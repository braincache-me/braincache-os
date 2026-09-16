import Foundation
import Security

/// Resolves on-disk locations and credentials that the BrainCache app maintains.
///
/// The CLI is a separate binary; it does NOT share an in-memory `Settings`
/// instance with the running app. Everything we need is either at a stable
/// filesystem path or stored in the user's defaults / Keychain, both of which
/// the CLI can read directly because the app is not sandboxed.
enum BrainCacheConfig {

    // MARK: - Build variant (mirrors BuildVariant.swift in the app)

    /// The data folder name under `~/Library/Application Support/`. The app
    /// uses `ClipVault` for the prod bundle and `ClipVault-Dev` for dev builds.
    /// We default to prod here because the shipped CLI lives inside the prod
    /// app bundle; `--dev` overrides this for development.
    static let prodDataFolderName = "ClipVault"
    static let devDataFolderName = "ClipVault-Dev"

    static let prodSettingsSuite = "com.clipvault.settings"
    static let devSettingsSuite = "com.clipvault.settings.dev"

    /// Keychain service used by `Settings.openAIAPIKey`.
    static let keychainServiceName = "com.clipvault.openai"
    static let keychainAccountName = "openAIAPIKey"

    /// True when the user passed `--dev` to a CLI command. Stored on
    /// `BrainCacheConfig` so deep helpers can consult it without threading
    /// a parameter through every call site.
    static var useDevVariant: Bool = false

    static var dataFolderName: String {
        useDevVariant ? devDataFolderName : prodDataFolderName
    }

    static var settingsSuiteName: String {
        useDevVariant ? devSettingsSuite : prodSettingsSuite
    }

    // MARK: - Filesystem paths

    static func applicationSupportRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    /// Absolute path to the BrainCache SQLite database.
    /// Equivalent to `DatabaseManager.databaseURL()` in the app.
    static func databaseURL() throws -> URL {
        try applicationSupportRoot()
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent("clipvault.db")
    }

    /// Absolute path to the on-disk media folder (where clipboard images,
    /// HTML/RTF blobs and other large clip payloads are stored).
    static func mediaDirectoryURL() throws -> URL {
        try applicationSupportRoot()
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
    }

    // MARK: - User defaults

    static var defaults: UserDefaults {
        UserDefaults(suiteName: settingsSuiteName) ?? .standard
    }

    /// User-chosen activity capture folder, if any. The app stores the
    /// resolved POSIX path in `activityCaptureLogRootPath` (plain string) so
    /// the CLI doesn't need to resolve a security-scoped bookmark.
    static func activityRootURL() -> URL? {
        guard let path = defaults.string(forKey: "activityCaptureLogRootPath"),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func activityLogsURL() -> URL? {
        activityRootURL()?.appendingPathComponent("logs", isDirectory: true)
    }

    static func activityScreenshotsURL() -> URL? {
        activityRootURL()?.appendingPathComponent("screenshots", isDirectory: true)
    }

    static func activitySummariesURL() -> URL? {
        activityRootURL()?.appendingPathComponent("summaries", isDirectory: true)
    }

    static var embeddingModel: String {
        defaults.string(forKey: "embeddingModel") ?? "text-embedding-3-small"
    }

    // MARK: - OpenAI API key resolution
    //
    // Precedence: OPENAI_API_KEY env var > app's Keychain item > defaults
    // (legacy, only used pre-migration). Returns nil if nothing is configured;
    // callers that require a key surface a friendly error instead of crashing.

    static func openAIAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.isEmpty {
            return env
        }
        if let key = readKeychainAPIKey(), !key.isEmpty {
            return key
        }
        if let legacy = defaults.string(forKey: "openAIAPIKey"), !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    private static func readKeychainAPIKey() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Honour macOS data protection so the prompt happens at most once per
        // session; sandboxless binaries already trip a one-time access ACL
        // dialog the first time they touch the item.
        query[kSecUseDataProtectionKeychain as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
