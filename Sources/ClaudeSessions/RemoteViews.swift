import AppKit
import SwiftUI

/// Toolbar entry point: phone icon, highlighted while serving, with a pairing popover.
struct PhoneToolbarButton: View {
    @EnvironmentObject private var remote: RemoteController
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("手机访问", systemImage: remote.activeStreams > 0 ? "iphone.radiowaves.left.and.right" : "iphone")
                .foregroundStyle(remote.isRunning ? Theme.accent : Color.secondary)
        }
        .help(remote.isRunning ? "手机访问已开启\(remote.activeStreams > 0 ? "，\(remote.activeStreams) 台设备在看" : "")" : "用手机访问")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PhoneAccessPanel().frame(width: 340)
        }
    }
}

struct PhoneAccessPanel: View {
    @EnvironmentObject private var remote: RemoteController
    @AppStorage(RemoteController.keepAwakeKey) private var keepAwake = true
    @State private var selectedHost: String?

    private let qrSize: CGFloat = 196

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if remote.isEnabled {
                if let error = remote.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                pairing
                Divider()
                options
            } else {
                Text("开启后，手机浏览器扫码即可查看所有会话、接着和 Claude 对话、打开终端。只接受同一局域网或 Tailscale 内的设备，并需要配对令牌。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .onAppear { remote.refreshAddresses() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("手机访问").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { remote.isEnabled }, set: { remote.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private var statusText: String {
        guard remote.isEnabled else { return "未开启" }
        guard remote.isRunning else { return "正在启动…" }
        return remote.activeStreams > 0 ? "\(remote.activeStreams) 台设备正在使用" : "端口 \(remote.port) · 等待连接"
    }

    @ViewBuilder
    private var pairing: some View {
        if let address = currentAddress {
            let url = remote.pairingURL(for: address)
            VStack(spacing: 10) {
                if let image = QRCode.image(for: url, size: qrSize) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: qrSize, height: qrSize)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                }
                Text("用手机相机扫码，在浏览器中打开")
                    .font(.caption).foregroundStyle(.secondary)
                if remote.addresses.count > 1 {
                    Picker("网络", selection: Binding(get: { address.host }, set: { selectedHost = $0 })) {
                        ForEach(remote.addresses) { Text("\($0.label) · \($0.host)").tag($0.host) }
                    }
                    .labelsHidden()
                } else {
                    Text("\(address.label) · \(address.host)").font(.caption).foregroundStyle(.secondary)
                }
                Button { copyToPasteboard(url) } label: { Label("复制配对链接", systemImage: "link") }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity)
        } else {
            Label("没有找到可用网络。请连上 Wi‑Fi，或安装 Tailscale 后在手机上登录同一账号。",
                  systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("开启期间阻止 Mac 自动睡眠", isOn: Binding(get: { keepAwake }, set: { keepAwake = $0; remote.setKeepAwake($0) }))
            HStack {
                Text(tailscaleHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("重置配对") { remote.regenerateToken() }
                    .help("让所有已配对的手机失效，需要重新扫码")
            }
        }
        .font(.callout)
    }

    private var tailscaleHint: String {
        remote.addresses.contains { $0.kind == .tailscale }
            ? "已检测到 Tailscale，在外面用流量也能连回来。"
            : "离开家里的 Wi‑Fi 也想用？在 Mac 和手机上都装 Tailscale。"
    }

    private var currentAddress: NetworkAddress? {
        remote.addresses.first { $0.host == selectedHost } ?? remote.addresses.first
    }
}

/// Shown over the terminal while a phone owns the pty size.
struct RemoteControlBar: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        if tab.sizeOwner == .remote {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                Text("手机正在使用此会话，终端宽度按手机屏幕排版").foregroundStyle(.secondary)
                Spacer()
                Button { tab.claimForDesktop() } label: { Label("收回到电脑", systemImage: "desktopcomputer") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.chrome)
            .environment(\.colorScheme, .dark)
        }
    }
}
