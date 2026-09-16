import Darwin
import Foundation
import Network
import Security

struct BrainCacheBridgeProvision {
    let baseURL: String
    let candidateBaseURLs: [String]
    let token: String
    let port: Int
}

enum BrainCacheLocalBridgeError: LocalizedError {
    case noAvailablePort
    case invalidPort
    case missingClipStore

    var errorDescription: String? {
        switch self {
        case .noAvailablePort:
            return "BrainCache could not find an available localhost port for the AI skill bridge."
        case .invalidPort:
            return "The configured AI skill bridge port is invalid."
        case .missingClipStore:
            return "BrainCache storage is not ready yet. Try exporting the skill again after launch finishes."
        }
    }
}

/// Read-only localhost HTTP bridge for exported AI skills.
///
/// The listener binds to IPv4 interfaces so host-local VM/container sandboxes
/// can reach it via their host gateway. Every endpoint requires a bearer token,
/// because localhost/private networking is not a permission boundary.
final class BrainCacheLocalBridgeServer {
    static let shared = BrainCacheLocalBridgeServer()
    static let discoveryFileName = "braincache-bridge.json"
    static let endpointList = [
        "GET /v1/info",
        "GET /v1/clips/recent?limit=50",
        "GET /v1/clips/search?q=keyword&limit=20",
        "GET /v1/audio/recent?limit=20",
        "GET /v1/audio/search?q=keyword&limit=20",
        "GET /v1/activity/day?day=YYYY-MM-DD&limit=500",
        "GET /v1/live/transcript"
    ]

    private let queue = DispatchQueue(label: "com.TalkFlow.BrainCache.LocalBridge")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private var listener: NWListener?
    private weak var clipStore: ClipStore?
    private var currentPort: Int?

    private init() {}

    var isRunning: Bool {
        listener != nil
    }

    func configure(clipStore: ClipStore?) {
        self.clipStore = clipStore
    }

    @discardableResult
    func provisionForSkillExport(clipStore: ClipStore?) throws -> BrainCacheBridgeProvision {
        configure(clipStore: clipStore)

        let port = Self.firstAvailablePort(preferred: Settings.shared.aiSkillBridgePort)
        guard port > 0 else { throw BrainCacheLocalBridgeError.noAvailablePort }

        let existingToken = Settings.shared.aiSkillBridgeToken
        let token = existingToken.isEmpty ? Self.generateToken() : existingToken
        Settings.shared.aiSkillBridgePort = port
        Settings.shared.aiSkillBridgeToken = token
        Settings.shared.aiSkillBridgeEnabled = true

        try startIfProvisioned()
        let activePort = currentPort ?? Settings.shared.aiSkillBridgePort
        return BrainCacheBridgeProvision(
            baseURL: "http://127.0.0.1:\(activePort)",
            candidateBaseURLs: Self.candidateBaseURLs(port: activePort),
            token: token,
            port: activePort
        )
    }

    func startIfProvisioned() throws {
        guard Settings.shared.aiSkillBridgeEnabled else { return }
        guard !Settings.shared.aiSkillBridgeToken.isEmpty else { return }
        let savedPort = Settings.shared.aiSkillBridgePort
        if listener != nil, currentPort == savedPort {
            try writeDiscoveryFile(port: savedPort)
            return
        }
        stop()
        let activePort = try startBestAvailable(preferred: savedPort)
        Settings.shared.aiSkillBridgePort = activePort
        try writeDiscoveryFile(port: activePort)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        currentPort = nil
    }

