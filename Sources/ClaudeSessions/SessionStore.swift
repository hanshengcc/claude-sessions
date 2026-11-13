import Foundation
import SessionCore

/// Session list + the user's local organisation of it (pins, names, hidden).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var pinned: Set<String>
    @Published private(set) var hidden: Set<String>
    @Published private(set) var aliases: [String: String]

    private let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    private let cacheURL: URL
    private var cache: [String: SessionInfo] = [:]
    private var isScanning = false
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private static let refreshInterval: TimeInterval = 4

    init() {
        pinned = Set(defaults.stringArray(forKey: "pinned") ?? [])
        hidden = Set(defaults.stringArray(forKey: "hidden") ?? [])
        aliases = defaults.dictionary(forKey: "aliases") as? [String: String] ?? [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSessions")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cacheURL = support.appendingPathComponent("index-cache-v2.json")
        loadCache()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Index

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let root = root, cache = cache
        Task.detached(priority: .utility) {
            let result = SessionIndex.scan(root: root, cache: cache)
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: [SessionInfo]) {
        isScanning = false
        guard result != sessions else { return }
        sessions = result
        cache = Dictionary(result.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        saveCache()
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let list = try? JSONDecoder().decode([SessionInfo].self, from: data)
        else { return }
        cache = Dictionary(list.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        sessions = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func saveCache() {
        do {
            try JSONEncoder().encode(Array(cache.values)).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("ClaudeSessions: cache save failed: %@", error.localizedDescription)
        }
    }

    // MARK: Queries

    func session(id: String) -> SessionInfo? { sessions.first { $0.id == id } }

    /// Look up a session by id even before the first scan finishes.
    func findSession(id: String) -> SessionInfo? {
        session(id: id) ?? SessionIndex.scan(root: root, cache: cache).first { $0.id == id }
    }

    func displayTitle(_ session: SessionInfo) -> String { aliases[session.id] ?? session.title }

    func visible(query: String, showHidden: Bool) -> [SessionInfo] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let filtered = sessions.filter { session in
            guard showHidden || !hidden.contains(session.id) else { return false }
            guard !terms.isEmpty else { return true }
            let haystack = [displayTitle(session), session.firstPrompt, session.lastPrompt, session.cwd, session.id]
                .joined(separator: " ").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
        let pins = filtered.filter { pinned.contains($0.id) }
        return pins + filtered.filter { !pinned.contains($0.id) }
    }

    /// Unique working directories, most recently used first.
    var recentProjects: [String] {
        var seen = Set<String>()
        return sessions.map(\.cwd).filter { seen.insert($0).inserted }
    }

    // MARK: Mutations

    func togglePin(_ id: String) {
        pinned = pinned.symmetricDifference([id])
        defaults.set(Array(pinned), forKey: "pinned")
    }

    func toggleHidden(_ id: String) {
        hidden = hidden.symmetricDifference([id])
        defaults.set(Array(hidden), forKey: "hidden")
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = aliases
        next[id] = trimmed.isEmpty ? nil : trimmed
        aliases = next
        defaults.set(next, forKey: "aliases")
    }
}
