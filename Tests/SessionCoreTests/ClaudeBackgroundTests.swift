import Foundation
import Testing
@testable import SessionCore

private let agentsJSON = Data("""
[
  {"id":"c9d8f35d","kind":"background","sessionId":"c9d8f35d-3296","state":"done","status":"idle"},
  {"pid":1,"kind":"interactive","sessionId":"bfced3c4-1687","status":"busy"}
]
""".utf8)

@Test func backgroundSessionGivesAttachID() {
    #expect(ClaudeBackground.attachID(for: "c9d8f35d-3296", in: agentsJSON) == "c9d8f35d")
}

@Test func interactiveOrUnknownSessionIsNotAttached() {
    #expect(ClaudeBackground.attachID(for: "bfced3c4-1687", in: agentsJSON) == nil)
    #expect(ClaudeBackground.attachID(for: "missing", in: agentsJSON) == nil)
    #expect(ClaudeBackground.attachID(for: "c9d8f35d-3296", in: Data("not json".utf8)) == nil)
}