    private func start(port: Int) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)),
              let anyIPv4 = IPv4Address("0.0.0.0") else {
            throw BrainCacheLocalBridgeError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(anyIPv4), port: .any)

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("BrainCacheLocalBridgeServer failed: %@", String(describing: error))
            }
        }
        listener.start(queue: queue)

        self.listener = listener
        currentPort = port
    }

    private func startBestAvailable(preferred: Int) throws -> Int {
        let primary = Self.firstAvailablePort(preferred: preferred)
        guard primary > 0 else { throw BrainCacheLocalBridgeError.noAvailablePort }

        do {
            try start(port: primary)
            return primary
        } catch {
            if preferred > 0, primary == preferred {
                let fallback = Self.firstAvailablePort(preferred: 0)
                guard fallback > 0, fallback != primary else { throw error }
                try start(port: fallback)
                return fallback
            }
            throw error
        }
    }

    private func handle(_ connection: NWConnection) {
        guard isAllowedClientEndpoint(connection.endpoint) else {
            connection.cancel()
            return
        }

        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            guard let data, let request = HTTPRequest(data: data) else {
                self.sendError(status: 400, message: "Bad Request", on: connection)
                return
            }
            self.route(request, on: connection)
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.method == "GET" else {
            sendError(status: 405, message: "Method Not Allowed", on: connection)
            return
        }
        guard isAuthorized(request) else {
            sendError(status: 401, message: "Unauthorized", on: connection)
            return
        }

        do {
            switch request.path {
            case "/v1/info":
                try sendJSON(infoPayload(), on: connection)
            case "/v1/clips/recent":
                try sendJSON(clipsRecentPayload(request.queryItems), on: connection)
            case "/v1/clips/search":
                try sendJSON(clipsSearchPayload(request.queryItems), on: connection)
            case "/v1/audio/recent":
                try sendJSON(audioRecentPayload(request.queryItems), on: connection)
            case "/v1/audio/search":
                try sendJSON(audioSearchPayload(request.queryItems), on: connection)
            case "/v1/activity/day":
                try sendJSON(activityDayPayload(request.queryItems), on: connection)
            case "/v1/live/transcript":
                try sendJSON(liveTranscriptPayload(), on: connection)
            default:
                sendError(status: 404, message: "Not Found", on: connection)
            }
        } catch {
            sendError(status: 500, message: error.localizedDescription, on: connection)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let expected = Settings.shared.aiSkillBridgeToken
        guard !expected.isEmpty,
              let header = request.headers["authorization"],
              header.hasPrefix("Bearer ") else { return false }
        let supplied = String(header.dropFirst("Bearer ".count))
        return Self.constantTimeEquals(supplied, expected)
    }

    private func infoPayload() throws -> BridgeInfoPayload {
        let databasePath = (try? DatabaseManager.databaseURL())?.path
        let databaseExists = databasePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let activityRoot = Settings.shared.activityCaptureLogRootPath
        let activityDays = availableActivityDays()

        return BridgeInfoPayload(
            name: "BrainCache Local Bridge",
            version: "1.0",
            baseURL: "http://127.0.0.1:\(Settings.shared.aiSkillBridgePort)",
            candidateBaseURLs: Self.candidateBaseURLs(port: Settings.shared.aiSkillBridgePort),
            boundHost: "0.0.0.0",
            database: PathStat(path: databasePath, exists: databaseExists),
            activityRoot: activityRoot,
            activityDaysAvailable: activityDays,
            endpoints: Self.endpointList
        )
    }

    private func writeDiscoveryFile(port: Int) throws {
        let payload = BridgeDiscoveryPayload(
            name: "BrainCache Local Bridge",
            version: "1.0",
            baseURL: "http://127.0.0.1:\(port)",
            candidateBaseURLs: Self.candidateBaseURLs(port: port),
            token: Settings.shared.aiSkillBridgeToken,
            port: port,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            endpoints: Self.endpointList
        )
        let directory = try DatabaseManager.dataDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.discoveryFileName)
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private func clipsRecentPayload(_ query: [String: String]) throws -> [ClipRecord] {
        guard let clipStore else { throw BrainCacheLocalBridgeError.missingClipStore }
        return try clipStore.fetchRecentClipboardClips(limit: limited(query["limit"], default: 50, max: 200))
    }

    private func clipsSearchPayload(_ query: [String: String]) throws -> [ClipRecord] {
        guard let clipStore else { throw BrainCacheLocalBridgeError.missingClipStore }
        let q = query["q"] ?? ""
        return try clipStore.searchClipboardHistory(query: q, limit: limited(query["limit"], default: 20, max: 100))
    }

    private func audioRecentPayload(_ query: [String: String]) throws -> [ClipRecord] {
        guard let clipStore else { throw BrainCacheLocalBridgeError.missingClipStore }
        return try clipStore.fetchRecentAudioTranscripts(limit: limited(query["limit"], default: 20, max: 100))
    }

    private func audioSearchPayload(_ query: [String: String]) throws -> [ClipRecord] {
        guard let clipStore else { throw BrainCacheLocalBridgeError.missingClipStore }
        let q = query["q"] ?? ""
        return try clipStore.searchAudioTranscripts(query: q, limit: limited(query["limit"], default: 20, max: 100))
    }

    private func activityDayPayload(_ query: [String: String]) throws -> [ActivityEvent] {
        guard let day = query["day"],
              day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let rootPath = Settings.shared.activityCaptureLogRootPath else {
            return []
        }

        let limit = limited(query["limit"], default: 500, max: 2_000)
        let logsURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let logURL = logsURL.appendingPathComponent("\(day).jsonl")
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }

        var events: [ActivityEvent] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard events.count < limit else { break }
            if let data = String(line).data(using: .utf8),
               let event = try? ActivityEvent.jsonDecoder.decode(ActivityEvent.self, from: data) {
                events.append(event)
            }
        }
        return events
    }

    /// Snapshot of the voice recording currently in progress (dictation or a
    /// meeting recording), so a connected AI harness can follow the
    /// conversation live instead of waiting for the saved transcript.
    /// Voice state is main-thread-owned; the bridge serves from its own queue.
    private func liveTranscriptPayload() -> LiveTranscriptPayload {
        let build = {
            let service = VoiceTranscriptionService.shared
            return Self.makeLiveTranscriptPayload(
                state: service.state,
                transcript: service.transcript,
                startedAt: service.recordingStartTime,
                durationSeconds: service.recordingDuration,
                includesSystemAudio: service.isSystemAudioEnabled
            )
        }
        if Thread.isMainThread { return build() }
        return DispatchQueue.main.sync(execute: build)
    }

    static func makeLiveTranscriptPayload(
        state: VoiceTranscriptionService.State,
        transcript: VoiceTranscriptionService.LiveTranscript,
        startedAt: Date?,
        durationSeconds: TimeInterval,
        includesSystemAudio: Bool
    ) -> LiveTranscriptPayload {
        let stateLabel: String
        var isLive = false
        switch state {
        case .idle: stateLabel = "idle"
        case .recording: stateLabel = "recording"; isLive = true
        case .transcribing: stateLabel = "transcribing"; isLive = true
        case .completed: stateLabel = "completed"
        case .error: stateLabel = "error"
        }

        let entries = transcript.entries
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
            .map { entry in
                LiveTranscriptPayload.Entry(
                    source: entry.source.rawValue,
                    offsetSeconds: entry.timestamp,
                    text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: entry.isFinal
                )
            }

        return LiveTranscriptPayload(
            state: stateLabel,
            isLive: isLive,
            startedAt: startedAt.map { ISO8601DateFormatter().string(from: $0) },
            durationSeconds: durationSeconds,
            includesSystemAudio: includesSystemAudio,
            text: transcript.combined,
            micPartial: transcript.micPartial,
            systemPartial: transcript.systemPartial,
            entries: entries
        )
    }

    private func availableActivityDays() -> [String] {
        guard let rootPath = Settings.shared.activityCaptureLogRootPath else { return [] }
        let logsURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsURL.path) else { return [] }
        return files
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil }
            .map { String($0.dropLast(".jsonl".count)) }
            .sorted(by: >)
    }

    private func limited(_ raw: String?, default defaultValue: Int, max: Int) -> Int {
        guard let raw, let parsed = Int(raw) else { return defaultValue }
        return Swift.max(1, Swift.min(max, parsed))
    }

    private func sendJSON<T: Encodable>(_ value: T, on connection: NWConnection) throws {
        let body = try encoder.encode(value)
        send(status: 200, contentType: "application/json; charset=utf-8", body: body, on: connection)
    }

    private func sendError(status: Int, message: String, on connection: NWConnection) {
        let payload = BridgeErrorPayload(error: message)
        let body = (try? encoder.encode(payload)) ?? Data("{\"error\":\"\(message)\"}".utf8)
        send(status: status, contentType: "application/json; charset=utf-8", body: body, on: connection)
    }

    private func send(status: Int, contentType: String, body: Data, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: status)
        let headers = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func isAllowedClientEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return Self.isAllowedIPv4(address.debugDescription)
        case .ipv6(let address):
            let value = address.debugDescription.lowercased()
            return value == "::1" || value.hasPrefix("fe80:") || value.hasPrefix("fc") || value.hasPrefix("fd")
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    private static func isAllowedIPv4(_ raw: String) -> Bool {
        let octets = raw.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 127 { return true }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 169, octets[1] == 254 { return true }
        return false
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return "bc_live_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return "bc_live_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func firstAvailablePort(preferred: Int) -> Int {
        if preferred > 0, isPortAvailable(preferred) {
            return preferred
        }
        for port in 18_732...18_782 where isPortAvailable(port) {
            return port
        }
        return 0
    }

    private static func isPortAvailable(_ port: Int) -> Bool {
        guard port > 0, port <= Int(UInt16.max) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))

        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func candidateBaseURLs(port: Int) -> [String] {
        var hosts = [
            "127.0.0.1",
            "localhost",
            "host.docker.internal",
            "gateway.docker.internal",
            "host.lima.internal",
        ]
        hosts.append(contentsOf: localIPv4Addresses())

        var seen = Set<String>()
        return hosts.compactMap { host in
            guard !host.isEmpty, seen.insert(host).inserted else { return nil }
            return "http://\(host):\(port)"
        }
    }

    private static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let ip = String(cString: hostname)
            if isAllowedIPv4(ip) {
                result.append(ip)
            }
        }
        return result
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = [UInt8](lhs.utf8)
        let right = [UInt8](rhs.utf8)
        var diff = left.count ^ right.count
        for i in 0..<Swift.max(left.count, right.count) {
            diff |= Int((i < left.count ? left[i] : 0) ^ (i < right.count ? right[i] : 0))
        }
        return diff == 0
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Internal Server Error"
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]

    init?(data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        method = requestParts[0].uppercased()
        let target = requestParts[1]
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return nil }
        path = components.path
        queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders
    }
}

