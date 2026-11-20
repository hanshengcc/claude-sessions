import Foundation
import SessionCore

/// Environment captured from the user's login shell, so a Finder-launched app
/// sees the same PATH / API settings as the terminal does.
struct ShellEnvironment {
    let variables: [String: String]
    let claudePath: String?
    let agyPath: String?

    private static let envMarker = "__CLAUDE_SESSIONS_ENV__"
    private static let pathMarker = "__CLAUDE_SESSIONS_PATH__"
    private static let agyMarker = "__CLAUDE_SESSIONS_AGY__"
    private static let timeoutSeconds: TimeInterval = 8
    private static let fallbackPaths = ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]

    static func capture() -> ShellEnvironment {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "printf '\(envMarker)\\n'; env; printf '\(pathMarker)\\n'; "
            + "whence -p claude 2>/dev/null || command -v claude; printf '\(agyMarker)\\n'; "
            + "whence -p agy 2>/dev/null || command -v agy"
        let output = run(shell, args: ["-l", "-i", "-c", script]) ?? ""
        var variables = parseEnv(output)
        if variables["PATH"] == nil { variables["PATH"] = ProcessInfo.processInfo.environment["PATH"] }
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }
        let paths = output.components(separatedBy: pathMarker + "\n").last ?? ""
        let parts = paths.components(separatedBy: agyMarker + "\n")
        let trimmed = { (text: String?) in text?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ShellEnvironment(variables: variables,
                                claudePath: resolve("claude", candidate: trimmed(parts.first)),
                                agyPath: resolve("agy", candidate: trimmed(parts.count > 1 ? parts[1] : nil)))
    }

    var asArray: [String] { variables.map { "\($0.key)=\($0.value)" } }

    private static func parseEnv(_ output: String) -> [String: String] {
        guard let start = output.range(of: envMarker + "\n"),
              let end = output.range(of: pathMarker, range: start.upperBound..<output.endIndex)
        else { return [:] }
        var result: [String: String] = [:]
        for line in output[start.upperBound..<end.lowerBound].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        // Shell-session noise that should not leak into child terminals.
        // Claude Code markers would make child sessions think they are nested.
        let dropped = ["SHLVL", "_", "OLDPWD", "PWD", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
                       "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SSE_PORT"]
        for key in dropped {
            result.removeValue(forKey: key)
        }
        return result
    }

    /// `whence -p` skips aliases, so `candidate` is a real path or empty.
    private static func resolve(_ command: String, candidate: String?) -> String? {
        let fm = FileManager.default
        if let candidate, candidate.hasPrefix("/"), fm.isExecutableFile(atPath: candidate) { return candidate }
        return fallbackPaths
            .map { ($0 as NSString).expandingTildeInPath + "/" + command }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// Start the login shell from a clean slate, like Terminal.app does, so nothing
    /// from whoever launched this app (e.g. a running claude) leaks into sessions.
    private static func baseEnvironment() -> [String: String] {
        let keep = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"]
        let current = ProcessInfo.processInfo.environment
        var base = current.filter { keep.contains($0.key) }
        base["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return base
    }

    /// `claude attach` id when `sessionID` is a running background session. Blocking; call off the main thread.
    func backgroundAttachID(for sessionID: String) -> String? {
        guard let claudePath,
              let output = Self.run(claudePath, args: ["agents", "--json"], environment: variables)
        else { return nil }
        return ClaudeBackground.attachID(for: sessionID, in: Data(output.utf8))
    }

    private static func run(_ executable: String, args: [String], environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.environment = environment ?? baseEnvironment()
        do {
            try process.run()
        } catch {
            NSLog("ClaudeSessions: running %@ failed: %@", executable, error.localizedDescription)
            return nil
        }
        let deadline = DispatchTime.now() + timeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
