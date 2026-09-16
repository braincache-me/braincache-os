import ArgumentParser
import Foundation

struct BrainCache: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "braincache",
        abstract: "Read-only command-line access to BrainCache clips, audio transcripts, and activity history.",
        discussion: """
        braincache lets other apps and scripts pull data out of BrainCache.

        It reads directly from the on-disk SQLite database and the activity log
        folder, so the BrainCache app does NOT need to be running. Vector search
        and "ask" require an OpenAI API key (read from BrainCache's Keychain
        entry or from the OPENAI_API_KEY environment variable).

        See docs/CLI.md for the full reference.
        """,
        version: "1.0.0",
        subcommands: [
            Clips.self,
            Audio.self,
            Activity.self,
            Info.self,
        ]
    )
}

BrainCache.main()
