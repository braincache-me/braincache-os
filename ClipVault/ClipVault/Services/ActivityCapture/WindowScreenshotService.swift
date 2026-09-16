import Foundation
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Protocol (injectable for testing)

/// Captures the frontmost window of a given app and writes it as a JPEG file.
/// Returning `nil` means capture was skipped (permission denied, window not found, etc.).
protocol WindowScreenshotCapturing: AnyObject {
    func captureAndSave(
        appName: String,
        bundleID: String,
        trigger: String,
        screenshotsURL: URL,
        quality: Double,
        scale: Int
    ) async -> String?
}

// MARK: - User-pickable window descriptor

/// A window the user can attach to an AI Assist request.
///
/// Uses `CGWindowID` for capture identity (stable for the lifetime of the
/// window) and carries enough metadata to render a picker tile without
/// re-querying the system.
struct CapturableWindow: Identifiable, Equatable {
    let id: CGWindowID
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let appIcon: NSImage?

    static func == (lhs: CapturableWindow, rhs: CapturableWindow) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Production implementation

/// Screenshot service backed by `ScreenCaptureKit` (macOS 14+) with a
/// `CGWindowListCreateImage` fallback for macOS 13.
///
/// Returns `nil` and silently does nothing when Screen Recording permission is
/// not granted, so the caller can continue metadata logging without interruption.
final class WindowScreenshotService: WindowScreenshotCapturing {

    /// Hard cap on the longer edge of any saved screenshot, in pixels. Large
    /// 5K windows would otherwise produce ~1 MB JPEGs each; downscaling to
    /// 1000 px keeps files in the 100–250 KB range while staying legible.
    static let maxScreenshotLongEdge: Int = 1000

    /// Whether Screen Recording permission is currently granted.
    static var isScreenRecordingGranted: Bool {
        AccessibilityChecker.isScreenRecordingGranted
    }

    func captureAndSave(
        appName: String,
        bundleID: String,
        trigger: String,
        screenshotsURL: URL,
        quality: Double,
        scale: Int
    ) async -> String? {
        guard Self.isScreenRecordingGranted else { return nil }

        let now = Date()
        let relativePath = ActivityLogPaths.relativeScreenshotPath(
            timestamp: now,
            appName: appName,
            trigger: trigger
        )
        let fileURL = ActivityLogPaths.screenshotFileURL(
            timestamp: now,
            appName: appName,
            trigger: trigger,
            in: screenshotsURL
        )

        // Ensure per-day directory exists.
        let dayDir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        } catch {
            if !FileManager.default.fileExists(atPath: dayDir.path) {
                return nil
            }
        }

        // Capture using the best available API.
        let image: CGImage?
        if #available(macOS 14.0, *) {
            image = await captureWithSCScreenshotManager(bundleID: bundleID, scale: scale)
        } else {
            image = captureWithCGWindowList(bundleID: bundleID, scale: scale)
        }

