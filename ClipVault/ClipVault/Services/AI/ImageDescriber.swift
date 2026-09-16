import AppKit
import Foundation

/// Generates a concise text description of an image clip using the OpenAI vision API.
///
/// Images larger than 1 MB are resized to at most 1024 px on the longest edge before
/// encoding, which controls token cost. The returned description is stored in
/// `ClipRecord.imageDescription` and is subsequently used for FTS indexing and embedding.
final class ImageDescriber {

    static let maxByteSize = 1_024 * 1_024   // 1 MB
    static let maxEdgePx: CGFloat = 1_024

    private let client: OpenAIClient

    init(client: OpenAIClient = .shared) {
        self.client = client
    }

    // MARK: - Public API

    /// Describes the given image data.
    ///
    /// - Returns: A 1-3 sentence description, or `nil` if the API call fails.
    ///   Errors are swallowed so callers can continue classification/embedding
    ///   with whatever text content is available.
    func describe(imageData: Data) async -> String? {
        guard let dataToSend = prepareForVision(imageData: imageData) else { return nil }

        let systemMessage = OpenAIClient.ChatMessage(
            role: "system",
            content: systemPrompt
        )

        do {
            let response = try await client.chatCompletionWithVision(
                model: Settings.shared.visionModel,
                messages: [systemMessage],
                imageData: dataToSend,
                detail: "low",
                maxOutputTokens: 768,
                usageCategory: .indexing
            )
            return response.choices.first?.message.content
        } catch {
            NSLog("ClipVault: image description request failed: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Image Resizing

    /// Returns PNG data suitable for OpenAI's vision endpoint. Clipboard images can arrive
    /// as TIFF even when the request labels the payload as PNG, so normalize non-PNG bytes.
    func prepareForVision(imageData: Data) -> Data? {
        if imageData.count <= Self.maxByteSize, Self.isPNG(imageData) {
            return imageData
        }
        return pngData(imageData: imageData, maxLongEdge: Self.maxEdgePx)
    }

    /// Resizes `imageData` so its longest edge is at most `maxEdgePx`.
    /// Returns `nil` if the image cannot be decoded.
    func resize(imageData: Data) -> Data? {
        pngData(imageData: imageData, maxLongEdge: Self.maxEdgePx)
    }

    private func pngData(imageData: Data, maxLongEdge: CGFloat) -> Data? {
        guard let image = NSImage(data: imageData) else { return nil }
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let longestEdge = max(originalSize.width, originalSize.height)
        let scaleFactor = min(1, maxLongEdge / longestEdge)
        let newSize = CGSize(
            width:  floor(originalSize.width  * scaleFactor),
            height: floor(originalSize.height * scaleFactor)
        )

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = newSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: CGRect(origin: .zero, size: newSize),
            from: CGRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return data.prefix(signature.count).elementsEqual(signature)
    }

    // MARK: - Prompt

    var systemPrompt: String { Prompts.shared.imageDescriber.system }
}
