import SessionCore
import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabChip(tab: tab, index: index, isSelected: tab.id == tabs.selectedID)
                    }
                }
                .padding(.horizontal, 8)
            }
            NewSessionMenu()
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 10)
        }
        .frame(height: 38)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

struct TabChip: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var ui: UIState
    @ObservedObject var tab: TerminalTab
    let index: Int
    let isSelected: Bool
    @State private var hovering = false

    private let minWidth: CGFloat = 120
    private let maxWidth: CGFloat = 230
    private let shortcutLimit = 9

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(tab: tab, size: 11)
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 2)
            trailing
        }
        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.62))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: 26)
        .background(chipBackground)
        .contentShape(Rectangle())
        .onTapGesture { tabs.selectedID = tab.id }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .help("\(abbreviateHome(tab.cwd))\(index < shortcutLimit ? "  ⌘\(index + 1)" : "")")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering || isSelected {
            Button { tabs.close(tab) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .help("关闭标签 (⌘W)")
        } else if index < shortcutLimit {
            Text("⌘\(index + 1)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.3))
                .frame(minWidth: 16)
        }
    }

    private var chipBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(isSelected ? 0.11 : hovering ? 0.05 : 0))
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule().fill(Theme.accent).frame(height: 2).padding(.horizontal, 12)
                }
            }
    }

    @ViewBuilder
    private var menu: some View {
        if tab.status == .exited {
            Button { tabs.restart(tab) } label: { Label("重新打开", systemImage: "arrow.clockwise") }
        }
        if let id = tab.sessionID {
            Button { ui.copy(resumeCommand(cwd: tab.cwd, sessionID: id), message: "已复制恢复命令") } label: {
                Label("复制恢复命令", systemImage: "terminal")
            }
        }
        Button { tabs.newShell(in: tab.cwd) } label: { Label("在此目录打开终端", systemImage: "terminal") }
        Button { openFolder(tab.cwd) } label: { Label("打开所在文件夹", systemImage: "folder") }
        Divider()
        Button { tabs.close(tab) } label: { Label("关闭标签", systemImage: "xmark") }
    }

    private var title: String {
        if tab.kind == .shell { return "终端 · \((tab.cwd as NSString).lastPathComponent)" }
        if let id = tab.sessionID, let session = store.session(id: id) { return store.displayTitle(session) }
        return "新会话 · \((tab.cwd as NSString).lastPathComponent)"
    }
}
