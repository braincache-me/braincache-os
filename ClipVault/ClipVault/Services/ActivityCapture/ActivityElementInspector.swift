import AppKit
import ApplicationServices

// MARK: - Result type

/// The result of inspecting an accessibility element at a screen position.
struct ActivityAXResult {
    /// AX role string, e.g. "AXButton", "AXTextField", "AXSecureTextField".
    var role: String?
    /// Human-readable role description from `kAXRoleDescriptionAttribute`.
    var roleDescription: String?
    /// Element title from `kAXTitleAttribute`.
    var title: String?
    /// Linked label text from `kAXTitleUIElementAttribute` when available.
    var titleUIElementText: String?
    /// Element description from `kAXDescriptionAttribute`.
    var elementDescription: String?
    /// Placeholder text from `AXPlaceholderValue`.
    var placeholderValue: String?
    /// Help / tooltip text from `kAXHelpAttribute`.
    var help: String?
    /// DOM `id` attribute for browser-hosted elements (`AXDOMIdentifier`).
    var domIdentifier: String?
    /// DOM `class` attribute for browser-hosted elements (`AXDOMClassList`), joined with spaces.
    var domClassList: String?
    /// A synthetic label resolved from related AX elements (ancestor / descendant fallback).
    var derivedControlName: String?
    /// Element value (always nil for secure/password fields).
    var value: String?
    /// Whether the element is a password / secure text field.
    var isSecureField: Bool
    /// The title of the containing window, obtained by walking up the AX hierarchy.
    var windowTitle: String?
    /// Frame of the containing window in screen coordinates (top-left origin),
    /// obtained by walking up the AX hierarchy.
    var windowFrame: CGRect?
    /// Active page URL resolved from `kAXURLAttribute` on the closest
    /// `AXWebArea` ancestor. Nil for non-browser content.
    var url: String?

    static let interactiveRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton",
        "AXSearchField",
        "AXSecureTextField",
        "AXSlider",
        "AXTab",
        "AXTextArea",
        "AXTextField",
    ]

    static let textRoles: Set<String> = [
        "AXHeading",
        "AXStaticText",
    ]

    static let genericContainerRoles: Set<String> = [
        "AXBrowser",
        "AXGroup",
        "AXLayoutArea",
        "AXScrollArea",
        "AXSplitGroup",
        "AXSplitterGroup",
        "AXWebArea",
    ]

    private static let rolesWhoseValueActsAsName: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXDisclosureTriangle",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton",
        "AXTab",
    ]

    var isInteractiveRole: Bool {
        Self.interactiveRoles.contains(role ?? "")
    }

    var isTextRole: Bool {
        Self.textRoles.contains(role ?? "")
    }

    var canContributeDerivedControlName: Bool {
        isInteractiveRole || isTextRole
    }

    var explicitControlName: String? {
        derivedControlName
            ?? title
            ?? titleUIElementText
            ?? elementDescription
            ?? placeholderValue
            ?? help
            ?? valueBackedControlName
            ?? domSelector
    }

    /// A CSS-style selector built from the DOM id / class attributes plus a
    /// best-effort HTML tag name inferred from the AX role. Used as a
    /// last-resort name for browser elements that have no accessible label
    /// (e.g. a styled `<div id="save-btn">` used as a button).
    var domSelector: String? {
        let hasID = (domIdentifier?.isEmpty == false)
        let hasClass = (domClassList?.isEmpty == false)
        guard hasID || hasClass else { return nil }

        var out = Self.htmlTagHint(forRole: role) ?? ""
        if let domIdentifier, !domIdentifier.isEmpty {
            out += "#\(domIdentifier)"
        }
        if let domClassList, !domClassList.isEmpty {
            let classes = domClassList
                .split(separator: " ")
                .prefix(3)
                .map { ".\($0)" }
                .joined()
            out += classes
        }
        return out.isEmpty ? nil : out
    }

    /// Maps common AX roles back to a likely HTML tag name. The macOS AX API
    /// does not expose the raw tag, but the role mapping used by both WebKit
    /// and Blink is stable enough that this hint is usually correct.
    static func htmlTagHint(forRole role: String?) -> String? {
        guard let role else { return nil }
        switch role {
        case "AXLink": return "a"
        case "AXButton", "AXMenuButton", "AXPopUpButton": return "button"
        case "AXImage": return "img"
        case "AXHeading": return "h"
        case "AXTextField", "AXSearchField", "AXSecureTextField": return "input"
        case "AXTextArea": return "textarea"
        case "AXCheckBox": return "input"
        case "AXRadioButton": return "input"
        case "AXComboBox": return "select"
        case "AXList": return "ul"
        case "AXListItem": return "li"
        case "AXTable", "AXGrid": return "table"
        case "AXRow": return "tr"
        case "AXCell": return "td"
        case "AXTabGroup": return "nav"
        case "AXTab": return "a"
        case "AXWebArea": return "body"
        default: return nil
        }
    }

    /// The best available control name.
    ///
    /// Priority: derived/associated label → title → description/placeholder/help → role description.
    /// This helps browser-backed controls where the clicked AX node is often a child text node.
    var bestControlName: String? {
        explicitControlName ?? (isInteractiveRole ? roleDescription : nil)
    }

    static let empty = ActivityAXResult(isSecureField: false)

    /// Whether this node carries enough browser metadata to count as a named
    /// candidate during descendant search even if it is not itself interactive.
    var hasBrowserDOMMetadata: Bool {
        domIdentifier != nil || domClassList != nil
    }

    private var valueBackedControlName: String? {
        guard let role, Self.rolesWhoseValueActsAsName.contains(role) else { return nil }
        return value
    }
}

