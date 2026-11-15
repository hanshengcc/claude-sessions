import AppKit
import SessionCore
import SwiftUI

enum SidebarMode: String, CaseIterable {
    case recent = "最近"
    case projects = "项目"

    var icon: String { self == .recent ? "clock" : "folder" }
}

struct SidebarView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var ui: UIState
    @AppStorage("sidebarMode") private var mode: SidebarMode = .recent
    @AppStorage("showHidden") private var showHidden = false
    @State private var query = ""
    /// Row highlight only. AppKit rewrites list selection when rows reorder, so
    /// selection changes must never open sessions; only an explicit click does.
    @State private var highlighted: String?
    @State private var collapsed: Set<String> = []
    @State private var renaming: SessionInfo?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool

    private var visible: [SessionInfo] { store.visible(query: query, showHidden: showHidden) }

    var body: some View {
        List(selection: $highlighted) {
            switch mode {
            case .recent:
                ForEach(visible) { row($0, showProject: true) }
            case .projects:
                ForEach(groupedByProject, id: \.cwd) { group in
                    Section(isExpanded: expandedBinding(group.cwd)) {
                        ForEach(group.sessions) { row($0, showProject: false) }
                    } header: {
                        ProjectHeader(cwd: group.cwd, count: group.sessions.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "搜索标题、内容、路径")
        .searchFocused($searchFocused)
        // Only a real search opens its top hit; a stray Return in an empty field must not.
        .onSubmit(of: .search) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            visible.first.map { tabs.open($0) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { modePicker }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay { if visible.isEmpty { emptyResult } }
        .toolbar {
            ToolbarItem { NewSessionMenu() }
        }
        .onChange(of: ui.focusSearchToken) { searchFocused = true }
        .onChange(of: tabs.selected?.sessionID, initial: true) { _, id in highlighted = id }
        .alert("重命名会话", isPresented: renameBinding) {
            TextField("名称（留空恢复原标题）", text: $renameText)
            Button("保存") { renaming.map { store.rename($0.id, to: renameText) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名称只保存在本 App 中，不会改动 Claude Code 的会话记录。")
        }
    }

    // MARK: Pieces

    private var modePicker: some View {
        Picker("视图", selection: $mode) {
            ForEach(SidebarMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("\(visible.count) 个会话 · \(projectCount) 个项目", systemImage: "tray.full")
                .labelStyle(CompactLabelStyle())
                .foregroundStyle(.secondary)
            Spacer()
            Button { showHidden.toggle() } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
            }
            .help(showHidden ? "不显示已隐藏的会话" : "显示已隐藏的会话")
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新列表")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var emptyResult: some View {
        ContentUnavailableView.search(text: query)
    }

    private var projectCount: Int { Set(visible.map(\.cwd)).count }

    private var groupedByProject: [(cwd: String, sessions: [SessionInfo])] {
        var order: [String] = []
        var groups: [String: [SessionInfo]] = [:]
        for session in visible {
            if groups[session.cwd] == nil { order.append(session.cwd) }
            groups[session.cwd, default: []].append(session)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func row(_ session: SessionInfo, showProject: Bool) -> some View {
        SessionRow(session: session, showProject: showProject)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { tabs.open(session) })
            .tag(session.id)
            .contextMenu { contextMenu(for: session) }
    }

    @ViewBuilder
    private func contextMenu(for session: SessionInfo) -> some View {
        Button { tabs.open(session) } label: { Label("打开", systemImage: "arrow.up.right.square") }
        Button { tabs.newSession(in: session.cwd) } label: {
            Label("在同目录新建会话", systemImage: "plus.bubble")
        }
        Button { tabs.newShell(in: session.cwd) } label: {
            Label("在此目录打开终端", systemImage: "terminal")
        }
        Divider()
        Button {
            renameText = store.aliases[session.id] ?? ""
            renaming = session
        } label: { Label("重命名…", systemImage: "pencil") }
        Button { store.togglePin(session.id) } label: {
            store.pinned.contains(session.id)
                ? Label("取消置顶", systemImage: "pin.slash") : Label("置顶", systemImage: "pin")
        }
        Button { store.toggleHidden(session.id) } label: {
            store.hidden.contains(session.id)
                ? Label("取消隐藏", systemImage: "eye") : Label("隐藏", systemImage: "eye.slash")
        }
        Divider()
        Button { ui.copy(resumeCommand(cwd: session.cwd, sessionID: session.id), message: "已复制恢复命令") } label: {
            Label("复制恢复命令", systemImage: "terminal")
        }
        Button { ui.copy(session.id, message: "已复制会话 ID") } label: { Label("复制会话 ID", systemImage: "number") }
        Button { openFolder(session.cwd) } label: { Label("打开所在文件夹", systemImage: "folder") }
    }

    // MARK: Bindings

    private func expandedBinding(_ cwd: String) -> Binding<Bool> {
        Binding(
            get: { !query.isEmpty || !collapsed.contains(cwd) },
            set: { expanded in collapsed = expanded ? collapsed.subtracting([cwd]) : collapsed.union([cwd]) }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}

struct ProjectHeader: View {
    @EnvironmentObject private var tabs: TabManager
    let cwd: String
    let count: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.accent.opacity(0.85))
            Text((cwd as NSString).lastPathComponent)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            Button { tabs.newSession(in: cwd) } label: { Image(systemName: "plus.bubble") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("在 \(abbreviateHome(cwd)) 新建会话")
        }
        .help(abbreviateHome(cwd))
        .onHover { hovering = $0 }
    }
}

struct NewSessionMenu: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var ui: UIState
    private let recentLimit = 12

    var body: some View {
        Menu {
            Button { ui.newSessionToken += 1 } label: { Label("选择文件夹…", systemImage: "folder.badge.plus") }
            Button { tabs.newShell(in: tabs.selected?.cwd ?? NSHomeDirectory()) } label: {
                Label("新建终端标签", systemImage: "terminal")
            }
            Divider()
            Section("最近的项目") {
                ForEach(store.recentProjects.prefix(recentLimit), id: \.self) { cwd in
                    Button { tabs.newSession(in: cwd) } label: {
                        Label(abbreviateHome(cwd), systemImage: "folder")
                    }
                }
            }
        } label: {
            Label("新建会话", systemImage: "square.and.pencil")
        }
        .help("新建会话 (⌘T)")
    }
}

struct SessionRow: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager
    let session: SessionInfo
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusIcon(tab: tabs.tab(forSession: session.id))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                metaLine
            }
        }
        .padding(.vertical, 3)
        .opacity(store.hidden.contains(session.id) ? 0.45 : 1)
        .help(tooltip)
    }

    private var titleLine: some View {
        HStack(spacing: 4) {
            Text(store.displayTitle(session))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if store.pinned.contains(session.id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(35))
            }
            Spacer(minLength: 6)
            Text(RelativeTime.short(session.updatedAt))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let branch = session.gitBranch == "HEAD" ? "" : session.gitBranch
        if showProject || !branch.isEmpty {
            HStack(spacing: 10) {
                if showProject {
                    Label(session.projectName, systemImage: "folder")
                }
                if !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    /// Latest prompt, unless it just repeats the title.
    private var preview: String {
        let title = store.displayTitle(session)
        return [session.lastPrompt, session.firstPrompt].first { !$0.isEmpty && $0 != title } ?? ""
    }

    private var tooltip: String {
        var lines = [abbreviateHome(session.cwd)]
        if !session.firstPrompt.isEmpty { lines.append("开头：\(session.firstPrompt)") }
        if !session.lastPrompt.isEmpty { lines.append("最后：\(session.lastPrompt)") }
        return lines.joined(separator: "\n")
    }
}
