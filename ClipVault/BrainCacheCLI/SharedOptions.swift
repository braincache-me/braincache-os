import ArgumentParser

/// Options every subcommand accepts.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Use the development data folder (~/Library/Application Support/ClipVault-Dev).")
    var dev: Bool = false

    @Option(name: .long, help: "Output format: auto (default), json, or table. 'auto' picks json when piped and table on a terminal.")
    var output: OutputMode = .auto

    /// Applies side-effects from global flags. Subcommands should call this in
    /// their `run()` body before doing anything else.
    func apply() {
        BrainCacheConfig.useDevVariant = dev
    }
}

extension OutputMode: ExpressibleByArgument {}
