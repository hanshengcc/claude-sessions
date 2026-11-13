import Foundation
import Testing
@testable import SessionCore

private func jsonl(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

@Test func summarizeTakesLatestTitleAndFirstRealPrompt() {
    // Arrange
    let data = jsonl([
        #"{"type":"mode","mode":"normal"}"#,
        #"{"type":"user","isMeta":true,"cwd":"/repo","gitBranch":"main","timestamp":"2026-11-13T13:06:38.847Z","message":{"content":"<local-command-caveat>x"}}"#,
        #"{"type":"user","cwd":"/repo","message":{"content":[{"type":"text","text":"  修复   登录 bug "}]}}"#,
        #"{"type":"assistant","message":{"content":"ok"}}"#,
        #"{"type":"ai-title","aiTitle":"旧标题"}"#,
        #"{"type":"ai-title","aiTitle":"新标题"}"#,
        #"{"type":"last-prompt","lastPrompt":"再跑一次测试"}"#,
    ])

    // Act
    let summary = SessionIndex.summarize(SessionIndex.parseRecords(data))

    // Assert
    #expect(summary.cwd == "/repo")
    #expect(summary.gitBranch == "main")
    #expect(summary.firstPrompt == "修复 登录 bug")
    #expect(summary.title == "新标题")
    #expect(summary.lastPrompt == "再跑一次测试")
    #expect(summary.startedAt != nil)
    #expect(summary.hasContent)
}

@Test func customTitleBeatsAiTitle() {
    let data = jsonl([
        #"{"type":"custom-title","customTitle":"我的名字"}"#,
        #"{"type":"ai-title","aiTitle":"AI 名字"}"#,
    ])
    #expect(SessionIndex.summarize(SessionIndex.parseRecords(data)).title == "我的名字")
}

@Test func toolResultOnlySessionHasNoContent() {
    let data = jsonl([
        #"{"type":"user","cwd":"/r","message":{"content":[{"type":"tool_result","content":"big"}]}}"#,
        #"{"type":"user","isSidechain":true,"message":{"content":"subagent prompt"}}"#,
    ])
    let summary = SessionIndex.summarize(SessionIndex.parseRecords(data))
    #expect(!summary.hasContent)
    #expect(summary.title == "(无标题)")
}

@Test func parseRecordsSkipsBrokenAndIrrelevantLines() {
    let data = jsonl([#"{"type":"user","message":{"content":"a"#, "not json", #"{"type":"assistant"}"#])
    #expect(SessionIndex.parseRecords(data).isEmpty)
}

@Test func scanReadsDirectoryAndReusesCache() throws {
    // Arrange
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("-repo")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try jsonl([#"{"type":"user","cwd":"/repo","message":{"content":"hello"}}"#])
        .write(to: project.appendingPathComponent("abc.jsonl"))
    try jsonl([#"{"type":"mode"}"#]).write(to: project.appendingPathComponent("empty.jsonl"))

    // Act
    let first = SessionIndex.scan(root: root)
    let cached = first.map { info in
        SessionInfo(id: info.id, file: info.file, cwd: info.cwd, gitBranch: "", title: "from-cache",
                    firstPrompt: "", lastPrompt: "", startedAt: nil, updatedAt: info.updatedAt,
                    size: info.size, cacheKey: info.cacheKey)
    }
    let second = SessionIndex.scan(root: root, cache: Dictionary(uniqueKeysWithValues: cached.map { ($0.file, $0) }))

    // Assert
    #expect(first.map(\.id) == ["abc"])
    #expect(first.first?.title == "hello")
    #expect(second.first?.title == "from-cache")
}

@Test func sdkSessionsAreExcluded() {
    let data = jsonl([#"{"type":"user","entrypoint":"sdk-cli","cwd":"/r","message":{"content":"{\"jsonrpc\":\"2.0\"}"}}"#])
    let summary = SessionIndex.summarize(SessionIndex.parseRecords(data))
    #expect(summary.entrypoint == "sdk-cli")
    #expect(!summary.hasContent)
}
