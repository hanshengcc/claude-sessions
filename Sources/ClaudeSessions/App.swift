import AppKit
import SwiftTerm
import SwiftUI

@main
struct ClaudeSessionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Claude Sessions", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.tabs)
                .environmentObject(appDelegate.ui)
                .environmentObject(appDelegate.remote)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(tabs: appDelegate.tabs, store: appDelegate.store, ui: appDelegate.ui) }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.tabs)
                .environmentObject(appDelegate.remote)
        }
    }
}

/// Cross-view UI signals triggered from menu commands.
@MainActor
final class UIState: ObservableObject {
    @Published var focusSearchToken = 0
    @Published var newSessionToken = 0
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    private static let toastNanoseconds: UInt64 = 1_600_000_000

    /// Short confirmation bubble at the bottom of the window.
    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.toastNanoseconds)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func copy(_ text: String, message: String) {
        copyToPasteboard(text)
        showToast(message)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let tabs = TabManager()
    let ui = UIState()
    lazy var remote = RemoteController(store: store, tabs: tabs)
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = remote
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.reclaimFromPhone(event)
            return Self.handleShiftEnter(event) ? nil : event
        }
        handleLaunchArguments(CommandLine.arguments)
    }

    /// `--new <dir>` starts a session in dir, `--shell <dir>` opens a shell tab, `--open <session-id>` resumes one.
    private func handleLaunchArguments(_ args: [String]) {
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let dir = value(after: "--new") {
            tabs.newSession(in: (dir as NSString).standardizingPath)
        }
        if let dir = value(after: "--shell") {
            tabs.newShell(in: (dir as NSString).standardizingPath)
        }
        if let id = value(after: "--open"), let session = store.findSession(id: id) {
            tabs.open(session)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        tabs.clearSelectedAttention()
    }

    /// Keep serving the phone after the window is closed; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !remote.isEnabled }

    /// Typing into a terminal the phone is driving hands its size back to the Mac.
    private func reclaimFromPhone(_ event: NSEvent) {
        guard let terminal = event.window?.firstResponder as? TerminalView,
              let tab = tabs.tabs.first(where: { $0.view === terminal }) else { return }
        tab.claimForDesktop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = tabs.runningCount
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有 \(running) 个会话在运行"
        alert.informativeText = "退出会结束这些 claude 进程。会话记录都已保存，之后可以从列表里继续。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        tabs.terminateAll()
        return .terminateNow
    }

    /// Shift+Enter inserts a newline in Claude Code's prompt (same bytes as `/terminal-setup`).
    private static func handleShiftEnter(_ event: NSEvent) -> Bool {
        let returnKeyCode: UInt16 = 36
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == returnKeyCode, mods == .shift,
              let terminal = event.window?.firstResponder as? TerminalView
        else { return false }
        terminal.send(data: ArraySlice(Array("\u{1b}\r".utf8)))
        return true
    }
}

struct AppCommands: Commands {
    let tabs: TabManager
    let store: SessionStore
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建会话…") { ui.newSessionToken += 1 }
                .keyboardShortcut("t")
            Button("新建终端标签") { tabs.newShell(in: tabs.selected?.cwd ?? NSHomeDirectory()) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("打开所在文件夹") { openFolder(tabs.selected?.cwd ?? NSHomeDirectory()) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("关闭标签") { tabs.closeSelected() }
                .keyboardShortcut("w")
        }
        CommandGroup(after: .toolbar) {
            Button("放大字号") { tabs.adjustFontSize(by: 1) }
                .keyboardShortcut("=")
            Button("缩小字号") { tabs.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Button("默认字号") { tabs.setFontSize(TerminalAppearance.defaultFontSize) }
                .keyboardShortcut("0")
            Divider()
        }
        CommandMenu("会话") {
            Button("搜索会话") { ui.focusSearchToken += 1 }
                .keyboardShortcut("k")
            Button("刷新列表") { store.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("下一个标签") { tabs.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个标签") { tabs.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { number in
                Button("标签 \(number)") { tabs.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(TabManager.skipPermissionsKey) private var skipPermissions = true
    @AppStorage(TerminalAppearance.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $skipPermissions) {
                    Label {
                        Text("跳过权限确认")
                        Text("启动时带 --dangerously-skip-permissions，和你终端里的 claude 别名一致。只影响之后新开的标签。")
                    } icon: {
                        Image(systemName: "bolt.shield")
                    }
                }
            } header: {
                Text("启动")
            }
            Section {
                LabeledContent {
                    Stepper(value: fontSizeBinding, in: TerminalAppearance.fontSizeRange, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                } label: {
                    Label("终端字号", systemImage: "character.cursor.ibeam")
                }
            } header: {
                Text("终端")
            }
            Section {
                PhoneAccessPanel().padding(-8)
            } header: {
                Text("手机访问")
            }
            Section {
                LabeledContent {
                    Text(tabs.environment?.claudePath ?? "读取中…").textSelection(.enabled)
                } label: {
                    Label("claude 路径", systemImage: "terminal")
                }
                LabeledContent {
                    Text("~/.claude/projects").textSelection(.enabled)
                } label: {
                    Label("会话目录", systemImage: "folder")
                }
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { fontSize }, set: { tabs.setFontSize($0) })
    }
}
