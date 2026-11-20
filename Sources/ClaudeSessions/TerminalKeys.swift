import AppKit
import SwiftTerm

/// Copies the selection when the mouse is released, like iTerm2. Programs that track
/// the mouse (Claude Code fullscreen) make their own selection and copy it themselves.
final class CopyOnSelectTerminalView: TerminalView {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard selectionActive, let text = getSelection(), !text.isEmpty else { return }
        copyToPasteboard(text)
    }
}

enum TerminalKeyRouter {
    private static let returnKeyCode: UInt16 = 36

    /// True when the event was handled and must not reach the terminal.
    @MainActor
    static func handle(_ event: NSEvent) -> Bool {
        guard let terminal = event.window?.firstResponder as? TerminalView else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            // Cmd is the app's: run the menu shortcut if any, never type it into the program
            // (agy turns on the kitty keyboard protocol, which would send Cmd+C as "c").
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            return true
        }
        if mods == .shift, event.keyCode == returnKeyCode {
            // Shift+Enter inserts a newline in Claude Code's prompt (same bytes as `/terminal-setup`).
            terminal.send(data: ArraySlice(Array("\u{1b}\r".utf8)))
            return true
        }
        if mods == .control, event.charactersIgnoringModifiers?.lowercased() == "c", terminal.selectionActive {
            // Ctrl+C copies a selection, like Windows Terminal; otherwise it is an interrupt.
            terminal.copy(terminal)
            terminal.selectNone()
            return true
        }
        return false
    }
}
