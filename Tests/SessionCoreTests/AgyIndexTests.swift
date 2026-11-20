import Foundation
import Testing
@testable import SessionCore

@Test func workspacePathDecodesPercentEncodedFileURI() {
    let json = #"["file:///Users/me/Documents/%E5%AD%A6%E4%B9%A0"]"#
    #expect(AgyIndex.workspacePath(json) == "/Users/me/Documents/学习")
}

@Test func workspacePathRejectsMissingOrNonFileURIs() {
    #expect(AgyIndex.workspacePath("[]") == nil)
    #expect(AgyIndex.workspacePath(#"["https://example.com"]"#) == nil)
    #expect(AgyIndex.workspacePath("not json") == nil)
}

@Test func parseHistorySkipsSlashCommandsAndUnassignedPrompts() {
    // Arrange
    let data = Data("""
    {"display":"/model","timestamp":1000,"conversationId":"c1","type":"slash_command"}
    {"display":"没有会话 id","timestamp":1500}
    {"display":"  第一句  ","timestamp":2000,"conversationId":"c1"}
    {"display":"最后一句","timestamp":3000,"conversationId":"c1"}
    {"display":"/exit","timestamp":4000,"conversationId":"c1","type":"slash_command"}
    """.utf8)

    // Act
    let prompts = AgyIndex.parseHistory(data)

    // Assert
    #expect(prompts.count == 1)
    #expect(prompts["c1"]?.first == "第一句")
    #expect(prompts["c1"]?.last == "最后一句")
    #expect(prompts["c1"]?.startedAt == Date(timeIntervalSince1970: 2))
}

@Test func makeSessionFallsBackToPreviewAndSkipsMissingWorkspace() {
    let row = AgyIndex.Row(id: "c1", title: "", preview: "预览文字", workspaceURIs: #"["file:///repo"]"#,
                           modified: Date(timeIntervalSince1970: 10))
    let session = AgyIndex.makeSession(row, prompts: nil)
    #expect(session?.agent == .agy)
    #expect(session?.cwd == "/repo")
    #expect(session?.title == "预览文字")
    #expect(session?.firstPrompt == "预览文字")

    let homeless = AgyIndex.Row(id: "c2", title: "t", preview: "", workspaceURIs: "[]", modified: Date())
    #expect(AgyIndex.makeSession(homeless, prompts: nil) == nil)
}

@Test func scanReadsTopLevelConversationsNewestFirst() throws {
    // Arrange
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // WAL like agy's real database; when agy is not running its -wal / -shm files are absent.
    let sql = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE conversation_summaries (conversation_id text, title text, preview text, step_count integer,
      last_modified_time datetime, workspace_uris text, nesting_depth integer);
    INSERT INTO conversation_summaries VALUES
      ('old', '旧会话', '', 5, '2026-11-01 10:00:00.5+00:00', '["file:///a"]', 0),
      ('new', '新会话', '', 5, '2026-11-02 10:00:00.123456+00:00', '["file:///b"]', 0),
      ('sub', '子代理', '', 5, '2026-11-03 10:00:00+00:00', '["file:///b"]', 1),
      ('empty', '空', '', 0, '2026-11-03 10:00:00+00:00', '["file:///b"]', 0);
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [root.appendingPathComponent(AgyIndex.databaseName).path, sql]
    try process.run()
    process.waitUntilExit()
    try Data(#"{"display":"你好","timestamp":1,"conversationId":"new"}"#.utf8)
        .write(to: root.appendingPathComponent(AgyIndex.historyName))

    for suffix in ["-shm", "-wal"] {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(AgyIndex.databaseName + suffix))
    }

    // Act
    let sessions = try #require(AgyIndex.scan(root: root))

    // Assert
    #expect(sessions.map(\.id) == ["new", "old"])
    #expect(sessions.first?.lastPrompt == "你好")
    let expected = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!.timeIntervalSince1970 + 0.123456
    #expect(abs((sessions.first?.updatedAt.timeIntervalSince1970 ?? 0) - expected) < 0.01)
}
