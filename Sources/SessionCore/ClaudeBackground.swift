import Foundation

/// Claude Code background sessions (`claude --bg`, or a session left running when its
/// terminal closed) refuse `--resume`; they have to be opened with `claude attach <id>`.
public enum ClaudeBackground {
    /// The attach id of `sessionID` if `claude agents --json` lists it as a live background session.
    public static func attachID(for sessionID: String, in json: Data) -> String? {
        guard let entries = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        let entry = entries.first { $0["sessionId"] as? String == sessionID && $0["kind"] as? String == "background" }
        return entry?["id"] as? String
    }
}
