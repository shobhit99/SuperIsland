import AppKit
import Carbon.HIToolbox

enum QuitHotkeyGuard {
    static let defaultsKey = "general.allowQuitHotkey"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func shouldBlock(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isEnabled else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command] && event.keyCode == UInt16(kVK_ANSI_Q)
    }
}
