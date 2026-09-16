import Foundation

/// Runs a locally installed AI coding agent CLI in non-interactive print mode
/// so Ask AI can put a question directly to the agent about past work:
///
///     claude -p --continue --model opus --effort low "<question>"
///     codex exec resume --last --sandbox read-only --skip-git-repo-check "<question>"
///
/// Both invocations resume the most recent conversation for the working
/// directory the process is launched from, so the agent answers with its full
/// session context — much richer than grepping transcript logs when the user
/// asks "How did you do that?".
///
/// Binaries are resolved from the usual install locations directly (GUI apps
/// don't inherit the user's shell PATH) and executed with an argument array —
/// never through a shell — so the model-supplied question can't inject
/// commands. Codex additionally runs with a read-only sandbox: history
/// questions must never mutate the user's files.
final class AgentCLIBridge {

    enum Agent {
        case claude
        case codex

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        var binaryName: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            }
        }

        /// Fallback tool the model should try when the CLI isn't usable.
        var fallbackToolName: String {
            switch self {
            case .claude: return AskAIToolDefinitions.claudeCodeHistoryToolName
            case .codex: return AskAIToolDefinitions.codexHistoryToolName
            }
        }
    }

    /// Keep Ask AI responsive: a stuck CLI call is killed after this long.
    static let timeoutSeconds: TimeInterval = 120
    /// Cap on CLI output handed back to the model.
    static let maxOutputChars = 20_000

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Argument list for the print-mode invocation. Low reasoning effort for
    /// Claude is deliberate: history questions need recall, not deep
    /// reasoning, and it keeps the round-trip short.
    static func buildArguments(agent: Agent, question: String) -> [String] {
        switch agent {
        case .claude:
            return ["-p", "--continue", "--model", "opus", "--effort", "low", question]
        case .codex:
            return ["exec", "resume", "--last",
                    "--sandbox", "read-only", "--skip-git-repo-check", question]
        }
    }

    /// Locates the agent executable in the common install locations.
    func resolveBinary(agent: Agent) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let name = agent.binaryName
        let candidates = [
            home.appendingPathComponent(".claude/local/\(name)"),
            home.appendingPathComponent(".local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Blocking call — run from a background task only. `projectPath` selects
    /// which conversation gets resumed (both CLIs key sessions by working
    /// directory); nil falls back to the user's home directory.
    func ask(agent: Agent, question: String, projectPath: String?) -> String {
        guard let binary = resolveBinary(agent: agent) else {
            return "Error: the \(agent.binaryName) CLI is not installed (looked in "
                + "~/.claude/local, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin). "
                + "Fall back to \(agent.fallbackToolName) instead."
        }

        let workingDirectory: URL
        if let projectPath, !projectPath.isEmpty {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: projectPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "Error: project_path \"\(projectPath)\" is not a directory on this Mac."
            }
            workingDirectory = URL(fileURLWithPath: projectPath)
        } else {
            workingDirectory = fileManager.homeDirectoryForCurrentUser
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.buildArguments(agent: agent, question: question)
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return "Error: failed to launch the \(agent.binaryName) CLI: \(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            return "Error: the \(agent.binaryName) CLI timed out after \(Int(Self.timeoutSeconds))s. "
                + "Fall back to \(agent.fallbackToolName) instead."
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errorText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errorText.isEmpty ? output : errorText
            return "Error: \(agent.binaryName) CLI exited with status \(process.terminationStatus)."
                + (detail.isEmpty ? "" : " Output: \(String(detail.prefix(2_000)))")
        }

        guard !output.isEmpty else {
            return "The \(agent.binaryName) CLI returned no output. There may be no prior "
                + "conversation to resume in \(workingDirectory.path)."
        }
        return String(output.prefix(Self.maxOutputChars))
    }
}
