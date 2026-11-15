import AppKit
import CoreImage.CIFilterBuiltins
import SessionCore

/// Phone access: serves the web client and a small JSON + SSE API over the
/// local network / Tailscale, guarded by a pairing token.
@MainActor
final class RemoteController: ObservableObject {
    static let enabledKey = "remoteEnabled"
    static let portKey = "remotePort"
    static let tokenKey = "remoteToken"
    static let keepAwakeKey = "remoteKeepAwake"
    static let defaultPort = 7631

    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var activeStreams = 0
    @Published private(set) var addresses: [NetworkAddress] = []

    private let store: SessionStore
    private let tabs: TabManager
    private var server: HTTPServer?
    private var sleepActivity: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    private lazy var web = WebAssets()

    private static let cookieName = "cs_token"
    private static let cookieMaxAge = 60 * 60 * 24 * 365
    private static let sessionLimit = 200
    private static let projectLimit = 20
    nonisolated private static let base64Chunk = 48 * 1024
    private static let metaInterval: TimeInterval = 1
    private static let keepAliveEvery = 15

    init(store: SessionStore, tabs: TabManager) {
        self.store = store
        self.tabs = tabs
        defaults.register(defaults: [Self.portKey: Self.defaultPort, Self.keepAwakeKey: true])
        if token.isEmpty { regenerateToken() }
        if isEnabled { start() }
    }

