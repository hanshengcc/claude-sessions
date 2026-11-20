import AppKit
import SessionCore
import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabChip(tab: tab, index: index, isSelected: tab.id == tabs.selectedID)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .background(VerticalWheelToHorizontal())
                .onChange(of: tabs.selectedID, initial: true) { _, id in reveal(id, proxy) }
                .onChange(of: tabs.tabs.count) { reveal(tabs.selectedID, proxy) }
            }
            if tabs.tabs.count > 1 { TabListMenu() }
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

    /// Keep the selected chip on screen, e.g. a tab opened past the right edge.
    private func reveal(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        // Wait one runloop so a just-added chip has been laid out.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
        }
    }
}

/// Every open tab in one list, for when the strip is wider than the window.
struct TabListMenu: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        Menu {
            ForEach(tabs.tabs) { tab in
                Toggle(isOn: Binding(get: { tab.id == tabs.selectedID }, set: { _ in tabs.selectedID = tab.id })) {
                    Text(store.title(of: tab))
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 6)
        .help("全部标签（\(tabs.tabs.count) 个）")
    }
}

/// A mouse wheel only scrolls vertically, which a horizontal ScrollView ignores.
/// While the pointer is over this view, vertical wheel deltas are re-sent as horizontal ones.
struct VerticalWheelToHorizontal: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelCatcherView { WheelCatcherView() }
    func updateNSView(_ view: WheelCatcherView, context: Context) {}

    final class WheelCatcherView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.convert(event) ?? event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func convert(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let copy = event.cgEvent?.copy()
            else { return nil }
            let swaps: [(CGEventField, CGEventField)] = [
                (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
                (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
            ]
            for (vertical, horizontal) in swaps {
                copy.setIntegerValueField(horizontal, value: copy.getIntegerValueField(vertical))
                copy.setIntegerValueField(vertical, value: 0)
            }
            let fixedVertical = CGEventField.scrollWheelEventFixedPtDeltaAxis1
            let fixedHorizontal = CGEventField.scrollWheelEventFixedPtDeltaAxis2
            copy.setDoubleValueField(fixedHorizontal, value: copy.getDoubleValueField(fixedVertical))
            copy.setDoubleValueField(fixedVertical, value: 0)
            return NSEvent(cgEvent: copy)
        }
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
            if tab.kind == .agy { AgentBadge() }
            Text(store.title(of: tab))
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
            Button { ui.copy(resumeCommand(cwd: tab.cwd, sessionID: id, agent: tab.kind.agent ?? .claude), message: "已复制恢复命令") } label: {
                Label("复制恢复命令", systemImage: "terminal")
            }
        }
        Button { tabs.newShell(in: tab.cwd) } label: { Label("在此目录打开终端", systemImage: "terminal") }
        Button { openFolder(tab.cwd) } label: { Label("打开所在文件夹", systemImage: "folder") }
        Divider()
        Button { tabs.close(tab) } label: { Label("关闭标签", systemImage: "xmark") }
    }

}

extension SessionStore {
    /// Tab label shared by the Mac tab bar and the phone client.
    func title(of tab: TerminalTab) -> String {
        let folder = (tab.cwd as NSString).lastPathComponent
        if tab.kind == .shell { return "终端 · \(folder)" }
        if let id = tab.sessionID, let session = session(id: id) { return displayTitle(session) }
        return tab.kind == .agy ? "新 agy 会话 · \(folder)" : "新会话 · \(folder)"
    }
}
