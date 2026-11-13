import AppKit
import SessionCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var ui: UIState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 330, max: 480)
        } detail: {
            DetailView()
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { ToastView() }
        .animation(.spring(duration: 0.3), value: ui.toast)
        .onReceive(store.$sessions) { tabs.bindNewSessions($0) }
        .onChange(of: ui.newSessionToken) { pickFolderForNewSession() }
    }

    private func pickFolderForNewSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "在此新建会话"
        panel.message = "选择 claude 的工作目录"
        panel.directoryURL = tabs.selected.map { URL(fileURLWithPath: $0.cwd) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tabs.newSession(in: url.path)
    }
}

// MARK: Detail

struct DetailView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        Group {
            if tabs.tabs.isEmpty {
                EmptyStateView()
            } else {
                VStack(spacing: 0) {
                    TabBarView()
                    if let tab = tabs.selected, tab.status == .exited {
                        ExitedBar(tab: tab)
                    }
                    TerminalContainer(view: tabs.selected?.view)
                        .padding([.leading, .top], TerminalAppearance.padding)
                        .padding(.trailing, TerminalAppearance.padding / 2)
                        .background(Theme.terminalBackground)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { DetailToolbar() }
    }

    private var title: String {
        guard let tab = tabs.selected else { return "Claude Sessions" }
        if let id = tab.sessionID, let session = store.session(id: id) { return store.displayTitle(session) }
        return "新会话"
    }

    private var subtitle: String {
        guard let tab = tabs.selected else { return "" }
        let rawBranch = tab.sessionID.flatMap(store.session(id:))?.gitBranch ?? ""
        let branch = rawBranch == "HEAD" ? "" : rawBranch
        return abbreviateHome(tab.cwd) + (branch.isEmpty ? "" : "  ⎇ \(branch)")
    }
}

struct DetailToolbar: ToolbarContent {
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var ui: UIState

    private var cwd: String { tabs.selected?.cwd ?? NSHomeDirectory() }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { tabs.newShell(in: cwd) } label: { Label("打开终端", systemImage: "terminal") }
                .help("在 \(abbreviateHome(cwd)) 打开终端标签 (⌘⇧T)")
            Button { openFolder(cwd) } label: { Label("打开所在文件夹", systemImage: "folder") }
                .help("在 Finder 中打开 \(abbreviateHome(cwd)) (⌘⇧O)")
            Menu {
                Button { openInTerminalApp(cwd) } label: { Label("在「终端」App 中打开", systemImage: "macwindow") }
                Button { revealInFinder(cwd) } label: { Label("在 Finder 中选中文件夹", systemImage: "scope") }
                Button { ui.copy(cwd, message: "已复制路径") } label: { Label("复制路径", systemImage: "link") }
                if let tab = tabs.selected, let id = tab.sessionID {
                    Divider()
                    Button { ui.copy(resumeCommand(cwd: tab.cwd, sessionID: id), message: "已复制恢复命令") } label: {
                        Label("复制恢复命令", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("更多操作")
            if tabs.selected != nil {
                ControlGroup {
                    Button { tabs.adjustFontSize(by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("缩小字号 (⌘-)")
                    Button { tabs.adjustFontSize(by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("放大字号 (⌘+)")
                }
            }
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager
    private let recentLimit = 5

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text("Claude Sessions").font(.system(size: 22, weight: .semibold))
                Text("\(store.sessions.count) 个会话 · \(store.recentProjects.count) 个项目")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !store.sessions.isEmpty { recentList }
            HStack(spacing: 18) {
                hint("⌘K", "搜索")
                hint("⌘T", "新建会话")
                hint("⌘1–9", "切换标签")
                hint("⇧↩", "换行")
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("继续最近的会话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(store.visible(query: "", showHidden: false).prefix(recentLimit)) { session in
                RecentSessionCard(session: session) { tabs.open(session) }
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(label).font(.system(size: 11.5))
        }
    }
}

struct RecentSessionCard: View {
    @EnvironmentObject private var store: SessionStore
    let session: SessionInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.displayTitle(session)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Label("\(session.projectName) · \(RelativeTime.short(session.updatedAt))", systemImage: "folder")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(hovering ? 1 : 0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct ExitedBar: View {
    @EnvironmentObject private var tabs: TabManager
    let tab: TerminalTab

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
            Text("会话已结束").foregroundStyle(.secondary)
            Spacer()
            Button { tabs.restart(tab) } label: { Label("重新打开", systemImage: "arrow.clockwise") }
            Button { tabs.close(tab) } label: { Label("关闭标签", systemImage: "xmark") }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.chrome)
        .environment(\.colorScheme, .dark)
    }
}

/// Hosts the selected tab's terminal NSView; switching tabs swaps the subview
/// so every terminal keeps its process and scrollback.
struct TerminalContainer: NSViewRepresentable {
    let view: NSView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

struct ToastView: View {
    @EnvironmentObject private var ui: UIState

    var body: some View {
        if let message = ui.toast {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
