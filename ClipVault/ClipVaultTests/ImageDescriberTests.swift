import XCTest
@testable import ClipVault

final class ImageDescriberTests: XCTestCase {

    private var describer: ImageDescriber!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session, initialRetryDelay: 100_000)
        describer = ImageDescriber(client: client)
        Settings.shared.openAIAPIKey = "sk-test-describer"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        describer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Returns a minimal 2×2 PNG as Data (valid, but tiny).
    private func smallPNGData() -> Data {
        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create test PNG")
            return Data()
        }
        return png
    }

    private func smallTIFFData() -> Data {
        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else {
            XCTFail("Could not create test TIFF")
            return Data()
        }
        return tiff
    }

    private func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return data.prefix(signature.count).elementsEqual(signature)
    }

    /// Creates a PNG that is guaranteed to exceed `ImageDescriber.maxByteSize` by padding with
    /// a large white rectangle.
    private func largePNGData() -> Data {
        // 1024 × 1024 solid-colour image ≫ 1 MB as uncompressed TIFF
        let image = NSImage(size: CGSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        image.unlockFocus()
        // Use TIFF for the source data — TIFF is uncompressed and will be large
        guard let tiff = image.tiffRepresentation else {
            XCTFail("Could not create test TIFF")
            return Data()
        }
        // TIFF of a 1024×1024 RGBA image = 1024*1024*4 = 4 MB, well above the 1 MB limit
        return tiff
    }

    private func makeChatResponse(description: String) -> Data {
        let escaped = description
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "id": "chatcmpl-test",
          "choices": [{
            "message": {"role": "assistant", "content": "\(escaped)"},
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 20, "completion_tokens": 30, "total_tokens": 50}
        }
        """.data(using: .utf8)!
    }

    private func makeHTTPResponse(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - Basic describe

    func testDescribeReturnsDescriptionString() async {
        let expected = "A red square on a white background."
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeChatResponse(description: expected))
        }

        let result = await describer.describe(imageData: smallPNGData())
        XCTAssertEqual(result, expected)
    }

    // MARK: - Model and detail

    func testDescribeUsesCorrectModelAndDetail() async {
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
            let messages = body["messages"] as! [[String: Any]]
            // The last message should contain an image_url content block with detail "low"
            let lastMsg = messages.last!
            let contentArr = lastMsg["content"] as? [[String: Any]]
            let imageBlock = contentArr?.first(where: { $0["type"] as? String == "image_url" })
            let imageURL = imageBlock?["image_url"] as? [String: String]
            XCTAssertEqual(imageURL?["detail"], "low")
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "test"))
        }

        _ = await describer.describe(imageData: smallPNGData())
    }

    // MARK: - Base64 encoding

    func testDescribeSendsBase64EncodedImage() async {
        let pngData = smallPNGData()
        let expectedBase64 = pngData.base64EncodedString()

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let lastMsg = messages.last!
            let contentArr = lastMsg["content"] as? [[String: Any]]
            let imageBlock = contentArr?.first(where: { $0["type"] as? String == "image_url" })
            let imageURL = imageBlock?["image_url"] as? [String: String]
            let urlString = imageURL?["url"] ?? ""
            XCTAssertTrue(urlString.contains(expectedBase64), "Request should contain the base64-encoded image")
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "A tiny red square."))
        }

        _ = await describer.describe(imageData: pngData)
    }

    func testDescribeConvertsSmallTIFFToPNGBeforeSending() async {
        let tiffData = smallTIFFData()
        XCTAssertFalse(isPNG(tiffData), "Test data should start as TIFF, not PNG")

        var sentData: Data?
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let lastMsg = messages.last!
            let contentArr = lastMsg["content"] as? [[String: Any]]
            let imageBlock = contentArr?.first(where: { $0["type"] as? String == "image_url" })
            let imageURL = imageBlock?["image_url"] as? [String: String]
            let urlString = imageURL?["url"] ?? ""
            XCTAssertTrue(urlString.hasPrefix("data:image/png;base64,"))
            let base64 = String(urlString.dropFirst("data:image/png;base64,".count))
            sentData = Data(base64Encoded: base64)
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "A tiny green square."))
        }

        _ = await describer.describe(imageData: tiffData)
        XCTAssertNotNil(sentData)
        XCTAssertTrue(isPNG(sentData ?? Data()), "TIFF clipboard images should be normalized to PNG")
    }

    // MARK: - Image resizing

    func testResizeReturnsSmallerDataForLargeImage() {
        let large = largePNGData()
        XCTAssertGreaterThan(large.count, ImageDescriber.maxByteSize,
                             "Test image must exceed maxByteSize to be a valid resize test")
        let resized = describer.resize(imageData: large)
        XCTAssertNotNil(resized)
        // The resized PNG should not decode to a larger image than maxEdgePx
        if let resizedData = resized, let img = NSImage(data: resizedData) {
            XCTAssertLessThanOrEqual(
                max(img.size.width, img.size.height),
                ImageDescriber.maxEdgePx + 1,
                "Resized image longest edge should be ≤ \(ImageDescriber.maxEdgePx)"
            )
        }
    }

    func testResizeIsSkippedForSmallImage() async {
        let small = smallPNGData()
        XCTAssertLessThan(small.count, ImageDescriber.maxByteSize)

        var sentData: Data?
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let lastMsg = messages.last!
            let contentArr = lastMsg["content"] as? [[String: Any]]
            let imageBlock = contentArr?.first(where: { $0["type"] as? String == "image_url" })
            let imageURL = imageBlock?["image_url"] as? [String: String]
            let urlString = imageURL?["url"] ?? ""
            // Strip "data:image/png;base64," prefix
            let base64 = String(urlString.dropFirst("data:image/png;base64,".count))
            sentData = Data(base64Encoded: base64)
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "Small image."))
        }

        _ = await describer.describe(imageData: small)
        XCTAssertEqual(sentData, small, "Small images should be sent without resizing")
    }

    func testLargeImageIsResizedBeforeSending() async {
        let large = largePNGData()
        XCTAssertGreaterThan(large.count, ImageDescriber.maxByteSize)

        var sentDataSize = 0
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let lastMsg = messages.last!
            let contentArr = lastMsg["content"] as? [[String: Any]]
            let imageBlock = contentArr?.first(where: { $0["type"] as? String == "image_url" })
            let imageURL = imageBlock?["image_url"] as? [String: String]
            let urlString = imageURL?["url"] ?? ""
            let base64 = String(urlString.dropFirst("data:image/png;base64,".count))
            sentDataSize = Data(base64Encoded: base64)?.count ?? 0
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "Large resized image."))
        }

        _ = await describer.describe(imageData: large)
        XCTAssertLessThan(sentDataSize, large.count, "Large images should be resized before sending")
    }

    // MARK: - Prompt structure

    func testSystemPromptContainsRequiredKeywords() {
        let prompt = describer.systemPrompt
        XCTAssertTrue(prompt.contains("1-3 sentences"))
        XCTAssertTrue(prompt.contains("screenshot"))
        XCTAssertTrue(prompt.contains("visible text"))
    }

    func testDescribeSendsSystemMessage() async {
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let systemMsg = messages.first(where: { $0["role"] as? String == "system" })
            XCTAssertNotNil(systemMsg, "A system message should be sent")
            let content = systemMsg?["content"] as? String ?? ""
            XCTAssertTrue(content.contains("1-3 sentences"))
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "A screenshot."))
        }

        _ = await describer.describe(imageData: smallPNGData())
    }

    // MARK: - Graceful error fallback

    func testDescribeReturnsNilOnHTTPError() async {
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let result = await describer.describe(imageData: smallPNGData())
        XCTAssertNil(result, "describe() should return nil on API error, not throw")
    }

    func testDescribeReturnsNilOnNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = await describer.describe(imageData: smallPNGData())
        XCTAssertNil(result, "describe() should return nil on network error, not throw")
    }

    func testDescribeReturnsNilForInvalidImageWithoutCallingAPI() async {
        var didCallAPI = false
        MockURLProtocol.requestHandler = { _ in
            didCallAPI = true
            return (self.makeHTTPResponse(), self.makeChatResponse(description: "Unexpected"))
        }

        let result = await describer.describe(imageData: Data("not an image".utf8))
        XCTAssertNil(result)
        XCTAssertFalse(didCallAPI)
    }

    // MARK: - resize edge cases

    func testResizeReturnsNilForInvalidData() {
        let result = describer.resize(imageData: Data("not an image".utf8))
        XCTAssertNil(result)
    }
}
