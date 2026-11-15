import AppKit
import SessionCore
import SwiftTerm

/// Timestamp of the last process output, written from the pty queue.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.withLock { last = Date() } }
    var lastOutput: Date { lock.withLock { last } }
}

/// What remote viewers receive, in pty order.
enum StreamEvent: Sendable {
    case data(bytes: [UInt8], end: UInt64)
    case resize(OutputBuffer.Size)
    case exit(code: Int32?)
}

/// Owns the pty side of one tab: fans process output out to the desktop
/// terminal view, the replay buffer and any remote (phone) subscribers.
/// Data, resizes and exit all run on one serial queue so they stay ordered.
final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    static let bufferCapacity = 2 * 1024 * 1024

    let queue = DispatchQueue(label: "claude-sessions.pty", qos: .userInteractive)
    let output = OutputBuffer(capacity: bufferCapacity)
    let clock = ActivityClock()
    var onExit: (@Sendable (Int32?) -> Void)?

    private weak var view: TerminalView?
    private let lock = NSLock()
    private var size = OutputBuffer.Size(cols: 80, rows: 24)
    private var subscribers: [UUID: @Sendable (StreamEvent) -> Void] = [:]

    init(view: TerminalView) {
        self.view = view
    }

    var currentSize: OutputBuffer.Size { lock.withLock { size } }

    // MARK: Subscribers

    func subscribe(_ handler: @escaping @Sendable (StreamEvent) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { subscribers[id] = handler }
        return id
    }

    /// Atomically snapshot the replay buffer and start receiving live events, so
    /// no output falls between the two (both happen on the pty queue).
    /// `replay` runs before any live event is delivered, keeping the stream ordered.
    func attach(since: UInt64?, replay: (OutputBuffer.Snapshot) -> Void,
                handler: @escaping @Sendable (StreamEvent) -> Void) -> UUID {
        queue.sync {
            replay(output.snapshot(since: since))
            return subscribe(handler)
        }
    }

    func unsubscribe(_ id: UUID) {
        _ = lock.withLock { subscribers.removeValue(forKey: id) }
    }

    private func emit(_ event: StreamEvent) {
        let handlers = lock.withLock { Array(subscribers.values) }
        handlers.forEach { $0(event) }
    }

    // MARK: Output

    /// Local notices (e.g. "claude exited") go through the same path as process output.
    func inject(_ text: String) {
        let bytes = Array(text.utf8)
        queue.async { self.deliver(bytes[...]) }
    }

    private func deliver(_ slice: ArraySlice<UInt8>) {
        view?.feed(byteArray: slice)
        let end = output.append(slice)
        clock.touch()
        emit(.data(bytes: Array(slice), end: end))
    }

    func resize(_ newSize: OutputBuffer.Size, process: LocalProcess?) {
        queue.async {
            self.lock.withLock { self.size = newSize }
            self.output.recordResize(newSize)
            var window = winsize(ws_row: UInt16(newSize.rows), ws_col: UInt16(newSize.cols), ws_xpixel: 0, ws_ypixel: 0)
            process?.updateWindowSize(&window)
            self.emit(.resize(newSize))
        }
    }

    // MARK: LocalProcessDelegate (called on `queue`)

    func dataReceived(slice: ArraySlice<UInt8>) { deliver(slice) }

    func getWindowSize() -> winsize {
        let current = currentSize
        return winsize(ws_row: UInt16(current.rows), ws_col: UInt16(current.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        emit(.exit(code: exitCode))
        onExit?(exitCode)
    }
}
