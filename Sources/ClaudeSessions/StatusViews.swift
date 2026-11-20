import SessionCore
import SwiftUI

/// Session/tab state as an SF Symbol: typing dots while working, bell when it
/// wants you, plain bubble when idle or not open.
struct StatusIcon: View {
    let tab: TerminalTab?
    var size: CGFloat = 13

    var body: some View {
        if let tab {
            LiveStatusIcon(tab: tab, size: size)
        } else {
            Image(systemName: "bubble.left")
                .font(.system(size: size))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct LiveStatusIcon: View {
    @ObservedObject var tab: TerminalTab
    let size: CGFloat

    var body: some View {
        icon
            .font(.system(size: size, weight: .medium))
            .help(label)
            .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var icon: some View {
        if tab.kind == .shell {
            Image(systemName: "terminal.fill")
                .foregroundStyle(tab.status == .working ? Theme.working : Color.secondary)
        } else if tab.needsAttention {
            Image(systemName: "bell.badge.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.attention, Theme.attention.opacity(0.7))
                .symbolEffect(.bounce, value: tab.needsAttention)
        } else {
            switch tab.status {
            case .working:
                Image(systemName: "ellipsis.bubble.fill")
                    .foregroundStyle(Theme.working)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            case .idle:
                Image(systemName: "bubble.left.fill").foregroundStyle(Theme.accent)
            case .exited:
                Image(systemName: "bubble.left").foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        if tab.needsAttention { return "等你回复" }
        switch tab.status {
        case .working: return "运行中"
        case .idle: return "已打开 · 空闲"
        case .exited: return "已退出"
        }
    }
}

/// Icon + text with tight spacing, for metadata lines.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Small "agy" tag that tells agy sessions apart from Claude ones.
struct AgentBadge: View {
    var body: some View {
        Text("agy")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.agy)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.agy.opacity(0.16)))
    }
}
