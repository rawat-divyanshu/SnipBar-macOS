import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftData
import SwiftUI

/// Translucent floating clipboard stack HUD bezel (`NSPanel`) for cycling, searching, and
/// direct-pasting up to 50 clipboard history entries via `⌘⇧V` without touching explicit Snippets.
public final class ClipboardBezelPanel: NSPanel {
    public var onKeyDownEvent: (@MainActor (NSEvent) -> Bool)?
    public var onFlagsChangedEvent: (@MainActor (NSEvent) -> Void)?
    public var onResignKey: (@MainActor () -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    override public func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            onFlagsChangedEvent?(event)
            super.sendEvent(event)
            return
        case .keyDown:
            if onKeyDownEvent?(event) == true {
                return
            }
            super.sendEvent(event)
            return
        default:
            super.sendEvent(event)
        }
    }

    override public func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override public func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }
}

@MainActor
public final class ClipboardBezelState: ObservableObject {
    @Published public var selectedIndex: Int = 0
    @Published public var searchQuery: String = ""
    @Published public var isSearchActive: Bool = false
    @Published public var focusSearchTrigger: Int = 0
    @Published public var statusMessage: String?
    @Published public var isSavingAsSnippet: Bool = false
    @Published public var isArmedForReleasePaste: Bool = false
    @Published public var draftTitle: String = ""
    @Published public var draftTags: String = ""
}

@MainActor
public final class ClipboardBezelController: NSObject {
    private let panel: ClipboardBezelPanel
    private let state = ClipboardBezelState()
    private let modelContainer: ModelContainer
    private let onPastedFeedback: () -> Void

    private var previousFrontmostApp: NSRunningApplication?
    private var outsideClickMonitor: Any?
    private var localFlagsChangedMonitor: Any?
    private var globalFlagsChangedMonitor: Any?
    private var modifierReleaseWatchdog: Task<Void, Never>?
    private var armedForReleasePaste: Bool = false
    private var isPastingNow: Bool = false

    public init(modelContainer: ModelContainer, onPastedFeedback: @escaping () -> Void) {
        self.modelContainer = modelContainer
        self.onPastedFeedback = onPastedFeedback
        self.panel = ClipboardBezelPanel(contentRect: NSRect(x: 0, y: 0, width: 528, height: 408))
        super.init()

        configurePanelContent()
        configurePanelEvents()
    }

    private var filteredEntries: [IndexedClipboardEntry] {
        ClipboardHistoryStore.filterEntries(
            ClipboardHistoryStore.shared.entries,
            query: state.searchQuery
        )
    }

