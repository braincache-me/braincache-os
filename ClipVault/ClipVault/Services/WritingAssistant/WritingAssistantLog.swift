import Foundation

/// Lightweight file logger for diagnosing the Writing Assistant.
///
/// Writes to a log file inside the app's temporary directory and also mirrors
/// each line to `NSLog`. The file makes diagnosis reliable even when Console /
/// `log stream` filtering does not surface `NSLog` output.
enum WritingAssistantLog {

    /// Log file path. Inside the (sandboxed) app this resolves under the app
    /// container's `tmp/` directory.
    static let fileURL: URL =
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("braincache-writing.log")

    private static let queue = DispatchQueue(label: "com.clipvault.writing-log")
    private static var announced = false

    static func log(_ message: String) {
        NSLog("[WritingAssistant] \(message)")
        queue.async {
            if !announced {
                announced = true
                NSLog("[WritingAssistant] diagnostic log file: \(fileURL.path)")
            }
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
