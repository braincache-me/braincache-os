import AppKit
import ApplicationServices

// MARK: - Snapshot

/// A point-in-time read of whatever editable text element currently has focus.
///
/// Plain-data fields are kept separate from the live `AXUIElement` so the
/// disambiguation logic (`hasRewritableText`, `textToRewrite`, …) can be unit
/// tested with hand-built snapshots — `AXUIElement` cannot be constructed in
/// tests.
struct FocusedTextSnapshot {
    /// AX role string, e.g. "AXTextField", "AXTextArea".
    var role: String?
    /// Full text content of the focused element ("" when empty or unreadable).
    var value: String
    /// Currently selected substring ("" when there is no selection).
    var selectedText: String
    /// Selection start, in UTF-16 offsets (matches AX `CFRange` semantics).
    var selectionLocation: Int
    /// Selection length, in UTF-16 offsets. Zero means a plain caret.
    var selectionLength: Int
    /// True for password / secure fields — their content is never read.
    var isSecure: Bool
    /// True when the element is a role we treat as an editable text input.
    var isEditable: Bool
    /// PID of the application that owns the element.
    var pid: pid_t
    /// Bundle identifier of the owning application, when resolvable.
    var bundleID: String?
    /// User-visible name of the owning application, when resolvable.
    var appName: String?
    /// Best-effort title of the window containing the focused element.
    var windowTitle: String?
    /// The live AX element. Nil in unit tests.
    var element: AXUIElement?

    /// UTF-16 length of `value`, the unit AX selection ranges use.
    var valueLength: Int { (value as NSString).length }

    /// True when there is editable, non-blank text that a rewrite can act on.
    /// Accepts a non-blank selection on its own — some apps (Chrome
    /// contenteditable, Slack web) surface `kAXSelectedText` but leave
    /// `kAXValue` empty, so requiring `value` would lock those out.
    var hasRewritableText: Bool {
        guard isEditable, !isSecure else { return false }
        let hasValue = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSelected = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasValue || hasSelected
    }

    /// True when it is safe to attempt a rewrite. Some rich/web editors expose
    /// an editable focus target but no AX text until we copy from the field.
    var canAttemptRewrite: Bool {
        isEditable && !isSecure
    }

    /// True when a non-empty selection exists — a rewrite then targets only it.
    var hasSelection: Bool { selectionLength > 0 && !selectedText.isEmpty }

    /// The text a rewrite should operate on: the selection if there is one,
    /// otherwise the whole field.
    var textToRewrite: String { hasSelection ? selectedText : value }
}

// MARK: - Protocol

/// Abstraction over focused-element reading so coordinators stay testable.
protocol FocusedTextReading {
    /// Read the system-wide focused element. Returns nil when nothing is
    /// focused or accessibility is unavailable.
    func readFocusedText() -> FocusedTextSnapshot?
}

// MARK: - Concrete reader

/// Reads the focused text element through the Accessibility API.
final class FocusedTextReader: FocusedTextReading {

    /// Roles we treat as editable text inputs. Web inputs in Safari/Chrome also
    /// report `AXTextField` / `AXTextArea`, so this covers native and web alike.
    static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    /// Roles whose content must never be read.
    static let secureRoles: Set<String> = [
        "AXSecureTextField",
        "AXPasswordField",
    ]

    /// Browsers whose accessibility tree must be woken before it can be read.
    /// Setting `AXManualAccessibility` is a no-op on non-Chromium browsers.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    func readFocusedText() -> FocusedTextSnapshot? {
        guard AXIsProcessTrusted() else { return nil }

        // Browsers build their accessibility tree lazily. When the frontmost
        // app is a browser, wake it up *before* the primary query by setting
        // `AXManualAccessibility`, so the system-wide path can already see web
        // text fields instead of always falling through.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let isBrowser = Self.browserBundleIDs.contains(frontApp?.bundleIdentifier ?? "")
        if let app = frontApp, app.processIdentifier > 0, isBrowser {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        // Primary: the system-wide focused element. For Chromium browsers the
        // system-wide query often returns a container (AXWebArea / AXGroup)
        // instead of the actual focused web input — drill into the container's
        // own focused descendant to find the editable element.
        if let element = focusedElement(of: AXUIElementCreateSystemWide()) {
            let resolved = resolveEditableDescendant(element)
            let snapshot = makeSnapshot(from: resolved)
            if snapshot.isEditable || !isBrowser {
                return snapshot
            }
            // In a browser but the resolved element isn't editable — fall
            // through to the app-element path which sometimes surfaces a
            // different (more specific) focused element.
        }

        // Fallback: browsers and Electron apps frequently do not surface their
        // focused web element to the system-wide query. Ask the frontmost
        // app's element directly.
        if let app = frontApp, app.processIdentifier > 0 {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let element = focusedElement(of: appElement) {
                let resolved = resolveEditableDescendant(element)
                return makeSnapshot(from: resolved)
            }
        }
        return nil
    }

