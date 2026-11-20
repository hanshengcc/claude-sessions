import Foundation

/// Which coding agent CLI owns a session.
public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude, agy

    public var displayName: String { self == .claude ? "Claude" : "agy" }
}

/// One agent session: a Claude Code `.jsonl` file or an agy conversation.
public struct SessionInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let agent: Agent
    public let file: String
    public let cwd: String
    public let gitBranch: String
    public let title: String
    public let firstPrompt: String
    public let lastPrompt: String
    public let startedAt: Date?
    public let updatedAt: Date
    public let size: Int
    public let cacheKey: String

    public var projectName: String { (cwd as NSString).lastPathComponent }
}

/// Fields extracted from session records. Pure value; built by `summarize`.
public struct SessionSummary: Equatable, Sendable {
    public var cwd = ""
    public var gitBranch = ""
    public var firstPrompt = ""
    public var lastPrompt = ""
    public var aiTitle = ""
    public var customTitle = ""
    public var startedAt: Date?
    public var entrypoint = ""
    public var userPromptCount = 0

    /// SDK / headless runs (`sdk-cli`, `sdk-py`, ...) are programmatic, not chats to resume.
    public var isInteractive: Bool { !entrypoint.hasPrefix("sdk") }
    public var hasContent: Bool { isInteractive && (userPromptCount > 0 || !lastPrompt.isEmpty) }
    public var title: String {
        [customTitle, aiTitle, firstPrompt].first { !$0.isEmpty } ?? "(无标题)"
    }
}

public enum SessionIndex {
    static let headBytes = 512 * 1024
    static let tailBytes = 1024 * 1024
    static let maxTextLength = 300

    // Only lines containing one of these get JSON-parsed; tool output lines are huge.
    private static let interestingMarkers = [
        "\"type\":\"user\"", "\"type\":\"ai-title\"", "\"type\":\"custom-title\"",
        "\"type\":\"last-prompt\"", "\"cwd\":\"",
    ].map { Data($0.utf8) }

    // MARK: Parsing

    public static func cleanPrompt(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.isEmpty { return "" }
        let noisePrefixes = ["<local-command", "<command-", "<system-reminder", "<user-prompt-submit", "Caveat:"]
        if noisePrefixes.contains(where: collapsed.hasPrefix) { return "" }
        return String(collapsed.prefix(maxTextLength))
    }

    static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fold parsed JSON records into a summary. Later title / last-prompt records win.
    public static func summarize(_ records: [[String: Any]]) -> SessionSummary {
        var summary = SessionSummary()
        for record in records {
            apply(record, to: &summary)
        }
        return summary
    }

    private static func apply(_ record: [String: Any], to summary: inout SessionSummary) {
        let type = record["type"] as? String
        if summary.cwd.isEmpty, let cwd = record["cwd"] as? String { summary.cwd = cwd }
        if summary.entrypoint.isEmpty, let entry = record["entrypoint"] as? String { summary.entrypoint = entry }
        if summary.gitBranch.isEmpty, let branch = record["gitBranch"] as? String { summary.gitBranch = branch }
        if summary.startedAt == nil, let stamp = record["timestamp"] as? String {
            summary.startedAt = isoFormatter.date(from: stamp)
        }
        switch type {
        case "ai-title":
            if let title = record["aiTitle"] as? String, !title.isEmpty { summary.aiTitle = title }
        case "custom-title":
            if let title = record["customTitle"] as? String, !title.isEmpty { summary.customTitle = title }
        case "last-prompt":
            if let prompt = record["lastPrompt"] as? String { summary.lastPrompt = cleanPrompt(prompt) }
        case "user":
            applyUser(record, to: &summary)
        default:
            break
        }
    }

    private static func applyUser(_ record: [String: Any], to summary: inout SessionSummary) {
        if record["isMeta"] as? Bool == true || record["isSidechain"] as? Bool == true { return }
        guard let message = record["message"] as? [String: Any] else { return }
        let text = cleanPrompt(contentText(message["content"]))
        guard !text.isEmpty else { return }
        summary.userPromptCount += 1
        if summary.firstPrompt.isEmpty { summary.firstPrompt = text }
    }

    /// Split raw bytes into JSON records, skipping lines without interesting markers.
    public static func parseRecords(_ data: Data) -> [[String: Any]] {
        var records: [[String: Any]] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.first == UInt8(ascii: "{") else { continue }
            let lineData = Data(line)
            guard interestingMarkers.contains(where: { lineData.range(of: $0) != nil }) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                records.append(object)
            }
        }
        return records
    }

    // MARK: Files

    /// Head holds cwd + first prompt; Claude Code re-appends titles near the tail.
    static func readHeadAndTail(_ url: URL, size: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if size <= headBytes + tailBytes {
            return try handle.readToEnd() ?? Data()
        }
        var data = try handle.read(upToCount: headBytes) ?? Data()
        try handle.seek(toOffset: UInt64(size - tailBytes))
        data.append(UInt8(ascii: "\n"))
        data.append(try handle.read(upToCount: tailBytes) ?? Data())
        return data
    }

    static func makeCacheKey(size: Int, modified: Date) -> String {
        "\(size):\(modified.timeIntervalSince1970)"
    }

    static func indexFile(_ url: URL, size: Int, modified: Date) throws -> SessionInfo? {
        let summary = summarize(parseRecords(try readHeadAndTail(url, size: size)))
        guard summary.hasContent else { return nil }
        return SessionInfo(
            id: url.deletingPathExtension().lastPathComponent,
            agent: .claude,
            file: url.path,
            cwd: summary.cwd,
            gitBranch: summary.gitBranch,
            title: summary.title,
            firstPrompt: summary.firstPrompt,
            lastPrompt: summary.lastPrompt,
            startedAt: summary.startedAt,
            updatedAt: modified,
            size: size,
            cacheKey: makeCacheKey(size: size, modified: modified)
        )
    }

    static func sessionFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return projectDirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
    }

    /// Scan every session under `root`. Files whose size+mtime match `cache` are
    /// reused without reading. Sessions with no user prompt are dropped.
    public static func scan(root: URL, cache: [String: SessionInfo] = [:]) -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        for url in sessionFiles(in: root) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate
            else { continue }
            if let cached = cache[url.path], cached.cacheKey == makeCacheKey(size: size, modified: modified) {
                sessions.append(cached)
                continue
            }
            do {
                if let info = try indexFile(url, size: size, modified: modified) { sessions.append(info) }
            } catch {
                NSLog("ClaudeSessions: index failed %@: %@", url.path, error.localizedDescription)
            }
        }
        return sessions.filter { !$0.cwd.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
