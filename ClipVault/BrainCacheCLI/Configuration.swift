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

    /// Keychain service used by `Settings.openAIAPIKey`. The account name is
    /// still `openAIAPIKey` regardless of provider — the app keeps that
    /// storage key for backward compatibility.
    static let keychainServiceName = "com.clipvault.openai"
    static let keychainAccountName = "openAIAPIKey"

    /// Default base URLs, mirroring `AIProvider.defaultBaseURL` in the app.
    static let nebiusBaseURL = "https://api.tokenfactory.nebius.com/v1"
    static let openAIBaseURL = "https://api.openai.com/v1"

    /// Dimension count stored in `clip_embeddings` (`EmbeddingGenerator.dimensions`).
    static let embeddingDimensions = 256

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

    // MARK: - AI provider

    /// The provider the app has selected (`aiProvider` in the shared defaults
    /// suite). Defaults to Nebius Token Factory, matching the app.
    static var aiProvider: String {
        defaults.string(forKey: "aiProvider") ?? "nebius"
    }

    /// Base URL of the OpenAI-compatible API the CLI should talk to.
    ///
    /// Precedence: `AI_BASE_URL` env var > the app's `aiBaseURL` (only stored
    /// for the custom provider) > the selected provider's default.
    static var aiBaseURL: String {
        if let env = ProcessInfo.processInfo.environment["AI_BASE_URL"], !env.isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if aiProvider == "custom",
           let stored = defaults.string(forKey: "aiBaseURL")?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return aiProvider == "openai" ? openAIBaseURL : nebiusBaseURL
    }

    /// Embedding model the app is configured to use, defaulting per provider.
    static var embeddingModel: String {
        if let stored = defaults.string(forKey: "embeddingModel"), !stored.isEmpty {
            return stored
        }
        return aiProvider == "openai" ? "text-embedding-3-small" : "Qwen/Qwen3-Embedding-8B"
    }

    // MARK: - API key resolution
    //
    // Precedence: NEBIUS_API_KEY / OPENAI_API_KEY env vars > app's Keychain
    // item > defaults (legacy, only used pre-migration). Returns nil if
    // nothing is configured; callers that require a key surface a friendly
    // error instead of crashing.

    static func openAIAPIKey() -> String? {
        for name in ["NEBIUS_API_KEY", "OPENAI_API_KEY"] {
            if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty {
                return env
            }
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
