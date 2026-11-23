import AppKit
import Carbon.HIToolbox
import Foundation

public struct HotkeyCombo: Equatable, Codable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var displayLabel: String

    public static let cmdShiftSpace = HotkeyCombo(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayLabel: "⌘⇧Space"
    )

    public static let optionS = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(optionKey),
        displayLabel: "⌥S"
    )

    public static let cmdShiftV = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayLabel: "⌘⇧V"
    )
}

/// Registers global summon shortcuts using Carbon's `RegisterEventHotKey`.
/// Supports two concurrent zero-permission hotkeys:
/// - ID 1: Snippet search popover (`⌘⇧Space` or `⌥S`)
/// - ID 2: Clipboard History bezel (`⌘⇧V`)
@MainActor
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()

    private var snippetHotKeyRef: EventHotKeyRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var onSnippetSummon: (() -> Void)?
    private var onClipboardSummon: (() -> Void)?

    nonisolated private static let signature: OSType = 0x534E_4950 // 'SNIP'
    nonisolated private static let snippetHotKeyID: UInt32 = 1
    nonisolated private static let clipboardHotKeyID: UInt32 = 2

    private init() {}

    public func register(combo: HotkeyCombo, handler: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        if let existing = snippetHotKeyRef {
            UnregisterEventHotKey(existing)
            snippetHotKeyRef = nil
        }

        self.onSnippetSummon = handler
        let hkID = EventHotKeyID(signature: Self.signature, id: Self.snippetHotKeyID)
        RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &snippetHotKeyRef
        )
    }

    public func registerClipboardHotKey(
        combo: HotkeyCombo = .cmdShiftV,
        handler: @escaping @MainActor () -> Void
    ) {
        installHandlerIfNeeded()
        if let existing = clipboardHotKeyRef {
            UnregisterEventHotKey(existing)
            clipboardHotKeyRef = nil
        }

        self.onClipboardSummon = handler
        let hkID = EventHotKeyID(signature: Self.signature, id: Self.clipboardHotKeyID)
        RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKeyRef
        )
    }

    public func unregister() {
        if let snippetHotKeyRef {
            UnregisterEventHotKey(snippetHotKeyRef)
            self.snippetHotKeyRef = nil
        }
        if let clipboardHotKeyRef {
            UnregisterEventHotKey(clipboardHotKeyRef)
            self.clipboardHotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
                var incomingID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &incomingID
                )
                guard err == noErr, incomingID.signature == GlobalHotkeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let matchedID = incomingID.id

                if matchedID == GlobalHotkeyManager.snippetHotKeyID {
                    Task { @MainActor in
                        manager.onSnippetSummon?()
                    }
                    return noErr
                } else if matchedID == GlobalHotkeyManager.clipboardHotKeyID {
                    Task { @MainActor in
                        manager.onClipboardSummon?()
                    }
                    return noErr
                }

                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
}
