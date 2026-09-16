import AppKit
import CoreGraphics
import Vision

/// Captures a small rectangle of screen pixels around a click and runs
/// Vision text recognition on it, returning the text observation nearest the
/// click point. Used to label clicks inside apps that don't expose rich
/// accessibility metadata (Chrome web content, games, some Electron apps).
///
/// Requires Screen Recording permission. On failure or absent permission,
/// returns `nil` — the caller should treat OCR as best-effort enrichment.
protocol ClickTextRecognizing {
    /// - Parameters:
    ///   - point: Screen position of the click in Quartz (top-left) coordinates.
    ///   - pid: Target process ID, used so the captured region is constrained
    ///          to windows owned by that process (avoids picking up text from
    ///          overlapping windows owned by other apps).
    /// - Returns: The recognised text nearest the click point, trimmed and
    ///            truncated to a reasonable length, or `nil` if no text was
    ///            found.
    func recognizeText(at point: CGPoint, ownerPID: pid_t) -> String?
}

final class ClickOCRService: ClickTextRecognizing {

    /// Width of the capture rectangle in points. A wider rect catches the
    /// whole line of a button / link but costs more OCR time.
    private let regionWidth: CGFloat = 420

    /// Height of the capture rectangle in points. Two lines of body text at
    /// typical system font sizes.
    private let regionHeight: CGFloat = 140

    /// Maximum characters retained from the picked observation.
    private let maxReturnedCharacters = 160

    func recognizeText(at point: CGPoint, ownerPID: pid_t) -> String? {
        let rect = CGRect(
            x: point.x - regionWidth / 2,
            y: point.y - regionHeight / 2,
            width: regionWidth,
            height: regionHeight
        )

        guard let cgImage = captureImage(in: rect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        // Vision observation coordinates are normalised [0,1] with origin at
        // bottom-left of the image. The click is at the centre of the captured
        // region, so pick the observation whose centre is closest to (0.5, 0.5).
        let picked = observations
            .compactMap { obs -> (VNRecognizedText, CGFloat)? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox
                let dx = box.midX - 0.5
                let dy = box.midY - 0.5
                return (top, dx * dx + dy * dy)
            }
            .min(by: { $0.1 < $1.1 })

        guard let text = picked?.0.string
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }

        if text.count > maxReturnedCharacters {
            return String(text.prefix(maxReturnedCharacters)) + "…"
        }
        return text
    }

    private func captureImage(in rect: CGRect) -> CGImage? {
        // Same API the screenshot fallback uses. Edge-of-rect content from
        // overlapping windows is acceptable for a small click region.
        CGWindowListCreateImage(
            rect,
            [.optionOnScreenOnly],
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }
}
