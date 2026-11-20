import AppKit
import SwiftTerm
import SessionCore
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.89, green: 0.46, blue: 0.30)
    static let accentNS = NSColor(srgbRed: 0.89, green: 0.46, blue: 0.30, alpha: 1)
    static let working = Color(red: 0.36, green: 0.78, blue: 0.47)
    static let attention = Color(red: 0.98, green: 0.66, blue: 0.24)
    static let agy = Color(red: 0.36, green: 0.58, blue: 0.98)
    static let terminalBackground = Color(nsColor: TerminalAppearance.background)
    static let chrome = Color(nsColor: TerminalAppearance.chrome)
}

enum TerminalAppearance {
    static let background = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.098, alpha: 1)
    static let chrome = NSColor(srgbRed: 0.118, green: 0.114, blue: 0.129, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.89, green: 0.88, blue: 0.86, alpha: 1)
    static let padding: CGFloat = 10
    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 10...22
    static let fontSizeKey = "terminalFontSize"

    static var fontSize: Double {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored == 0 ? defaultFontSize : stored
    }

    /// Muted ANSI palette tuned for the dark background (normal 0-7, bright 8-15).
    private static let ansiHex: [UInt32] = [
        0x2A2A30, 0xE5676B, 0x7CC489, 0xE3B66B, 0x6FA3E8, 0xC08BE0, 0x63C3CC, 0xD4D2CC,
        0x5C5B63, 0xF08A8D, 0x9AD8A5, 0xF0CB8A, 0x93BCF2, 0xD4A9EE, 0x87D6DD, 0xF5F4F0,
    ]

    private static func termColor(_ hex: UInt32) -> SwiftTerm.Color {
        func channel(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) }
        return SwiftTerm.Color(red8: channel(16), green8: channel(8), blue8: channel(0))
    }

    static func font(size: Double) -> NSFont {
        NSFont(name: "SF Mono", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @MainActor static func apply(to view: TerminalView) {
        view.font = font(size: fontSize)
        view.installColors(ansiHex.map(termColor))
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = Theme.accentNS
        view.selectedTextBackgroundColor = Theme.accentNS.withAlphaComponent(0.35)
        view.optionAsMetaKey = true
    }
}

enum RelativeTime {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    /// 刚刚 / 5 分钟前 / 3 小时前 / 昨天 14:20 / 11月2日 / 2025/3/1
    static func short(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        let calendar = Calendar.current
        if elapsed < minute { return "刚刚" }
        if elapsed < hour { return "\(Int(elapsed / minute)) 分钟前" }
        if calendar.isDateInToday(date) { return "\(Int(elapsed / hour)) 小时前" }
        if calendar.isDateInYesterday(date) { return "昨天 \(timeFormatter.string(from: date))" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dateFormatter.string(from: date)
        }
        return yearFormatter.string(from: date)
    }
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func resumeCommand(cwd: String, sessionID: String, agent: Agent) -> String {
    let resume = agent == .agy ? "agy --conversation" : "claude --resume"
    return "cd \(shellQuote(cwd)) && \(resume) \(sessionID)"
}

func openInTerminalApp(_ path: String) {
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal,
                            configuration: NSWorkspace.OpenConfiguration())
}

/// Open the folder itself in a Finder window.
func openFolder(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

/// Small rounded "keycap" used in hints, e.g. ⌘K.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }
}
