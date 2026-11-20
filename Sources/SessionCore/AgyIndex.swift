import Foundation
import SQLite3

/// Indexes agy (Antigravity CLI) conversations from `~/.gemini/antigravity-cli`:
/// titles / workspaces / times from `conversation_summaries.db`, prompts from `history.jsonl`.
public enum AgyIndex {
    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".gemini/antigravity-cli")

    static let databaseName = "conversation_summaries.db"
    static let historyName = "history.jsonl"
    static let filePrefix = "agy:"
    private static let unixEpochJulianDay = 2_440_587.5
    private static let secondsPerDay = 86_400.0

    /// Top-level conversations with at least one step; subagent runs (nesting_depth > 0) are skipped.
    static let query = """
        SELECT conversation_id, title, preview, workspace_uris,
               (julianday(last_modified_time) - \(unixEpochJulianDay)) * \(secondsPerDay)
        FROM conversation_summaries
        WHERE nesting_depth = 0 AND step_count > 0
        """

    struct Row: Equatable {
        let id: String
        let title: String
        let preview: String
        let workspaceURIs: String
        let modified: Date
    }

    struct Prompts: Equatable {
        var first = ""
        var last = ""
        var startedAt: Date?
    }

    // MARK: Parsing

    /// First `file://` workspace as a path. agy stores a JSON array of percent-encoded URIs.
    static func workspacePath(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let uris = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return uris.lazy
            .compactMap(URL.init(string:))
            .first { $0.isFileURL }
            .map { $0.path }
    }

    /// Per-conversation first / last real prompt from history; slash commands are noise.
    static func parseHistory(_ data: Data) -> [String: Prompts] {
        var result: [String: Prompts] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = record["conversationId"] as? String,
                  record["type"] as? String != "slash_command",
                  let display = record["display"] as? String
            else { continue }
            let text = SessionIndex.cleanPrompt(display)
            guard !text.isEmpty else { continue }
            var prompts = result[id] ?? Prompts()
            if prompts.first.isEmpty { prompts.first = text }
            prompts.last = text
            if prompts.startedAt == nil, let millis = record["timestamp"] as? Double {
                prompts.startedAt = Date(timeIntervalSince1970: millis / 1000)
            }
            result[id] = prompts
        }
        return result
    }

    static func makeSession(_ row: Row, prompts: Prompts?) -> SessionInfo? {
        guard let cwd = workspacePath(row.workspaceURIs), !cwd.isEmpty else { return nil }
        let preview = SessionIndex.cleanPrompt(row.preview)
        let firstPrompt = [prompts?.first ?? "", preview].first { !$0.isEmpty } ?? ""
        let title = [row.title, firstPrompt].first { !$0.isEmpty } ?? "(无标题)"
        return SessionInfo(
            id: row.id,
            agent: .agy,
            file: filePrefix + row.id,
            cwd: cwd,
            gitBranch: "",
            title: String(title.prefix(SessionIndex.maxTextLength)),
            firstPrompt: firstPrompt,
            lastPrompt: prompts?.last ?? "",
            startedAt: prompts?.startedAt,
            updatedAt: row.modified,
            size: 0,
            cacheKey: String(row.modified.timeIntervalSince1970)
        )
    }

    // MARK: Files

    /// Changes whenever agy writes its database or history; equal stamps mean nothing to rescan.
    public static func stamp(root: URL = defaultRoot) -> String {
        [databaseName, databaseName + "-wal", historyName].map { name -> String in
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    /// A read-only connection to a WAL database cannot start while its -shm file is
    /// missing, which is the normal state when agy is not running. Nothing writes the
    /// database then, so retry as immutable instead of creating files in agy's folder.
    static func readRows(database: URL) throws -> [Row] {
        do {
            return try readRows(path: database.path, flags: SQLITE_OPEN_READONLY)
        } catch {
            var immutable = URLComponents(url: database, resolvingAgainstBaseURL: false)
            immutable?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = immutable?.url?.absoluteString else { throw error }
            return try readRows(path: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        }
    }

    private static func readRows(path: String, flags: Int32) throws -> [Row] {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_busy_timeout(handle, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Row(
                id: text(statement, 0),
                title: text(statement, 1),
                preview: text(statement, 2),
                workspaceURIs: text(statement, 3),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// All agy conversations, newest first. Missing agy install → empty list; unreadable database → nil.
    public static func scan(root: URL = defaultRoot) -> [SessionInfo]? {
        let database = root.appendingPathComponent(databaseName)
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let rows: [Row]
        do {
            rows = try readRows(database: database)
        } catch {
            NSLog("ClaudeSessions: agy index failed: %@", String(describing: error))
            return nil
        }
        let history = (try? Data(contentsOf: root.appendingPathComponent(historyName))).map(parseHistory) ?? [:]
        return rows
            .compactMap { makeSession($0, prompts: history[$0.id]) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    enum IndexError: Error {
        case sqlite(String)
    }
}
