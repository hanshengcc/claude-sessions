import AppKit
import SessionCore
import SwiftTerm

enum TabStatus {
    case working, idle, exited
}

/// What a tab runs: a claude session, or a plain login shell.
enum TabKind {
    case claude, shell
}

/// Who decides the pty size: the Mac window, or a phone that is driving the session.
enum SizeOwner {
    case desktop, remote
}

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String
    let kind: TabKind
    let view: TerminalView
    let bridge: ProcessBridge
    @Published var sessionID: String?
    @Published var status: TabStatus = .working
    @Published var needsAttention = false
    @Published private(set) var sizeOwner: SizeOwner = .desktop
    @Published private(set) var remoteViewers = 0
    private(set) var spawnedAt = Date()
    private(set) var process: LocalProcess?
    private var desktopSize = OutputBuffer.Size(cols: 80, rows: 24)
    private var remoteSize: OutputBuffer.Size?

    var clock: ActivityClock { bridge.clock }
    var output: OutputBuffer { bridge.output }
    var isRunning: Bool { status != .exited }

    init(cwd: String, sessionID: String?, kind: TabKind = .claude) {
        self.cwd = cwd
        self.kind = kind
        self.sessionID = sessionID
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        bridge = ProcessBridge(view: view)
        TerminalAppearance.apply(to: view)
    }

    func start(executable: String, args: [String], environment: [String], execName: String) {
        spawnedAt = Date()
        clock.touch()
        status = .working
        let process = LocalProcess(delegate: bridge, dispatchQueue: bridge.queue)
        self.process = process
        applySize()
        process.startProcess(executable: executable, args: args, environment: environment,
                             execName: execName, currentDirectory: cwd)
    }

    func send(_ bytes: [UInt8]) {
        guard isRunning else { return }
        process?.send(data: bytes[...])
    }

    func terminate() {
        if isRunning { process?.terminate() }
    }

    // MARK: Size ownership

    func desktopResized(cols: Int, rows: Int) {
        desktopSize = OutputBuffer.Size(cols: cols, rows: rows)
        if sizeOwner == .desktop { applySize() }
    }

    func claimForRemote(cols: Int, rows: Int) {
        remoteSize = OutputBuffer.Size(cols: cols, rows: rows)
        sizeOwner = .remote
        applySize()
    }

    func claimForDesktop() {
        guard sizeOwner == .remote else { return }
        sizeOwner = .desktop
        applySize()
    }

    func remoteAttached() { remoteViewers += 1 }

    func remoteDetached() {
        remoteViewers = max(0, remoteViewers - 1)
        if remoteViewers == 0 { claimForDesktop() }
    }

    private func applySize() {
        let size = sizeOwner == .remote ? (remoteSize ?? desktopSize) : desktopSize
        bridge.resize(size, process: process)
    }
}

@MainActor
final class TabManager: NSObject, ObservableObject, TerminalViewDelegate {
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

    func tab(id: UUID) -> TerminalTab? { tabs.first { $0.id == id } }

    @discardableResult
    func open(_ session: SessionInfo, select: Bool = true) -> TerminalTab {
        if let existing = tab(forSession: session.id) {
            if select { selectedID = existing.id }
            if existing.status == .exited { launch(existing) }
            return existing
        }
        return add(TerminalTab(cwd: session.cwd, sessionID: session.id), select: select)
    }

    @discardableResult
    func newSession(in cwd: String, select: Bool = true) -> TerminalTab {
        add(TerminalTab(cwd: cwd, sessionID: nil), select: select)
    }

    @discardableResult
    func newShell(in cwd: String, select: Bool = true) -> TerminalTab {
        add(TerminalTab(cwd: cwd, sessionID: nil, kind: .shell), select: select)
    }

    func restart(_ tab: TerminalTab) { launch(tab) }

    func close(_ tab: TerminalTab) {
        tab.terminate()
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

    func terminateAll() { tabs.forEach { $0.terminate() } }

    private func add(_ tab: TerminalTab, select: Bool) -> TerminalTab {
        tab.view.terminalDelegate = self
        tab.bridge.onExit = { [weak self, weak tab] code in
            Task { @MainActor in
                guard let self, let tab else { return }
                self.processExited(tab, code: code)
            }
        }
        tabs = tabs + [tab]
        if select || selectedID == nil { selectedID = tab.id }
        launch(tab)
        return tab
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
            tab.bridge.inject("正在读取 shell 环境…\r\n")
            return
        }
        guard FileManager.default.fileExists(atPath: tab.cwd) else {
            tab.bridge.inject("\r\n目录不存在：\(tab.cwd)\r\n")
            tab.status = .exited
            return
        }
        if tab.kind == .shell {
            launchShell(tab, env: env)
            return
        }
        guard let claude = env.claudePath else {
            tab.bridge.inject("\r\n找不到 claude 命令。请确认终端里 `which claude` 有结果。\r\n")
            tab.status = .exited
            return
        }
        var args: [String] = []
        if UserDefaults.standard.bool(forKey: Self.skipPermissionsKey) { args.append("--dangerously-skip-permissions") }
        if let id = tab.sessionID { args += ["--resume", id] }
        tab.start(executable: claude, args: args, environment: env.asArray, execName: "claude")
    }

    private func launchShell(_ tab: TerminalTab, env: ShellEnvironment) {
        let shell = env.variables["SHELL"] ?? "/bin/zsh"
        // Leading "-" in argv[0] makes it a login shell, like Terminal.app.
        tab.start(executable: shell, args: [], environment: env.asArray,
                  execName: "-" + (shell as NSString).lastPathComponent)
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

    // MARK: TerminalViewDelegate (desktop terminal views)

    private func owner(of view: TerminalView) -> TerminalTab? { tabs.first { $0.view === view } }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        owner(of: source)?.desktopResized(cols: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        owner(of: source)?.send(Array(data))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func processExited(_ tab: TerminalTab, code: Int32?) {
        tab.status = .exited
        tab.needsAttention = false
        let name = tab.kind == .shell ? "终端" : "claude"
        tab.bridge.inject("\r\n\u{1b}[2m[\(name) 已退出\(code.map { "，代码 \($0)" } ?? "")]\u{1b}[0m\r\n")
    }
}