// MARK: - Protocol

/// Abstraction over AX inspection so the coordinator is testable with fakes.
protocol ActivityAXInspecting {
    /// Inspect the accessibility element at the given screen point and return its attributes.
    func inspect(at point: CGPoint) -> ActivityAXResult

    /// Returns `true` if the system-wide focused element is a secure text field.
    func isSecureFieldFocused() -> Bool

    /// Resolve the active page URL for the application with `pid` by walking the
    /// AX hierarchy from the focused element to the closest `AXWebArea`.
    /// Nil for non-browser apps and when accessibility is not exposed.
    func currentURL(forPID pid: pid_t) -> String?
}

// MARK: - Concrete implementation

/// Real AX inspector that uses the Accessibility API.
final class ActivityElementInspector: ActivityAXInspecting {

    private static let secureRoles: Set<String> = [
        "AXSecureTextField",
        "AXPasswordField",  // used by some Electron-based and non-standard apps
    ]

    private static let placeholderValueAttribute = "AXPlaceholderValue"
    private static let domIdentifierAttribute = "AXDOMIdentifier"
    private static let domClassListAttribute = "AXDOMClassList"
    private static let webAreaRole = "AXWebArea"

    func inspect(at point: CGPoint) -> ActivityAXResult {
        guard AXIsProcessTrusted() else { return .empty }

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        // AXUIElementCopyElementAtPosition takes Float coordinates
        let err = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x), Float(point.y),
            &elementRef
        )
        guard err == .success, let element = elementRef else {
            return .empty
        }

        let resolvedElement = preferredElement(at: point, startingFrom: element)
        let window = walkToWindow(from: resolvedElement)
        let windowTitle = window.flatMap { stringAttribute($0, kAXTitleAttribute) }
        let windowFrame = window.flatMap { frame(of: $0) }
        let pageURL = walkToWebAreaURL(from: resolvedElement)
        let chain = elementChain(startingAt: resolvedElement)
        let inspectedChain = chain.map { inspectSingleElement($0) }

        let interactiveMatch = inspectedChain.first(where: { $0.isInteractiveRole })
        let namedBrowserMatch = inspectedChain.first(where: { $0.hasBrowserDOMMetadata && $0.explicitControlName != nil })
        guard var resolved = interactiveMatch ?? namedBrowserMatch ?? inspectedChain.first else {
            var empty = ActivityAXResult.empty
            empty.windowTitle = windowTitle
            empty.windowFrame = windowFrame
            empty.url = pageURL
            return empty
        }

        if resolved.explicitControlName == nil {
            resolved.derivedControlName = inspectedChain
                .filter { $0.canContributeDerivedControlName }
                .compactMap { $0.explicitControlName }
                .first
        }
        resolved.windowTitle = windowTitle
        resolved.windowFrame = windowFrame
        resolved.url = pageURL
        return resolved
    }

    func currentURL(forPID pid: pid_t) -> String? {
        guard AXIsProcessTrusted(), pid > 0 else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        let start: AXUIElement
        if err == .success, let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            start = unsafeBitCast(focused, to: AXUIElement.self)
        } else {
            // No focused element — fall back to the focused window so we can
            // still find the AXWebArea descendant in browser apps.
            var windowRef: CFTypeRef?
            let werr = AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                &windowRef
            )
            guard werr == .success,
                  let win = windowRef,
                  CFGetTypeID(win) == AXUIElementGetTypeID()
            else { return nil }
            return descendantWebAreaURL(in: unsafeBitCast(win, to: AXUIElement.self))
        }

        if let url = walkToWebAreaURL(from: start) { return url }
        return descendantWebAreaURL(in: start)
    }

    func isSecureFieldFocused() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else { return false }
        let element = focused as! AXUIElement
        guard let role = stringAttribute(element, kAXRoleAttribute) else { return false }
        return Self.secureRoles.contains(role)
    }

    // MARK: - Private helpers

    private func inspectSingleElement(_ element: AXUIElement, includeDescendantText: Bool = true) -> ActivityAXResult {
        let role = stringAttribute(element, kAXRoleAttribute)
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute)
        let title = stringAttribute(element, kAXTitleAttribute)
        let description = stringAttribute(element, kAXDescriptionAttribute)
        let titleUIElementText = titleUIElementText(for: element)
        let placeholderValue = stringAttribute(element, Self.placeholderValueAttribute)
        let help = stringAttribute(element, kAXHelpAttribute)
        let domIdentifier = stringAttribute(element, Self.domIdentifierAttribute)
        let domClassList = stringArrayAttribute(element, Self.domClassListAttribute)?
            .joined(separator: " ")

        let isSecure = Self.secureRoles.contains(role ?? "")
        let value: String? = isSecure ? nil : stringAttribute(element, kAXValueAttribute)

        let shouldLookForDescendantText =
            includeDescendantText &&
            title == nil &&
            titleUIElementText == nil &&
            description == nil &&
            placeholderValue == nil &&
            help == nil &&
            ActivityAXResult.interactiveRoles.contains(role ?? "")

        let derivedControlName = shouldLookForDescendantText ? descendantText(for: element) : nil

        return ActivityAXResult(
            role: role,
            roleDescription: roleDescription,
            title: title,
            titleUIElementText: titleUIElementText,
            elementDescription: description,
            placeholderValue: placeholderValue,
            help: help,
            domIdentifier: domIdentifier,
            domClassList: domClassList,
            derivedControlName: derivedControlName,
            value: value,
            isSecureField: isSecure,
            windowTitle: nil
        )
    }

    private func stringArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [String]? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let array = valueRef as? [Any]
        else { return nil }
        let strings = array.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let str = valueRef as? String,
              !str.isEmpty
        else { return nil }
        return str
    }

    private func preferredElement(at point: CGPoint, startingFrom element: AXUIElement) -> AXUIElement {
        let role = stringAttribute(element, kAXRoleAttribute)
        let isAlreadyPrecise =
            ActivityAXResult.interactiveRoles.contains(role ?? "") ||
            ActivityAXResult.textRoles.contains(role ?? "")
        guard !isAlreadyPrecise else { return element }

        guard ActivityAXResult.genericContainerRoles.contains(role ?? "") else { return element }
        return pointMatchingDescendant(in: element, point: point) ?? element
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let ref = valueRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func titleUIElementText(for element: AXUIElement) -> String? {
        guard let titleElement = elementAttribute(element, kAXTitleUIElementAttribute) else { return nil }
        return textContent(of: titleElement)
    }

    private func textContent(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute)
            ?? stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? stringAttribute(element, kAXHelpAttribute)
    }

    private func descendantText(for element: AXUIElement, maxDepth: Int = 2) -> String? {
        guard maxDepth > 0 else { return nil }

        for child in children(of: element) {
            let role = stringAttribute(child, kAXRoleAttribute)
            if ActivityAXResult.textRoles.contains(role ?? ""), let text = textContent(of: child) {
                return text
            }
            if let nested = descendantText(for: child, maxDepth: maxDepth - 1) {
                return nested
            }
        }
        return nil
    }

    private func pointMatchingDescendant(
        in root: AXUIElement,
        point: CGPoint,
        maxDepth: Int = 6,
        maxNodes: Int = 250
    ) -> AXUIElement? {
        struct Candidate {
            let element: AXUIElement
            let hasExplicitName: Bool
            let isInteractive: Bool
            let depth: Int
            let area: CGFloat
        }

        var visitedNodes = 0
        var best: Candidate?

        func isBetter(_ candidate: Candidate, than current: Candidate?) -> Bool {
            guard let current else { return true }
            if candidate.hasExplicitName != current.hasExplicitName {
                return candidate.hasExplicitName
            }
            if candidate.isInteractive != current.isInteractive {
                return candidate.isInteractive
            }
            if abs(candidate.area - current.area) > 1 {
                return candidate.area < current.area
            }
            return candidate.depth > current.depth
        }

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < maxDepth, visitedNodes < maxNodes else { return }

            for child in children(of: element) {
                guard visitedNodes < maxNodes else { return }
                visitedNodes += 1

                let childFrame = frame(of: child)
                if let childFrame, !frameContainsPoint(childFrame, point: point) {
                    continue
                }

                let childResult = inspectSingleElement(child, includeDescendantText: false)
                if childResult.isInteractiveRole || childResult.isTextRole || childResult.hasBrowserDOMMetadata {
                    let area = childFrame.map { max($0.width * $0.height, 1) } ?? .greatestFiniteMagnitude
                    let candidate = Candidate(
                        element: child,
                        hasExplicitName: childResult.explicitControlName != nil,
                        isInteractive: childResult.isInteractiveRole,
                        depth: depth + 1,
                        area: area
                    )
                    if isBetter(candidate, than: best) {
                        best = candidate
                    }
                }

                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return best?.element
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }

    private func frameContainsPoint(_ frame: CGRect, point: CGPoint) -> Bool {
        frame.insetBy(dx: -1, dy: -1).contains(point)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &valueRef) == .success,
              let array = valueRef as? [Any]
        else { return [] }

        return array.compactMap { child in
            let ref = child as CFTypeRef
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(ref, to: AXUIElement.self)
        }
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(element, kAXParentAttribute)
    }

    private func elementChain(startingAt element: AXUIElement, maxDepth: Int = 12) -> [AXUIElement] {
        var chain = [element]
        var current = element

        for _ in 0..<maxDepth {
            guard let parent = parentElement(of: current) else { break }
            if stringAttribute(parent, kAXRoleAttribute) == kAXWindowRole as String {
                break
            }
            chain.append(parent)
            current = parent
        }

        return chain
    }

    /// Walks up from `element` toward the root, returning the URL string of
    /// the first `AXWebArea` ancestor that exposes `kAXURLAttribute`.
    private func walkToWebAreaURL(from element: AXUIElement) -> String? {
        var current: AXUIElement = element
        for _ in 0..<20 {
            if stringAttribute(current, kAXRoleAttribute) == Self.webAreaRole {
                if let url = urlAttribute(current) { return url }
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    /// Searches descendants of `root` for the first `AXWebArea` and returns
    /// its `kAXURLAttribute`. Used when the focused element sits above the
    /// web area (e.g. a focused window with no focused descendant).
    private func descendantWebAreaURL(
        in root: AXUIElement,
        maxDepth: Int = 6,
        maxNodes: Int = 200
    ) -> String? {
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) -> String? {
            guard depth < maxDepth, visited < maxNodes else { return nil }
            for child in children(of: element) {
                guard visited < maxNodes else { return nil }
                visited += 1
                if stringAttribute(child, kAXRoleAttribute) == Self.webAreaRole {
                    if let url = urlAttribute(child) { return url }
                }
                if let nested = visit(child, depth: depth + 1) { return nested }
            }
            return nil
        }

        if stringAttribute(root, kAXRoleAttribute) == Self.webAreaRole,
           let url = urlAttribute(root) {
            return url
        }
        return visit(root, depth: 0)
    }

    /// Reads `kAXURLAttribute` from an element. The value is typically a
    /// `CFURL`/`NSURL` but some clients return a plain `String`; handle both.
    private func urlAttribute(_ element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &valueRef) == .success,
              let value = valueRef
        else { return nil }

        if CFGetTypeID(value) == CFURLGetTypeID() {
            let url = value as! CFURL
            let str = (url as URL).absoluteString
            return str.isEmpty ? nil : str
        }
        if let str = value as? String, !str.isEmpty {
            return str
        }
        if let nsurl = value as? URL {
            let str = nsurl.absoluteString
            return str.isEmpty ? nil : str
        }
        return nil
    }

    private func walkToWindow(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement = element
        for _ in 0..<20 {
            if let role = stringAttribute(current, kAXRoleAttribute), role == kAXWindowRole as String {
                return current
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }
}
