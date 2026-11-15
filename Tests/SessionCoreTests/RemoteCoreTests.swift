import Foundation
import Testing
@testable import SessionCore

private func text(_ s: String) -> [UInt8] { Array(s.utf8) }

@Test func incrementalSnapshotReturnsOnlyNewBytes() {
    // Arrange
    let buffer = OutputBuffer(capacity: 1024)
    let mark = buffer.append(text("hello\n"))
    buffer.append(text("world"))

    // Act
    let snapshot = buffer.snapshot(since: mark)

    // Assert
    #expect(!snapshot.isFullReplay)
    #expect(snapshot.segments.flatMap(\.bytes) == text("world"))
    #expect(snapshot.end == 11)
}

@Test func staleOffsetFallsBackToFullReplayFromLineBoundary() {
    let buffer = OutputBuffer(capacity: 8)
    buffer.append(text("abc\ndefghij"))  // trimmed to "\ndefghij"... start inside data
    let snapshot = buffer.snapshot(since: 0)
    #expect(snapshot.isFullReplay)
    #expect(snapshot.segments.flatMap(\.bytes) == text("defghij"))
}

@Test func replaySplitsAtResizes() {
    let buffer = OutputBuffer(capacity: 1024, initialSize: .init(cols: 120, rows: 40))
    buffer.append(text("wide\n"))
    buffer.recordResize(.init(cols: 50, rows: 30))
    buffer.append(text("narrow"))

    let snapshot = buffer.snapshot(since: nil)

    #expect(snapshot.segments.map(\.size.cols) == [120, 50])
    #expect(snapshot.segments.map { String(decoding: $0.bytes, as: UTF8.self) } == ["wide\n", "narrow"])
    #expect(buffer.currentSize == .init(cols: 50, rows: 30))
}

@Test func resizeWithoutOutputStillReportsLatestSize() {
    let buffer = OutputBuffer(capacity: 1024, initialSize: .init(cols: 80, rows: 24))
    let mark = buffer.append(text("x"))
    buffer.recordResize(.init(cols: 40, rows: 20))
    let snapshot = buffer.snapshot(since: mark)
    #expect(snapshot.segments.last?.size == .init(cols: 40, rows: 20))
}

@Test func parsesRequestWithBodyQueryAndCookies() {
    let raw = "POST /api/tabs/x/input?since=5 HTTP/1.1\r\nHost: a\r\nCookie: cs_token=abc; other=1\r\n"
        + "Content-Length: 4\r\n\r\nbody"
    guard case .complete(let request) = HTTPParser.parse(Data(raw.utf8)) else {
        Issue.record("expected complete")
        return
    }
    #expect(request.method == "POST")
    #expect(request.path == "/api/tabs/x/input")
    #expect(request.query["since"] == "5")
    #expect(request.cookies["cs_token"] == "abc")
    #expect(request.body == Data("body".utf8))
}

@Test func partialRequestIsIncomplete() {
    #expect(HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)) == .incomplete)
    let raw = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
    #expect(HTTPParser.parse(Data(raw.utf8)) == .incomplete)
    #expect(HTTPParser.parse(Data("garbage\r\n\r\n".utf8)) == .invalid)
}

@Test func onlyPrivateAddressesAreAllowed() {
    for allowed in ["127.0.0.1", "192.168.1.20", "10.0.0.5", "172.20.1.1", "100.101.102.103",
                    "::1", "fd7a:115c:a1e0::1", "fe80::1%en0", "::ffff:192.168.1.2"] {
        #expect(AddressPolicy.isAllowed(allowed), "\(allowed)")
    }
    for denied in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:4860::8888", "::ffff:1.1.1.1", "nonsense"] {
        #expect(!AddressPolicy.isAllowed(denied), "\(denied)")
    }
}