    /// If `element` is a container (web area, group, scroll area), drill into
    /// its focus chain to find the actual focused input. Tries
    /// `kAXFocusedUIElement` first (cheap, walks the focus chain Chrome
    /// declares). When that stalls — Chrome / Chromium often returns the
    /// AXWebArea or AXWindow without propagating focus deeper — falls back to
    /// a bounded breadth-first search through children looking for any
    /// descendant marked `kAXFocused = true`.
    private func resolveEditableDescendant(_ element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<6 {
            let role = stringAttribute(current, kAXRoleAttribute)
            if Self.editableRoles.contains(role ?? "") { return current }
            if Self.secureRoles.contains(role ?? "") { return current }
            guard Self.containerRoles.contains(role ?? "") else { return current }
            if let next = focusedElement(of: current), next != current {
                current = next
                continue
            }
            // Focus chain stalled — try a BFS scan for a kAXFocused descendant.
            if let focused = breadthFirstFocusedDescendant(of: current) {
                return focused
            }
            return current
        }
        return current
    }

    /// Container roles we descend through to reach a real editable element.
    private static let containerRoles: Set<String> = [
        "AXWebArea", "AXGroup", "AXScrollArea", "AXSplitGroup",
        "AXApplication", "AXWindow", "AXUnknown", "AXTabGroup", "AXLayoutArea",
        "AXGenericElement",
    ]

    /// BFS over children looking for the first descendant with `AXFocused`
    /// true. Capped at a small node budget so we never iterate huge DOM trees.
    private func breadthFirstFocusedDescendant(of root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let maxVisits = 400
        while !queue.isEmpty && visited < maxVisits {
            let next = queue.removeFirst()
            visited += 1
            if next != root, isFocused(next) {
                let role = stringAttribute(next, kAXRoleAttribute)
                if Self.editableRoles.contains(role ?? "")
                    || hasAttribute(next, kAXSelectedTextRangeAttribute) {
                    return next
                }
            }
            // Prefer AXChildren; some apps expose AXChildrenInNavigationOrder.
            for child in axChildren(of: next) {
                queue.append(child)
            }
        }
        return nil
    }