        guard let cgImage = image else { return nil }
        let downscaled = Self.downscale(cgImage, maxLongEdge: Self.maxScreenshotLongEdge) ?? cgImage
        guard writeJPEG(downscaled, to: fileURL, quality: quality) else { return nil }
        return relativePath
    }

    // MARK: - Downscale

    /// Returns a copy of `image` resized so its longer edge is at most
    /// `maxLongEdge` pixels (preserving aspect ratio). Returns `nil` if the
    /// image is already small enough or if resizing fails.
    static func downscale(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return nil }

        let scaleFactor = Double(maxLongEdge) / Double(longEdge)
        let newWidth = max(1, Int((Double(width) * scaleFactor).rounded()))
        let newHeight = max(1, Int((Double(height) * scaleFactor).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    // MARK: - macOS 14+ single-shot capture

    @available(macOS 14.0, *)
    private func captureWithSCScreenshotManager(bundleID: String, scale: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return nil }

        // Find the frontmost on-screen window of the target app.
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
        }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixelScale = scale == 2 ? 2.0 : 1.0
        config.width = max(1, Int(window.frame.width * pixelScale))
        config.height = max(1, Int(window.frame.height * pixelScale))
        config.showsCursor = false

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    // MARK: - macOS 13 fallback via CGWindowListCreateImage

    private func captureWithCGWindowList(bundleID: String, scale: Int) -> CGImage? {
        let listOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID) as? [[CFString: Any]]
        else { return nil }

        // CGWindowListCopyWindowInfo returns windows front-to-back; take the first
        // layer-0 window belonging to the target app.
        for info in list {
            guard
                let pidAny = info[kCGWindowOwnerPID as CFString],
                let pidInt = (pidAny as? Int) ?? (pidAny as? Int32).map(Int.init),
                let app = NSRunningApplication(processIdentifier: pid_t(pidInt)),
                app.bundleIdentifier == bundleID,
                let windowNumberAny = info[kCGWindowNumber as CFString],
                let windowID = (windowNumberAny as? CGWindowID)
                    ?? (windowNumberAny as? UInt32),
                let layerAny = info[kCGWindowLayer as CFString],
                let layer = (layerAny as? Int) ?? (layerAny as? Int32).map(Int.init),
                layer == 0
            else { continue }

            let imageOption: CGWindowImageOption = scale == 2 ? .bestResolution : .nominalResolution
            return CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                imageOption
            )
        }
        return nil
    }

    // MARK: - Window enumeration (for AI Assist picker)

    /// Lists on-screen windows the user could attach to an AI Assist request.
    /// Excludes our own bundle, the desktop, menu bars, and tiny / off-screen
    /// windows so the picker stays focused on real document/app windows.
    func enumerateCapturableWindows() async -> [CapturableWindow] {
        guard Self.isScreenRecordingGranted else { return [] }

        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let listOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID) as? [[CFString: Any]]
        else { return [] }

        var seenWindowIDs = Set<CGWindowID>()
        var results: [CapturableWindow] = []

        for info in list {
            guard
                let layerAny = info[kCGWindowLayer as CFString],
                let layer = (layerAny as? Int) ?? (layerAny as? Int32).map(Int.init),
                layer == 0,
                let windowNumberAny = info[kCGWindowNumber as CFString],
                let windowID = (windowNumberAny as? CGWindowID) ?? (windowNumberAny as? UInt32),
                !seenWindowIDs.contains(windowID),
                let pidAny = info[kCGWindowOwnerPID as CFString],
                let pidInt = (pidAny as? Int) ?? (pidAny as? Int32).map(Int.init),
                let app = NSRunningApplication(processIdentifier: pid_t(pidInt)),
                let bundleID = app.bundleIdentifier,
                bundleID != ownBundleID
            else { continue }

            // Filter out tiny/off-screen utility windows so the picker shows
            // real content. 200x100 covers most browser tabs while skipping
            // status overlays.
            let bounds = (info[kCGWindowBounds as CFString] as? [String: CGFloat]) ?? [:]
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            if frame.width < 200 || frame.height < 100 { continue }

            let title = (info[kCGWindowName as CFString] as? String) ?? ""
            let appName = app.localizedName ?? bundleID

            seenWindowIDs.insert(windowID)
            results.append(
                CapturableWindow(
                    id: windowID,
                    bundleID: bundleID,
                    appName: appName,
                    title: title,
                    frame: frame,
                    appIcon: app.icon
                )
            )
        }

        return results
    }

    /// Generates a small thumbnail (max 320pt long edge) for a previously
    /// enumerated window. Returns nil if capture fails.
    func thumbnail(for window: CapturableWindow) async -> NSImage? {
        let imageOption: CGWindowImageOption = .nominalResolution
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.id,
            imageOption
        ) else { return nil }

        let maxEdge: CGFloat = 320
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        let scale = min(1.0, maxEdge / max(srcW, srcH))
        let size = NSSize(width: srcW * scale, height: srcH * scale)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Captures a single window by its `CGWindowID` and returns JPEG data
    /// suitable for inlining into an OpenAI vision request. Honors the same
    /// quality/scale knobs as `captureAndSave`.
    func captureWindowAsJPEG(
        windowID: CGWindowID,
        quality: Double,
        scale: Int
    ) async -> Data? {
        guard Self.isScreenRecordingGranted else { return nil }

        let cgImage: CGImage?
        if #available(macOS 14.0, *) {
            cgImage = await captureWithSCScreenshotManager(windowID: windowID, scale: scale)
        } else {
            let imageOption: CGWindowImageOption = scale == 2 ? .bestResolution : .nominalResolution
            cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                imageOption
            )
        }
        guard let image = cgImage else { return nil }
        return jpegData(image, quality: quality)
    }

    /// Captures the frontmost window for a bundle as JPEG data for transient
    /// model context. This does not write anything to disk.
    func captureFrontmostWindowAsJPEG(
        bundleID: String,
        quality: Double,
        scale: Int,
        maxLongEdge: Int = 900
    ) async -> Data? {
        guard Self.isScreenRecordingGranted else { return nil }

        let image: CGImage?
        if #available(macOS 14.0, *) {
            image = await captureWithSCScreenshotManager(bundleID: bundleID, scale: scale)
        } else {
            image = captureWithCGWindowList(bundleID: bundleID, scale: scale)
        }
        guard let cgImage = image else { return nil }
        let downscaled = Self.downscale(cgImage, maxLongEdge: maxLongEdge) ?? cgImage
        return jpegData(downscaled, quality: quality)
    }

    @available(macOS 14.0, *)
    private func captureWithSCScreenshotManager(windowID: CGWindowID, scale: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return nil }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixelScale = scale == 2 ? 2.0 : 1.0
        config.width = max(1, Int(window.frame.width * pixelScale))
        config.height = max(1, Int(window.frame.height * pixelScale))
        config.showsCursor = false

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    private func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let utType = UTType.jpeg.identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, utType, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - JPEG encoding

    private func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        let utType = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil)
        else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
