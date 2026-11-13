import AppKit
import SessionCore
import SwiftTerm

/// Timestamp of the last process output, written from SwiftTerm's parse thread.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.withLock { last = Date() } }
    var lastOutput: Date { lock.withLock { last } }
}

enum TabStatus {
    case working, idle, exited
}

/// What a tab runs: a claude session, or a plain login shell.
enum TabKind {
    case claude, shell
}

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String
    let kind: TabKind
    let view: LocalProcessTerminalView
    let clock = ActivityClock()
    @Published var sessionID: String?
    @Published var status: TabStatus = .working
    @Published var needsAttention = false
    private(set) var spawnedAt = Date()

    init(cwd: String, sessionID: String?, kind: TabKind = .claude) {
        self.cwd = cwd
        self.kind = kind
        self.sessionID = sessionID
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        TerminalAppearance.apply(to: view)
        let clock = clock
        view.setProcessOutputHandler { clock.touch() }
    }

    func markSpawned() {
        spawnedAt = Date()
        clock.touch()
        status = .working
    }
}

@MainActor
final class TabManager: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedID: UUID? {
        didSet { selected?.needsAttention = false }
    }
    @Published private(set) var environment: ShellEnvironment?

    private var ticker: Timer?
    private var pendingLaunches: [UUID] = []

    private static let quietSeconds: TimeInterval = 2
    private static let tickSeconds: TimeInterval = 0.5
    static let skipPermissionsKey = "skipPermissions"

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.skipPermissionsKey: true])
        Task.detached(priority: .userInitiated) {
            let env = ShellEnvironment.capture()
            await MainActor.run { self.environmentReady(env) }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var selected: TerminalTab? { tabs.first { $0.id == selectedID } }
    var runningCount: Int { tabs.filter { $0.status != .exited }.count }

    func tab(forSession id: String) -> TerminalTab? { tabs.first { $0.sessionID == id } }

    // MARK: Opening

    func open(_ session: SessionInfo) {
        if let existing = tab(forSession: session.id) {
            selectedID = existing.id
            if existing.status == .exited { launch(existing) }
            return
        }
        add(TerminalTab(cwd: session.cwd, sessionID: session.id))
    }

    func newSession(in cwd: String) {
        add(TerminalTab(cwd: cwd, sessionID: nil))
    }

    func newShell(in cwd: String) {
        add(TerminalTab(cwd: cwd, sessionID: nil, kind: .shell))
    }

    func restart(_ tab: TerminalTab) { launch(tab) }

    func close(_ tab: TerminalTab) {
        if tab.status != .exited { tab.view.terminate() }
        let index = tabs.firstIndex { $0.id == tab.id }
        tabs = tabs.filter { $0.id != tab.id }
        guard selectedID == tab.id else { return }
        let nextIndex = min(index ?? 0, tabs.count - 1)
        selectedID = nextIndex >= 0 ? tabs[nextIndex].id : nil
    }

    func closeSelected() { selected.map(close) }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func selectAdjacent(_ offset: Int) {
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    // MARK: Font size

    func adjustFontSize(by delta: Double) {
        setFontSize(TerminalAppearance.fontSize + delta)
    }

    func setFontSize(_ size: Double) {
        let range = TerminalAppearance.fontSizeRange
        let clamped = min(max(size, range.lowerBound), range.upperBound)
        UserDefaults.standard.set(clamped, forKey: TerminalAppearance.fontSizeKey)
        let font = TerminalAppearance.font(size: clamped)
        tabs.forEach { $0.view.font = font }
    }

    func terminateAll() { tabs.filter { $0.status != .exited }.forEach { $0.view.terminate() } }

    private func add(_ tab: TerminalTab) {
        tab.view.processDelegate = self
        tabs = tabs + [tab]
        selectedID = tab.id
        launch(tab)
    }

    private func environmentReady(_ env: ShellEnvironment) {
        environment = env
        let waiting = pendingLaunches
        pendingLaunches = []
        tabs.filter { waiting.contains($0.id) }.forEach(launch)
    }

    private func launch(_ tab: TerminalTab) {
        guard let env = environment else {
            pendingLaunches.append(tab.id)
            tab.view.feed(text: "正在读取 shell 环境…\r\n")
            return
        }
        guard FileManager.default.fileExists(atPath: tab.cwd) else {
            tab.view.feed(text: "\r\n目录不存在：\(tab.cwd)\r\n")
            tab.status = .exited
            return
        }
        if tab.kind == .shell {
            launchShell(tab, env: env)
            return
        }
        guard let claude = env.claudePath else {
            tab.view.feed(text: "\r\n找不到 claude 命令。请确认终端里 `which claude` 有结果。\r\n")
            tab.status = .exited
            return
        }
        var args: [String] = []
        if UserDefaults.standard.bool(forKey: Self.skipPermissionsKey) { args.append("--dangerously-skip-permissions") }
        if let id = tab.sessionID { args += ["--resume", id] }
        tab.markSpawned()
        tab.view.startProcess(executable: claude, args: args, environment: env.asArray,
                              execName: "claude", currentDirectory: tab.cwd)
    }

    private func launchShell(_ tab: TerminalTab, env: ShellEnvironment) {
        let shell = env.variables["SHELL"] ?? "/bin/zsh"
        tab.markSpawned()
        // Leading "-" in argv[0] makes it a login shell, like Terminal.app.
        tab.view.startProcess(executable: shell, args: [], environment: env.asArray,
                              execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: tab.cwd)
    }

    // MARK: New-session binding

    /// A fresh `claude` gets its session id only once it writes a .jsonl;
    /// attach the newest unclaimed session in the same folder.
    func bindNewSessions(_ sessions: [SessionInfo]) {
        let claimed = Set(tabs.compactMap(\.sessionID))
        for tab in tabs where tab.sessionID == nil && tab.kind == .claude {
            let match = sessions.first { session in
                session.cwd == tab.cwd && !claimed.contains(session.id)
                    && (session.startedAt ?? session.updatedAt) >= tab.spawnedAt.addingTimeInterval(-5)
            }
            if let match { tab.sessionID = match.id }
        }
    }

    // MARK: Status

    private func tick() {
        let now = Date()
        let appActive = NSApp.isActive
        for tab in tabs where tab.status != .exited {
            let quiet = now.timeIntervalSince(tab.clock.lastOutput) > Self.quietSeconds
            let next: TabStatus = quiet ? .idle : .working
            if tab.kind == .claude, tab.status == .working, next == .idle, tab.id != selectedID || !appActive {
                tab.needsAttention = true
            }
            if tab.status != next { tab.status = next }
        }
        let waiting = tabs.filter(\.needsAttention).count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    func clearSelectedAttention() { selected?.needsAttention = false }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let tab = tabs.first(where: { $0.view === source }) else { return }
        tab.status = .exited
        tab.needsAttention = false
        tab.view.feed(text: "\r\n\u{1b}[2m[claude 已退出\(exitCode.map { "，代码 \($0)" } ?? "")]\u{1b}[0m\r\n")
    }
}