    private func isFocused(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedAttribute as CFString, &ref) == .success,
              let value = ref else { return false }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? Bool) ?? false
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        let array = value as! CFArray
        let count = CFArrayGetCount(array)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let raw = CFArrayGetValueAtIndex(array, i)!
            let element = unsafeBitCast(raw, to: AXUIElement.self)
            out.append(element)
        }
        return out
    }

    /// Reads `kAXFocusedUIElementAttribute` from `root`.
    private func focusedElement(of root: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root, kAXFocusedUIElementAttribute as CFString, &ref
        ) == .success,
            let value = ref,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func makeSnapshot(from element: AXUIElement) -> FocusedTextSnapshot {
        let role = stringAttribute(element, kAXRoleAttribute)
        let isSecure = Self.secureRoles.contains(role ?? "")
        let isEditable = !isSecure && isEditableText(element, role: role)

        let value = isSecure ? "" : (stringAttribute(element, kAXValueAttribute) ?? "")
        let selectedText = isSecure ? "" : (stringAttribute(element, kAXSelectedTextAttribute) ?? "")

        var selLocation = 0
        var selLength = 0
        if let range = selectedRange(of: element) {
            selLocation = range.location
            selLength = range.length
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName
        let windowTitle = windowTitle(of: element)

        return FocusedTextSnapshot(
            role: role,
            value: value,
            selectedText: selectedText,
            selectionLocation: selLocation,
            selectionLength: selLength,
            isSecure: isSecure,
            isEditable: isEditable,
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            element: element
        )
    }

    // MARK: - Text geometry

    /// Screen rect of the caret, in AX coordinates (top-left origin). Used to
    /// place the rewrite HUD. Returns nil for apps that do not expose
    /// `AXBoundsForRange` for the focused element.
    func caretRect(
        for element: AXUIElement,
        caretLocation: Int,
        textLength: Int
    ) -> CGRect? {
        // Raw caret bounds. Prefer the LAST CHARACTER's range: `AXBoundsForRange`
        // for a real one-character range is reliable, whereas a zero-length
        // range at the end of the text returns the wrong line (and a too-short
        // height) in some apps — NSTextView among them. The caret sits just
        // past that character's right edge. The zero-length range is only a
        // fallback for the empty-field edge case.
        let raw: CGRect
        if caretLocation > 0,
           let rect = boundsForRange(element, location: caretLocation - 1, length: 1),
           rect.height > 1 {
            raw = CGRect(
                x: Self.caretX(forCharacterBounds: rect),
                y: rect.minY,
                width: 2,
                height: rect.height
            )
        } else if let rect = boundsForRange(element, location: caretLocation, length: 0),
                  rect.height > 1 {
            raw = rect
        } else {
            return nil
        }

        return correctToScreen(raw, in: element)
    }

    /// Screen rect of the selected text, in AX coordinates (top-left origin).
    /// Used when the caret is hidden by a selection.
    func selectionRect(
        for element: AXUIElement,
        location: Int,
        length: Int
    ) -> CGRect? {
        guard length > 0,
              let raw = boundsForRange(element, location: location, length: length),
              raw.width > 1,
              raw.height > 1
        else {
            return nil
        }

        return correctToScreen(raw, in: element)
    }

    static func caretX(forCharacterBounds rect: CGRect) -> CGFloat {
        let maxExpectedCharacterWidth = max(6, rect.height * 0.55)
        let width = rect.width > rect.height * 0.9
            ? maxExpectedCharacterWidth
            : rect.width
        return rect.minX + width
    }

    /// `AXBoundsForRange` is *specified* to return screen coordinates, but many
    /// apps (Chromium/Electron especially) report them relative to the window
    /// instead. The window's own frame is reliably reported in screen
    /// coordinates, so use it as the anchor: accept the rect as-is when it
    /// lands inside the window, otherwise re-interpret it as window-relative,
    /// and reject it if neither fits — so the ghost text is never misplaced.
    private func correctToScreen(_ raw: CGRect, in element: AXUIElement) -> CGRect? {
        guard let window = windowFrame(of: element) else { return raw }
        let bounds = window.insetBy(dx: -8, dy: -8)
        if bounds.contains(CGPoint(x: raw.midX, y: raw.midY)) {
            return raw
        }
        let windowRelative = raw.offsetBy(dx: window.minX, dy: window.minY)
        if bounds.contains(CGPoint(x: windowRelative.midX, y: windowRelative.midY)) {
            return windowRelative
        }
        return nil
    }

    /// Screen frame of `element` from `kAXPosition` / `kAXSize` (AX top-left coords).
    func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self),
                              .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self),
                              .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Screen frame of the window containing `element`, in AX coords. Window
    /// positions are reliably reported in screen coordinates across apps.
    func windowFrame(of element: AXUIElement) -> CGRect? {
        if let window = axElement(element, kAXWindowAttribute),
           let frame = elementFrame(window) {
            return frame
        }
        // Fall back to walking up the parent chain to the window element.
        var current = element
        for _ in 0..<15 {
            if stringAttribute(current, kAXRoleAttribute) == (kAXWindowRole as String) {
                return elementFrame(current)
            }
            guard let parent = axElement(current, kAXParentAttribute) else { break }
            current = parent
        }
        return nil
    }

    /// Best-effort title of the window containing `element`.
    func windowTitle(of element: AXUIElement) -> String? {
        if let window = axElement(element, kAXWindowAttribute),
           let title = stringAttribute(window, kAXTitleAttribute),
           !title.isEmpty {
            return title
        }
        var current = element
        for _ in 0..<15 {
            if stringAttribute(current, kAXRoleAttribute) == (kAXWindowRole as String),
               let title = stringAttribute(current, kAXTitleAttribute),
               !title.isEmpty {
                return title
            }
            guard let parent = axElement(current, kAXParentAttribute) else { break }
            current = parent
        }
        return nil
    }

    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func boundsForRange(
        _ element: AXUIElement,
        location: Int,
        length: Int
    ) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var resultRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &resultRef
        ) == .success,
            let result = resultRef,
            CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(result, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    // MARK: - Editability

    /// Whether the element is an editable text input. Recognised text roles
    /// match directly; for unusual roles (Chrome / Electron contenteditable,
    /// rich text editors) we fall back to a structural test — an editable
    /// text element exposes a selection range and a string value, which
    /// buttons / checkboxes / static labels do not. We don't require the
    /// value to be settable through AX: the rewrite pastes via ⌘V, so a
    /// non-settable AX value is fine.
    private func isEditableText(_ element: AXUIElement, role: String?) -> Bool {
        if Self.editableRoles.contains(role ?? "") { return true }
        guard hasAttribute(element, kAXSelectedTextRangeAttribute) else { return false }
        // Either a string value is readable, or a selected-text attribute is
        // present — both signal a text-bearing element.
        if stringAttribute(element, kAXValueAttribute) != nil { return true }
        if hasAttribute(element, kAXSelectedTextAttribute) { return true }
        return false
    }

    private func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    // MARK: - Attribute helpers

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let str = valueRef as? String
        else { return nil }
        return str
    }

    private func selectedRange(of element: AXUIElement) -> (location: Int, length: Int)? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &valueRef
        ) == .success,
            let value = valueRef,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return (location: range.location, length: range.length)
    }
}