private struct BridgeInfoPayload: Encodable {
    let name: String
    let version: String
    let baseURL: String
    let candidateBaseURLs: [String]
    let boundHost: String
    let database: PathStat
    let activityRoot: String?
    let activityDaysAvailable: [String]
    let endpoints: [String]
}

private struct BridgeDiscoveryPayload: Encodable {
    let name: String
    let version: String
    let baseURL: String
    let candidateBaseURLs: [String]
    let token: String
    let port: Int
    let updatedAt: String
    let endpoints: [String]
}

private struct PathStat: Encodable {
    let path: String?
    let exists: Bool
}

/// Internal (not private) so unit tests can assert on the mapping.
struct LiveTranscriptPayload: Encodable, Equatable {
    struct Entry: Encodable, Equatable {
        let source: String
        let offsetSeconds: Double
        let text: String
        let isFinal: Bool
    }

    /// idle | recording | transcribing | completed | error
    let state: String
    /// True while a recording/transcription session is in progress.
    let isLive: Bool
    let startedAt: String?
    let durationSeconds: Double
    let includesSystemAudio: Bool
    /// Finalized transcript so far, same format the app saves/pastes
    /// (timestamped `[m:ss Source]` lines when system audio is captured).
    let text: String
    /// In-flight partial for each source — the words being spoken right now.
    let micPartial: String
    let systemPartial: String
    let entries: [Entry]
}

private struct BridgeErrorPayload: Encodable {
    let error: String
}
