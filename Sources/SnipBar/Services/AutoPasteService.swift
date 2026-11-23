import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Handles direct Auto-Paste into whichever macOS application was active prior to summoning SnipBar.
/// CAVEATS SOLVED:
/// 1. Never prompts for Accessibility (`AXIsProcessTrusted`) on launch—only checks or prompts
///    when the user explicitly triggers or enables Auto-Paste.
/// 2. Polls `targetApp.isActive` (up to 200ms) after dismissing the panel instead of firing `Cmd+V`
///    into a dead window transition.
/// 3. Uses `.privateState` `CGEventSource` so residual physical modifier keys (like held `Option`
///    or `Shift` from `Option+Enter` / `Cmd+Shift+Space`) do NOT mutate `Cmd+V` into `Cmd+Opt+V`.
@MainActor
public final class AutoPasteService {
    public static let shared = AutoPasteService()

    private init() {}

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibilityPermissionIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func pasteInto(previousApp: NSRunningApplication?) async -> Bool {
        guard let targetApp = previousApp, !targetApp.isTerminated else {
            return false
        }

        guard isAccessibilityTrusted else {
            _ = requestAccessibilityPermissionIfNeeded()
            return false
        }

        // Reactivate the target application
        targetApp.activate()

        // Wait up to 200ms (10 x 20ms) for macOS WindowServer to transfer key focus
        for _ in 0..<10 {
            if targetApp.isActive { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Brief settle frame so target responder chain is ready for keystrokes
        try? await Task.sleep(for: .milliseconds(25))

        // When triggered by releasing ⌘ from ⌘⇧V, the user may still hold Shift for a few
        // milliseconds. Wait briefly (up to 90ms) so lingering physical modifiers cannot turn
        // synthesized ⌘V into ⌘⇧V in apps that inspect live hardware modifier flags.
        let conflictingModifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskControl]
        for _ in 0..<6 {
            let liveFlags = CGEventSource.flagsState(.combinedSessionState)
            if liveFlags.intersection(conflictingModifiers).isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(15))
        }

        // Isolated event source strips any remaining physical modifier keys
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(8))
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