    // MARK: Settings

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var port: Int { defaults.integer(forKey: Self.portKey) }
    var token: String { defaults.string(forKey: Self.tokenKey) ?? "" }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
        objectWillChange.send()
    }

    func setKeepAwake(_ keepAwake: Bool) {
        defaults.set(keepAwake, forKey: Self.keepAwakeKey)
        updateSleepAssertion()
    }

    func regenerateToken() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        defaults.set(bytes.map { String(format: "%02x", $0) }.joined(), forKey: Self.tokenKey)
        objectWillChange.send()
    }

    /// URL that pairs a phone: sets the auth cookie, then opens the app.
    func pairingURL(for address: NetworkAddress) -> String {
        "http://\(address.host):\(port)/pair?t=\(token)"
    }

    func refreshAddresses() { addresses = NetworkAddress.current() }

    // MARK: Lifecycle

    private func start() {
        let server = HTTPServer { [weak self] request, connection in
            Task { @MainActor in self?.handle(request, connection) }
        }
        server.onStateChange = { [weak self] message in
            Task { @MainActor in
                self?.error = message
                self?.isRunning = message == nil
            }
        }
        do {
            try server.start(port: UInt16(clamping: port))
            self.server = server
        } catch {
            self.error = error.localizedDescription
        }
        refreshAddresses()
        updateSleepAssertion()
    }

    private func stop() {
        server?.stop()
        server = nil
        isRunning = false
        updateSleepAssertion()
    }

    private func updateSleepAssertion() {
        let wanted = server != nil && defaults.bool(forKey: Self.keepAwakeKey)
        if wanted, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "手机访问已开启")
        } else if !wanted, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: Routing

    private func handle(_ request: HTTPRequest, _ connection: HTTPConnection) {
        if request.path == "/pair" { return pair(request, connection) }
        guard request.path.hasPrefix("/api/") else { return serveStatic(request, connection) }
        guard isAuthorized(request) else { return connection.respondJSON(["error": "unauthorized"], status: 401) }
        if request.method == "POST", request.header("x-cs") == nil {
            return connection.respondJSON(["error": "missing header"], status: 403)
        }
        let parts = request.path.split(separator: "/").map(String.init) // ["api", ...]
        switch (request.method, parts.dropFirst().first ?? "") {
        case ("GET", "state"): connection.respondJSON(stateJSON())
        case ("POST", "open"): openSession(request, connection)
        case ("POST", "new"): newTab(request, connection)
        case (_, "tab") where parts.count >= 4: tabRoute(parts[2], parts[3], request, connection)
        default: connection.respondJSON(["error": "not found"], status: 404)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let bearer = request.header("authorization").flatMap { header -> String? in
            header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : nil
        }
        // EventSource cannot send headers, and iOS home-screen apps don't share
        // Safari's cookies, so the token may also arrive as `?k=`.
        let presented = bearer ?? request.query["k"] ?? request.cookies[Self.cookieName]
        guard let presented, !token.isEmpty else { return false }
        return constantTimeEquals(presented, token)
    }

    private func pair(_ request: HTTPRequest, _ connection: HTTPConnection) {
        guard let presented = request.query["t"], constantTimeEquals(presented, token) else {
            return connection.respond(status: 401, contentType: "text/html; charset=utf-8",
                                      body: Data(Self.pairFailedPage.utf8))
        }
        let cookie = "\(Self.cookieName)=\(token); Path=/; Max-Age=\(Self.cookieMaxAge); HttpOnly; SameSite=Strict"
        connection.respond(status: 302, headers: ["Location": "/?k=\(token)", "Set-Cookie": cookie], body: Data())
    }

    private func serveStatic(_ request: HTTPRequest, _ connection: HTTPConnection) {
        guard request.method == "GET", let asset = web.asset(for: request.path) else {
            return connection.respond(status: 404, body: Data("not found".utf8))
        }
        connection.respond(status: 200, contentType: asset.contentType,
                           headers: ["Cache-Control": asset.cacheControl], body: asset.data)
    }

    // MARK: API

    private func stateJSON() -> [String: Any] {
        let openByID = Dictionary(tabs.tabs.compactMap { tab in tab.sessionID.map { ($0, tab.id.uuidString) } },
                                  uniquingKeysWith: { a, _ in a })
        let sessions = store.visible(query: "", showHidden: false).prefix(Self.sessionLimit).map { session -> [String: Any] in
            [
                "id": session.id,
                "title": store.displayTitle(session),
                "project": session.projectName,
                "cwd": abbreviateHome(session.cwd),
                "branch": session.gitBranch == "HEAD" ? "" : session.gitBranch,
                "preview": session.lastPrompt.isEmpty ? session.firstPrompt : session.lastPrompt,
                "updatedAt": Int(session.updatedAt.timeIntervalSince1970 * 1000),
                "pinned": store.pinned.contains(session.id),
                "tabId": openByID[session.id] ?? NSNull(),
            ]
        }
        let projects = store.recentProjects.prefix(Self.projectLimit).map { cwd -> [String: Any] in
            ["path": cwd, "name": (cwd as NSString).lastPathComponent, "display": abbreviateHome(cwd)]
        }
        return [
            "host": Host.current().localizedName ?? "Mac",
            "tabs": tabs.tabs.map(tabJSON),
            "sessions": Array(sessions),
            "projects": Array(projects),
        ]
    }

    private func tabJSON(_ tab: TerminalTab) -> [String: Any] {
        [
            "id": tab.id.uuidString,
            "sessionId": tab.sessionID ?? NSNull(),
            "kind": tab.kind == .shell ? "shell" : "claude",
            "title": title(of: tab),
            "project": (tab.cwd as NSString).lastPathComponent,
            "cwd": abbreviateHome(tab.cwd),
            "status": statusName(tab),
            "attention": tab.needsAttention,
            "owner": tab.sizeOwner == .remote ? "remote" : "desktop",
        ]
    }

    private func title(of tab: TerminalTab) -> String {
        if tab.kind == .shell { return "终端 · \((tab.cwd as NSString).lastPathComponent)" }
        if let id = tab.sessionID, let session = store.session(id: id) { return store.displayTitle(session) }
        return "新会话 · \((tab.cwd as NSString).lastPathComponent)"
    }

    private func statusName(_ tab: TerminalTab) -> String {
        switch tab.status {
        case .working: return "working"
        case .idle: return "idle"
        case .exited: return "exited"
        }
    }

    private func body(_ request: HTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
    }

    private func openSession(_ request: HTTPRequest, _ connection: HTTPConnection) {
        guard let id = body(request)["sessionId"] as? String, let session = store.findSession(id: id) else {
            return connection.respondJSON(["error": "unknown session"], status: 404)
        }
        let tab = tabs.open(session, select: false)
        connection.respondJSON(["tabId": tab.id.uuidString])
    }

    private func newTab(_ request: HTTPRequest, _ connection: HTTPConnection) {
        let payload = body(request)
        let path = ((payload["cwd"] as? String) ?? "~") as NSString
        let cwd = path.expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return connection.respondJSON(["error": "目录不存在"], status: 400)
        }
        let tab = payload["kind"] as? String == "shell"
            ? tabs.newShell(in: cwd, select: false)
            : tabs.newSession(in: cwd, select: false)
        connection.respondJSON(["tabId": tab.id.uuidString])
    }

    private func tabRoute(_ rawID: String, _ action: String, _ request: HTTPRequest, _ connection: HTTPConnection) {
        guard let id = UUID(uuidString: rawID), let tab = tabs.tab(id: id) else {
            return connection.respondJSON(["error": "tab not found"], status: 404)
        }
        let payload = body(request)
        switch (request.method, action) {
        case ("GET", "stream"):
            stream(tab, request, connection)
        case ("POST", "input"):
            guard let text = payload["data"] as? String else { return connection.respondJSON([:], status: 400) }
            tab.send(Array(text.utf8))
            connection.respondJSON(["ok": true])
        case ("POST", "resize"):
            guard let cols = payload["cols"] as? Int, let rows = payload["rows"] as? Int,
                  (10...500).contains(cols), (4...300).contains(rows)
            else { return connection.respondJSON([:], status: 400) }
            tab.claimForRemote(cols: cols, rows: rows)
            connection.respondJSON(["ok": true])
        case ("POST", "close"):
            tabs.close(tab)
            connection.respondJSON(["ok": true])
        case ("POST", "restart"):
            tabs.restart(tab)
            connection.respondJSON(["ok": true])
        default:
            connection.respondJSON(["error": "not found"], status: 404)
        }
    }

    // MARK: Streaming

    private func stream(_ tab: TerminalTab, _ request: HTTPRequest, _ connection: HTTPConnection) {
        let since = (request.header("last-event-id") ?? request.query["since"]).flatMap { UInt64($0) }
        connection.startEventStream()
        let subscription = tab.bridge.attach(since: since, replay: { snapshot in
            if snapshot.isFullReplay { connection.sendEvent(name: "reset", data: "{}") }
            for segment in snapshot.segments {
                connection.sendEvent(name: "resize", data: Self.sizeJSON(segment.size))
                Self.sendData(segment.bytes, end: nil, to: connection)
            }
            connection.sendComment("replayed")
            connection.sendEvent(name: "sync", data: "{}", id: String(snapshot.end))
        }, handler: { event in
            switch event {
            case .data(let bytes, let end): Self.sendData(bytes, end: end, to: connection)
            case .resize(let size): connection.sendEvent(name: "resize", data: Self.sizeJSON(size))
            case .exit(let code): connection.sendEvent(name: "exit", data: "{\"code\":\(code.map(String.init) ?? "null")}")
            }
        })
        tab.remoteAttached()
        activeStreams += 1

        var lastMeta = ""
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: Self.metaInterval, repeats: true) { [weak self, weak tab] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let tab, self.tabs.tab(id: tab.id) != nil else {
                    connection.sendEvent(name: "gone", data: "{}")
                    connection.close()
                    return
                }
                let meta = Self.jsonString(self.tabJSON(tab))
                if meta != lastMeta { connection.sendEvent(name: "meta", data: meta); lastMeta = meta }
                ticks += 1
                if ticks % Self.keepAliveEvery == 0 { connection.sendComment("ping") }
            }
        }
        timer.fire()
        connection.onClose { [weak self, weak tab] in
            Task { @MainActor in
                timer.invalidate()
                tab?.bridge.unsubscribe(subscription)
                tab?.remoteDetached()
                self?.activeStreams -= 1
            }
        }
    }

    nonisolated private static func sendData(_ bytes: [UInt8], end: UInt64?, to connection: HTTPConnection) {
        var start = 0
        while start < bytes.count {
            let stop = min(start + base64Chunk, bytes.count)
            let isLast = stop == bytes.count
            connection.sendEvent(name: "data", data: Data(bytes[start..<stop]).base64EncodedString(),
                                 id: isLast ? end.map(String.init) : nil)
            start = stop
        }
    }

    nonisolated private static func sizeJSON(_ size: OutputBuffer.Size) -> String {
        "{\"cols\":\(size.cols),\"rows\":\(size.rows)}"
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let pairFailedPage = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <body style="font:16px -apple-system;background:#161619;color:#eee;padding:40px 24px">
    <h2>配对链接已失效</h2><p>请在 Mac 上的 Claude Sessions 里点「手机」按钮，重新扫码。</p></body>
    """
}

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

// MARK: - Addresses & QR

struct NetworkAddress: Hashable, Identifiable {
    enum Kind { case tailscale, lan }
    let host: String
    let interface: String
    let kind: Kind

    var id: String { host }
    var label: String { kind == .tailscale ? "Tailscale（任何网络）" : "局域网（同一 Wi‑Fi）" }

    static func current() -> [NetworkAddress] {
        var result: [NetworkAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            let name = String(cString: entry.pointee.ifa_name)
            guard host != "127.0.0.1", AddressPolicy.isAllowed(host), !host.hasPrefix("169.254.") else { continue }
            let kind: Kind = host.hasPrefix("100.") && name.hasPrefix("utun") ? .tailscale : .lan
            result.append(NetworkAddress(host: host, interface: name, kind: kind))
        }
        let unique = Array(Set(result))
        return unique.sorted { ($0.kind == .tailscale ? 0 : 1, $0.interface) < ($1.kind == .tailscale ? 0 : 1, $1.interface) }
    }
}

enum QRCode {
    static func image(for text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
