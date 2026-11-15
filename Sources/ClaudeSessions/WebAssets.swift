import Foundation

/// Static files for the phone client: `Contents/Resources/Web` in the app
/// bundle, or the repo's `Web/` folder when running from `swift run`.
struct WebAssets {
    struct Asset {
        let data: Data
        let contentType: String
        let cacheControl: String
    }

    private let root: URL?

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/manifest+json",
        "webmanifest": "application/manifest+json",
        "png": "image/png",
        "svg": "image/svg+xml",
    ]

    init() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Web")
        root = [bundled, source].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    func asset(for path: String) -> Asset? {
        guard let root else { return nil }
        let relative = path == "/" ? "index.html" : String(path.drop { $0 == "/" })
        let url = root.appendingPathComponent(relative).standardizedFileURL
        // Never serve anything outside the Web folder.
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let isVendor = relative.hasPrefix("vendor/")
        return Asset(data: data,
                     contentType: Self.types[ext] ?? "application/octet-stream",
                     cacheControl: isVendor ? "public, max-age=604800" : "no-cache")
    }
}
