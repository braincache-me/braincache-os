import Foundation

/// Per-build paths for state that must NOT be shared between dev and prod
/// installs of BrainCache.
///
/// Prod bundle ID keeps the legacy folder/suite names so existing installs
/// don't migrate. Any other bundle ID (e.g. `com.TalkFlow.BrainCache.dev` from
/// `scripts/dev-run.sh`) gets a parallel set of paths so a dev run can't
/// trample the prod database, media folder, or preferences.
///
/// Keychain (OpenAI API key) is intentionally shared — see `Settings.swift`.
enum BuildVariant {

    static let prodBundleID = "com.TalkFlow.BrainCache"

    static var isProd: Bool {
        (Bundle.main.bundleIdentifier ?? "") == prodBundleID
    }

    /// Subfolder name under `~/Library/Application Support/`.
    static var dataFolderName: String {
        isProd ? "ClipVault" : "ClipVault-Dev"
    }

    /// UserDefaults suite for app preferences.
    static var settingsSuiteName: String {
        isProd ? "com.clipvault.settings" : "com.clipvault.settings.dev"
    }

    /// Whether panel windows may appear in screen-recording / screen-sharing
    /// captures. Always `false` in prod. In dev, only `true` when built via
    /// `SCREEN_CAPTURE=1 ./scripts/dev-run.sh` (which defines the
    /// `DEV_SCREEN_CAPTURE` Swift compilation flag).
    static var allowsScreenCapture: Bool {
        #if DEV_SCREEN_CAPTURE
        return !isProd
        #else
        return false
        #endif
    }
}