    /// Reads the live hardware / WindowServer Command modifier state via CoreGraphics.
    /// Unlike AppKit's `NSEvent.modifierFlags` (which goes stale when a `.nonactivatingPanel`
    /// in an `.accessory` app does not receive the foreground app's `flagsChanged` event),
    /// `CGEventSource.flagsState(.combinedSessionState)` updates immediately in real time
    /// with zero extra Input Monitoring permission.
    private nonisolated static func isCommandKeyCurrentlyPressed() -> Bool {
        let cgFlags = CGEventSource.flagsState(.combinedSessionState)
        if cgFlags.contains(.maskCommand) {
            return true
        }
        let leftCmd = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Command))
        let rightCmd = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightCommand))
        return leftCmd || rightCmd
    }

    /// Invoked whenever `⌘⇧V` fires (`fromHotkey: true`) or the bezel is opened via menu/button (`fromHotkey: false`):
    /// - If hidden & opened via `⌘⇧V`: captures active app, resets search, arms Release-⌘ auto-paste immediately, and opens at `#1`.
    /// - If already visible: advances to the next matching entry in the clipboard stack.
    /// - Releasing `⌘` immediately auto-pastes the highlighted entry (no Enter key needed) unless the user entered Search (`⌘F` / `/`) or Add-as-Snippet (`S`).
    public func handleHotkeyTrigger(fromHotkey: Bool = true) {
        let storeEntries = ClipboardHistoryStore.shared.entries
        if panel.isVisible {
            let currentFiltered = filteredEntries
            guard !currentFiltered.isEmpty else {
                if !state.searchQuery.isEmpty {
                    state.searchQuery = ""
                    state.selectedIndex = 0
                } else {
                    closeBezel()
                }
                return
            }
            if state.isSavingAsSnippet {
                cancelSaveAsSnippet()
            }
            if fromHotkey
                && ClipboardHistoryStore.shared.pasteOnReleaseCommand
                && !state.isSearchActive
                && state.searchQuery.isEmpty {
                armReleasePaste()
            }
            state.statusMessage = nil
            state.selectedIndex = (state.selectedIndex + 1) % currentFiltered.count
            return
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }

        isPastingNow = false
        state.selectedIndex = 0
        state.searchQuery = ""
        state.isSearchActive = false
        state.statusMessage = nil
        state.isSavingAsSnippet = false
        state.draftTitle = ""
        state.draftTags = ""
        showBezel()

        if fromHotkey && !storeEntries.isEmpty && ClipboardHistoryStore.shared.pasteOnReleaseCommand {
            armReleasePaste()
        } else {
            disarmReleasePaste()
        }
    }

    public func showBezel() {
        centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)

        if let existing = outsideClickMonitor {
            NSEvent.removeMonitor(existing)
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeBezel()
            }
        }
    }

    public func closeBezel() {
        disarmReleasePaste()
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        state.isSavingAsSnippet = false
        state.isSearchActive = false
        state.searchQuery = ""
        panel.orderOut(nil)
    }

    public func enterSearchMode() {
        disarmReleasePaste()
        if state.isSavingAsSnippet {
            cancelSaveAsSnippet()
        }
        state.isSearchActive = true
        state.focusSearchTrigger += 1
        panel.makeKeyAndOrderFront(nil)
    }

    public func clearSearch() {
        state.searchQuery = ""
        state.selectedIndex = 0
    }

    private func armReleasePaste() {
        armedForReleasePaste = true
        state.isArmedForReleasePaste = true

        if localFlagsChangedMonitor == nil {
            localFlagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let commandStillDown = event.modifierFlags.contains(.command)
                    && ClipboardBezelController.isCommandKeyCurrentlyPressed()
                Task { @MainActor in
                    self?.handleCommandModifierUpdate(commandStillDown: commandStillDown)
                }
                return event
            }
        }

        if globalFlagsChangedMonitor == nil {
            globalFlagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let commandStillDown = event.modifierFlags.contains(.command)
                    && ClipboardBezelController.isCommandKeyCurrentlyPressed()
                Task { @MainActor in
                    self?.handleCommandModifierUpdate(commandStillDown: commandStillDown)
                }
            }
        }

        // High-responsiveness 20ms live HID watchdog while the bezel is armed:
        // Uses `CGEventSource.flagsState(.combinedSessionState)` so releasing `⌘` is ALWAYS
        // detected immediately even in a `.nonactivatingPanel` `.accessory` app without Input Monitoring.
        modifierReleaseWatchdog?.cancel()
        modifierReleaseWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { break }
                guard self.panel.isVisible,
                      self.armedForReleasePaste,
                      !self.state.isSavingAsSnippet,
                      !self.state.isSearchActive,
                      self.state.searchQuery.isEmpty else {
                    break
                }
                if !Self.isCommandKeyCurrentlyPressed() {
                    self.pasteSelectedEntry()
                    break
                }
            }
        }
    }

    private func disarmReleasePaste() {
        armedForReleasePaste = false
        state.isArmedForReleasePaste = false
        modifierReleaseWatchdog?.cancel()
        modifierReleaseWatchdog = nil
        if let monitor = localFlagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsChangedMonitor = nil
        }
        if let monitor = globalFlagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsChangedMonitor = nil
        }
    }

    private func handleCommandModifierUpdate(commandStillDown: Bool) {
        if !commandStillDown
            && ClipboardHistoryStore.shared.pasteOnReleaseCommand
            && armedForReleasePaste
            && !state.isSavingAsSnippet
            && !state.isSearchActive
            && state.searchQuery.isEmpty
            && panel.isVisible {
            pasteSelectedEntry()
        }
    }

    public func pasteSelectedEntry() {
        let items = filteredEntries
        guard !items.isEmpty else {
            closeBezel()
            return
        }
        let safeIdx = max(0, min(state.selectedIndex, items.count - 1))
        pasteEntry(items[safeIdx].entry)
    }

    public func pasteEntry(_ entry: ClipboardHistoryEntry) {
        guard !isPastingNow else { return }
        isPastingNow = true

        let targetApp = previousFrontmostApp
        ClipboardService.shared.copy(
            entry.content,
            isSecret: false,
            isTransient: true,
            autoClearAfterSeconds: nil,
            skipHistoryCapture: true
        )
        ClipboardHistoryStore.shared.promoteToTop(id: entry.id)
        onPastedFeedback()
        closeBezel()

        Task { @MainActor [weak self] in
            _ = await AutoPasteService.shared.pasteInto(previousApp: targetApp)
            self?.isPastingNow = false
        }
    }

    public func beginSaveAsSnippet(_ entry: ClipboardHistoryEntry) {
        disarmReleasePaste()
        state.isSearchActive = false
        let suggested = String(entry.previewLine.prefix(48))
        state.draftTitle = suggested.isEmpty ? "Clipboard Snippet" : suggested
        state.draftTags = ""
        state.statusMessage = nil
        state.isSavingAsSnippet = true
    }

    public func cancelSaveAsSnippet() {
        state.isSavingAsSnippet = false
        state.draftTitle = ""
        state.draftTags = ""
    }

    public func commitSaveAsSnippet(
        _ entry: ClipboardHistoryEntry,
        title: String,
        tagsRaw: String
    ) {
        let context = modelContainer.mainContext
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(entry.previewLine.prefix(48))
        let finalTitle = cleanTitle.isEmpty
            ? (fallback.isEmpty ? "Clipboard Snippet" : fallback)
            : cleanTitle

        let parsedTagNames = tagsRaw
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased() }
            .filter { !$0.isEmpty }

        var resolvedTags: [TagRecord] = []
        if !parsedTagNames.isEmpty {
            let existing = (try? context.fetch(FetchDescriptor<TagRecord>())) ?? []
            var byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name.lowercased(), $0) })

            var seen = Set<String>()
            let uniqueTagNames = parsedTagNames.filter { seen.insert($0).inserted }

            for tagName in uniqueTagNames {
                if let match = byName[tagName] {
                    resolvedTags.append(match)
                } else {
                    let created = TagRecord(name: tagName, color: .blue)
                    context.insert(created)
                    byName[tagName] = created
                    resolvedTags.append(created)
                }
            }
        }

        let record = SnippetRecord(
            title: finalTitle,
            content: entry.content,
            tags: resolvedTags
        )
        context.insert(record)
        try? context.save()

        state.isSavingAsSnippet = false
        state.draftTitle = ""
        state.draftTags = ""
        state.statusMessage = "Saved to Snippets"
    }

    private func configurePanelContent() {
        let rootView = ClipboardBezelView(
            store: ClipboardHistoryStore.shared,
            state: state,
            onEnterSearchMode: { [weak self] in
                self?.enterSearchMode()
            },
            onClearSearch: { [weak self] in
                self?.clearSearch()
            },
            onPaste: { [weak self] entry in
                self?.pasteEntry(entry)
            },
            onBeginSaveAsSnippet: { [weak self] entry in
                self?.beginSaveAsSnippet(entry)
            },
            onCommitSaveAsSnippet: { [weak self] entry, title, tagsRaw in
                self?.commitSaveAsSnippet(entry, title: title, tagsRaw: tagsRaw)
            },
            onCancelSaveAsSnippet: { [weak self] in
                self?.cancelSaveAsSnippet()
            },
            onClose: { [weak self] in
                self?.closeBezel()
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        panel.contentView = effect
    }

    private func configurePanelEvents() {
        panel.onResignKey = { [weak self] in
            self?.closeBezel()
        }

        panel.onFlagsChangedEvent = { [weak self] event in
            guard let self else { return }
            let commandStillDown = event.modifierFlags.contains(.command)
                && Self.isCommandKeyCurrentlyPressed()
            self.handleCommandModifierUpdate(commandStillDown: commandStillDown)
        }

        panel.onKeyDownEvent = { [weak self] event in
            guard let self else { return false }

            // While editing the inline "Add as Snippet" composer, allow normal typing
            // and only intercept Escape to dismiss the composer.
            if self.state.isSavingAsSnippet {
                if event.keyCode == 53 { // Escape
                    self.cancelSaveAsSnippet()
                    return true
                }
                return false
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyChar = event.charactersIgnoringModifiers?.lowercased()
            let items = self.filteredEntries

            // ⌘F always switches cleanly into Search Mode (even while holding ⌘ from ⌘⇧V!)
            if flags.contains(.command), !flags.contains(.control), !flags.contains(.option), keyChar == "f" {
                self.enterSearchMode()
                return true
            }

            // ⌘S opens inline "Add as Snippet" for the active matching entry
            if flags == .command, keyChar == "s" {
                if !items.isEmpty {
                    let safeIdx = max(0, min(self.state.selectedIndex, items.count - 1))
                    self.beginSaveAsSnippet(items[safeIdx].entry)
                    return true
                }
                return false
            }

            // Search Mode keyboard handling: keep typing natural while navigating filtered matches
            if self.state.isSearchActive {
                switch event.keyCode {
                case 53: // Escape -> clear search first, then close bezel
                    if !self.state.searchQuery.isEmpty {
                        self.clearSearch()
                    } else {
                        self.closeBezel()
                    }
                    return true
                case 36, 76: // Return / Numpad Enter -> paste highlighted matching item
                    if !items.isEmpty {
                        self.pasteSelectedEntry()
                    }
                    return true
                case 126: // Up Arrow -> previous matching item
                    guard !items.isEmpty else { return true }
                    self.state.statusMessage = nil
                    self.state.selectedIndex = (self.state.selectedIndex - 1 + items.count) % items.count
                    return true
                case 125: // Down Arrow -> next matching item
                    guard !items.isEmpty else { return true }
                    self.state.statusMessage = nil
                    self.state.selectedIndex = (self.state.selectedIndex + 1) % items.count
                    return true
                case 48: // Tab / Shift+Tab -> cycle through matching items
                    guard !items.isEmpty else { return true }
                    self.state.statusMessage = nil
                    if flags.contains(.shift) {
                        self.state.selectedIndex = (self.state.selectedIndex - 1 + items.count) % items.count
                    } else {
                        self.state.selectedIndex = (self.state.selectedIndex + 1) % items.count
                    }
                    return true
                case 123 where flags.contains(.command): // ⌘Left -> previous match
                    guard !items.isEmpty else { return true }
                    self.state.statusMessage = nil
                    self.state.selectedIndex = (self.state.selectedIndex - 1 + items.count) % items.count
                    return true
                case 124 where flags.contains(.command): // ⌘Right -> next match
                    guard !items.isEmpty else { return true }
                    self.state.statusMessage = nil
                    self.state.selectedIndex = (self.state.selectedIndex + 1) % items.count
                    return true
                default:
                    // Let normal typing, Backspace, Left/Right text cursor, ⌘A/⌘C/⌘V flow to TextField
                    return false
                }
            }

            // Quick-Cycle Mode (holding ⌘⇧V or browsing stack without search box focused)
            switch event.keyCode {
            case 53: // Escape
                if !self.state.searchQuery.isEmpty {
                    self.clearSearch()
                } else {
                    self.closeBezel()
                }
                return true
            case 36, 76: // Return / Numpad Enter
                self.pasteSelectedEntry()
                return true
            case 123, 126: // Left Arrow / Up Arrow -> previous (newer)
                guard !items.isEmpty else { return true }
                self.state.statusMessage = nil
                self.state.selectedIndex = (self.state.selectedIndex - 1 + items.count) % items.count
                return true
            case 124, 125: // Right Arrow / Down Arrow -> next (older)
                guard !items.isEmpty else { return true }
                self.state.statusMessage = nil
                self.state.selectedIndex = (self.state.selectedIndex + 1) % items.count
                return true
            case 9: // 'V' (e.g. holding ⌘ and tapping V after releasing ⇧) -> cycle forward
                guard !items.isEmpty else { return true }
                self.state.statusMessage = nil
                self.state.selectedIndex = (self.state.selectedIndex + 1) % items.count
                return true
            case 44 where flags.isDisjoint(with: [.command, .control, .option]): // '/' -> enter Search
                self.enterSearchMode()
                return true
            case 51, 117: // Delete / Forward Delete
                if items.indices.contains(self.state.selectedIndex) {
                    let target = items[self.state.selectedIndex].entry
                    ClipboardHistoryStore.shared.remove(id: target.id)
                    let remaining = self.filteredEntries.count
                    self.state.selectedIndex = max(0, min(self.state.selectedIndex, remaining - 1))
                }
                return true
            case 1: // 'S' -> Add active clipping directly as a permanent Snippet
                if items.indices.contains(self.state.selectedIndex) {
                    self.beginSaveAsSnippet(items[self.state.selectedIndex].entry)
                    return true
                }
                return false
            default:
                // Instant 1..9 jump & paste among current visible items
                if flags.isDisjoint(with: [.command, .control, .option]),
                   let chars = event.charactersIgnoringModifiers,
                   let digit = Int(chars),
                   (1...9).contains(digit),
                   items.indices.contains(digit - 1) {
                    self.pasteEntry(items[digit - 1].entry)
                    return true
                }
                return false
            }
        }
    }

    private func centerOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(
            x: round(frame.midX - size.width / 2),
            y: round(frame.midY - size.height / 2 + 40)
        )
        panel.setFrameOrigin(origin)
    }
}

private struct ClipboardBezelView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var state: ClipboardBezelState
    let onEnterSearchMode: () -> Void
    let onClearSearch: () -> Void
    let onPaste: (ClipboardHistoryEntry) -> Void
    let onBeginSaveAsSnippet: (ClipboardHistoryEntry) -> Void
    let onCommitSaveAsSnippet: (ClipboardHistoryEntry, String, String) -> Void
    let onCancelSaveAsSnippet: () -> Void
    let onClose: () -> Void

    @FocusState private var titleFocused: Bool
    @FocusState private var searchFocused: Bool

    private var isFiltering: Bool {
        !state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredEntries: [IndexedClipboardEntry] {
        ClipboardHistoryStore.filterEntries(store.entries, query: state.searchQuery)
    }

    private var safeIndex: Int {
        guard !filteredEntries.isEmpty else { return 0 }
        return max(0, min(state.selectedIndex, filteredEntries.count - 1))
    }

    private var activeIndexedEntry: IndexedClipboardEntry? {
        guard filteredEntries.indices.contains(safeIndex) else { return nil }
        return filteredEntries[safeIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Label("Clipboard History", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))

                if state.isArmedForReleasePaste && !state.isSavingAsSnippet && !state.isSearchActive && !isFiltering {
                    Text("Release ⌘ to Paste")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                } else if state.isSearchActive || isFiltering {
                    Text("Search Mode · ↵ Paste")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }

                Spacer()

                if !store.entries.isEmpty {
                    if isFiltering {
                        Text("\(filteredEntries.isEmpty ? 0 : safeIndex + 1) / \(filteredEntries.count) matches")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        Text("\(safeIndex + 1) / \(store.entries.count)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            // Search Bar for filtering up to 50 cached clipboard entries.
            // IMPORTANT: Mount the real `TextField` only when `state.isSearchActive` is true so AppKit
            // never auto-focuses an `NSTextField` on `makeKeyAndOrderFront` and disarms Release-⌘ paste.
            if !store.entries.isEmpty {
                if state.isSearchActive || isFiltering {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)

                        TextField("Search cached clipboards (text, app, #50)…", text: $state.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .focused($searchFocused)
                            .onChange(of: state.searchQuery) { _, _ in
                                state.selectedIndex = 0
                                state.statusMessage = nil
                            }
                            .onSubmit {
                                if let active = activeIndexedEntry {
                                    onPaste(active.entry)
                                }
                            }

                        if isFiltering {
                            Text("\(filteredEntries.count) of \(store.entries.count)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Button(action: onClearSearch) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear search (Esc)")
                        } else {
                            Text("↑↓ · ↵ Paste")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .task(id: state.focusSearchTrigger) {
                        try? await Task.sleep(for: .milliseconds(25))
                        searchFocused = true
                    }
                } else {
                    Button(action: onEnterSearchMode) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text("Search up to \(store.entries.count) cached clipboards…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("⌘F or /")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }

            Divider()

            if let active = activeIndexedEntry {
                let entry = active.entry

                // Active entry metadata + actions
                HStack(spacing: 8) {
                    Text("#\(active.originalRank)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))

                    if let source = entry.sourceApp, !source.isEmpty {
                        Text(source)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.copiedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(entry.characterCount) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let status = state.statusMessage {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else if !state.isSavingAsSnippet {
                        Button {
                            onBeginSaveAsSnippet(entry)
                        } label: {
                            Label(
                                state.isSearchActive ? "Add as Snippet (⌘S)" : "Add as Snippet (S)",
                                systemImage: "plus.square.on.square"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    Button("Paste") {
                        onPaste(entry)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // Inline Quick-Save-as-Snippet Bar (opened via 'S' / '⌘S' or button click)
                if state.isSavingAsSnippet {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Snippet title…", text: $state.draftTitle)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .focused($titleFocused)
                                .onSubmit {
                                    onCommitSaveAsSnippet(entry, state.draftTitle, state.draftTags)
                                }

                            TextField("Tags (e.g. sql, git)", text: $state.draftTags)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .frame(width: 148)
                                .onSubmit {
                                    onCommitSaveAsSnippet(entry, state.draftTitle, state.draftTags)
                                }
                        }

                        HStack {
                            Text("Press ↵ to save directly into Snippets or Esc to cancel")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") {
                                onCancelSaveAsSnippet()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("Save Snippet") {
                                onCommitSaveAsSnippet(entry, state.draftTitle, state.draftTags)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .task {
                        try? await Task.sleep(for: .milliseconds(30))
                        titleFocused = true
                    }
                }

                // Main clipping preview
                ScrollView {
                    Text(entry.content)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                // Filtered (or full) scrollable filmstrip with auto-centering
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, item in
                                let selected = idx == safeIndex
                                Button {
                                    state.selectedIndex = idx
                                    onPaste(item.entry)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("#\(item.originalRank)")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .opacity(0.8)
                                        Text(item.entry.previewLine)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                            .frame(maxWidth: 118, alignment: .leading)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        selected ? Color.accentColor : Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: safeIndex) { _, newIdx in
                        if filteredEntries.indices.contains(newIdx) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo(filteredEntries[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            } else if isFiltering {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("No cached clipboard items match “\(state.searchQuery)”")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Searched across all \(store.entries.count) cached clipboard entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear Search (Esc)") {
                        onClearSearch()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Clipboard History Empty",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy text in any app and press ⌘⇧V to cycle, search, and paste up to 50 recent clippings.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Shortcut hints footer
            HStack {
                Text(
                    state.isSearchActive || isFiltering
                        ? "↑↓ Cycle Matches · ↵ Paste · ⌘S Add Snippet · Esc Clear"
                        : "⌘⇧V / ←→ Cycle · Release ⌘ Paste · ⌘F Search · S Snippet"
                )
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("Max \(store.maxEntries)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 528, height: 408)
        .onChange(of: state.focusSearchTrigger) { _, _ in
            searchFocused = true
        }
        .onChange(of: state.isSearchActive) { _, active in
            if !active && searchFocused {
                searchFocused = false
            }
        }
    }
}
