import AppKit
import SwiftData
import SwiftUI

public struct PopoverContentView: View {
    private enum PopoverMode: String, CaseIterable {
        case snippets = "Snippets"
        case clipboard = "Clipboard"
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SnippetRecord.updatedAt, order: .reverse) private var allSnippets: [SnippetRecord]
    @Query(sort: \TagRecord.name) private var allTags: [TagRecord]
    @ObservedObject private var clipboardStore = ClipboardHistoryStore.shared

    @AppStorage("snipbar.autoPasteByDefault") private var autoPasteByDefault: Bool = false

    private let interactionBridge: PopoverInteractionBridge?
    let onCopyCompleted: (_ title: String, _ shouldAutoPaste: Bool) -> Void
    let onDirectPasteClipboard: (_ entry: ClipboardHistoryEntry) -> Void
    let onOpenClipboardBezel: () -> Void
    let onOpenLibrary: () -> Void
    let onClosePopover: () -> Void

    @State private var mode: PopoverMode = .snippets
    @State private var query: String = ""
    @State private var selectedTag: String?
    @State private var pinnedOnly: Bool = false
    @State private var selectedIndex: Int = 0
    @State private var previewSnippetID: UUID?
    @State private var errorMessage: String?

    // Inline "New Snippet" composer inside the menu bar popup (⌘N)
    @State private var isCreatingSnippet: Bool = false
    @State private var draftTitle: String = ""
    @State private var draftContent: String = ""
    @State private var draftSelectedTagNames: Set<String> = []
    @State private var draftNewTagName: String = ""
    @State private var draftPinned: Bool = false
    @State private var draftSecret: Bool = false
    @State private var draftRequireBiometrics: Bool = false

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isDraftTitleFocused: Bool

    private var filteredSnippets: [SnippetRecord] {
        FuzzySearchEngine.filter(
            snippets: allSnippets,
            rawQuery: query,
            selectedTag: selectedTag,
            pinnedOnly: pinnedOnly
        )
    }

    private var filteredClipboardEntries: [ClipboardHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clipboardStore.entries }
        let lowered = trimmed.lowercased()
        return clipboardStore.entries.filter {
            $0.content.lowercased().contains(lowered)
                || ($0.sourceApp?.lowercased().contains(lowered) ?? false)
        }
    }

    private var currentResultCount: Int {
        mode == .snippets ? filteredSnippets.count : filteredClipboardEntries.count
    }

    public init(
        interactionBridge: PopoverInteractionBridge? = nil,
        onCopyCompleted: @escaping (_ title: String, _ shouldAutoPaste: Bool) -> Void,
        onDirectPasteClipboard: @escaping (_ entry: ClipboardHistoryEntry) -> Void = { _ in },
        onOpenClipboardBezel: @escaping () -> Void = {},
        onOpenLibrary: @escaping () -> Void,
        onClosePopover: @escaping () -> Void
    ) {
        self.interactionBridge = interactionBridge
        self.onCopyCompleted = onCopyCompleted
        self.onDirectPasteClipboard = onDirectPasteClipboard
        self.onOpenClipboardBezel = onOpenClipboardBezel
        self.onOpenLibrary = onOpenLibrary
        self.onClosePopover = onClosePopover
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isCreatingSnippet {
                inlineNewSnippetForm
            } else {
                searchHeader
                Divider()
                if mode == .snippets {
                    snippetList
                    if let preview = filteredSnippets.first(where: { $0.id == previewSnippetID }), !preview.isSecret {
                        Divider()
                        previewDrawer(for: preview)
                    }
                } else {
                    clipboardHistoryList
                }
                if let errorMessage {
                    Divider()
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                Divider()
                footerBar
            }
        }
        .frame(width: 444, height: 486)
        .onAppear {
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .snipBarDidSummonPopover)) { _ in
            errorMessage = nil
            isCreatingSnippet = false
            interactionBridge?.isEditingInlineForm = false
            mode = .snippets
            selectedIndex = 0
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .snipBarPopoverToggleTab)) { _ in
            guard !isCreatingSnippet else { return }
            toggleModeWithTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snipBarPopoverOpenNewSnippet)) { _ in
            if !isCreatingSnippet {
                openNewSnippetForm()
            }
        }
        .onChange(of: isCreatingSnippet) { _, editing in
            interactionBridge?.isEditingInlineForm = editing
        }
        .onChange(of: mode) { _, _ in
            selectedIndex = 0
            previewSnippetID = nil
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: selectedTag) { _, _ in selectedIndex = 0 }
        .onChange(of: pinnedOnly) { _, _ in selectedIndex = 0 }
        .onChange(of: allTags.map(\.name)) { _, currentNames in
            if let activeTag = selectedTag, !currentNames.contains(activeTag) {
                selectedTag = nil
            }
        }
        .onKeyPress(.tab) {
            guard !isCreatingSnippet else { return .ignored }
            toggleModeWithTab()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !isCreatingSnippet else { return .ignored }
            guard currentResultCount > 0 else { return .handled }
            selectedIndex = min(selectedIndex + 1, currentResultCount - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !isCreatingSnippet else { return .ignored }
            guard currentResultCount > 0 else { return .handled }
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(keys: [.return]) { press in
            if isCreatingSnippet {
                if press.modifiers.contains(.command) {
                    commitNewSnippet()
                    return .handled
                }
                return .ignored
            }
            handlePrimaryAction(optionPressed: press.modifiers.contains(.option))
            return .handled
        }
        .onKeyPress(.escape) {
            if isCreatingSnippet {
                cancelNewSnippetForm()
            } else if previewSnippetID != nil {
                previewSnippetID = nil
            } else if !query.isEmpty {
                query = ""
            } else {
                onClosePopover()
            }
            return .handled
        }
        .background(popoverKeyboardShortcuts)
    }

    private func toggleModeWithTab() {
        mode = (mode == .snippets) ? .clipboard : .snippets
        selectedIndex = 0
        previewSnippetID = nil
        isSearchFocused = true
    }

    private func openNewSnippetForm() {
        draftTitle = ""
        draftContent = ""
        draftSelectedTagNames = selectedTag.map { [$0] } ?? []
        draftNewTagName = ""
        draftPinned = pinnedOnly
        draftSecret = false
        draftRequireBiometrics = false
        errorMessage = nil
        isCreatingSnippet = true
    }

    private func cancelNewSnippetForm() {
        isCreatingSnippet = false
        isSearchFocused = true
    }

    private func commitNewSnippet() {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedContent.isEmpty else {
            cancelNewSnippetForm()
            return
        }

        let fallbackTitle = String(
            trimmedContent
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(48) ?? "Untitled Snippet"
        )
        let finalTitle = trimmedTitle.isEmpty
            ? (fallbackTitle.isEmpty ? "Untitled Snippet" : fallbackTitle)
            : trimmedTitle

        var resolvedTags = allTags.filter { draftSelectedTagNames.contains($0.name) }
        let normalizedNewTag = TagRecord.normalize(draftNewTagName)
        if !normalizedNewTag.isEmpty {
            if let existing = allTags.first(where: { $0.name == normalizedNewTag }) {
                if !resolvedTags.contains(where: { $0.name == existing.name }) {
                    resolvedTags.append(existing)
                }
            } else {
                let createdTag = TagRecord(name: normalizedNewTag, color: .blue)
                modelContext.insert(createdTag)
                resolvedTags.append(createdTag)
            }
        }

        let record = SnippetRecord(
            title: finalTitle,
            content: draftContent,
            tags: resolvedTags,
            isPinned: draftPinned,
            isSecret: draftSecret,
            requireBiometrics: draftSecret ? draftRequireBiometrics : false
        )
        modelContext.insert(record)
        try? modelContext.save()

        isCreatingSnippet = false
        mode = .snippets
        query = ""
        selectedIndex = 0
        isSearchFocused = true
    }

    private func handlePrimaryAction(optionPressed: Bool) {
        if mode == .snippets {
            guard filteredSnippets.indices.contains(selectedIndex) else { return }
            let shouldPaste = optionPressed ? !autoPasteByDefault : autoPasteByDefault
            triggerCopy(filteredSnippets[selectedIndex], shouldAutoPaste: shouldPaste)
        } else {
            guard filteredClipboardEntries.indices.contains(selectedIndex) else { return }
            onDirectPasteClipboard(filteredClipboardEntries[selectedIndex])
        }
    }

    private var inlineNewSnippetForm: some View {
        VStack(spacing: 0) {
            HStack {
                Label("New Snippet", systemImage: "plus.square.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") {
                    cancelNewSnippetForm()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g., PostgreSQL Active Queries", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .focused($isDraftTitleFocused)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(draftSecret ? "Masked Secret Value" : "Content")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Paste Clipboard") {
                                if let clip = ClipboardService.shared.readPlainText() {
                                    draftContent = clip
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }

                        if draftSecret {
                            SecureField("Enter secret password or API token…", text: $draftContent)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        } else {
                            TextEditor(text: $draftContent)
                                .font(.system(size: 12.5, design: .monospaced))
                                .frame(minHeight: 130, maxHeight: 165)
                                .padding(4)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(allTags, id: \.name) { tag in
                                    let selected = draftSelectedTagNames.contains(tag.name)
                                    Button("#\(tag.name)") {
                                        if selected {
                                            draftSelectedTagNames.remove(tag.name)
                                        } else {
                                            draftSelectedTagNames.insert(tag.name)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        selected ? Color.accentColor : Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                }
                            }
                        }
                        TextField("Add new tag (optional)…", text: $draftNewTagName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Pin to top of Snippets", isOn: $draftPinned)
                            .font(.caption)
                        Toggle("Masked Secret (concealed clipboard, 30s auto-clear)", isOn: $draftSecret)
                            .font(.caption)
                            .onChange(of: draftSecret) { _, isSec in
                                if !isSec { draftRequireBiometrics = false }
                            }
                        if draftSecret {
                            Toggle("Require Touch ID before copying", isOn: $draftRequireBiometrics)
                                .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }

            Divider()

            HStack {
                Text("⌘↵ Save · Esc Cancel")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    cancelNewSnippetForm()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Create Snippet") {
                    commitNewSnippet()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(25))
            isDraftTitleFocused = true
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Dual-mode switcher: Snippets (explicit search) vs Clipboard History (up to 50 direct paste)
            HStack(spacing: 6) {
                modeTabButton(title: "Snippets", count: allSnippets.count, target: .snippets)
                modeTabButton(
                    title: "Clipboard",
                    count: clipboardStore.entries.count,
                    suffix: "/\(clipboardStore.maxEntries)",
                    target: .clipboard
                )
                Text("Tab")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Button {
                    onOpenClipboardBezel()
                } label: {
                    Text("⌘⇧V Stack")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Open Clipboard Paste Screen (⌘⇧V)")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    mode == .snippets ? "Search snippets or type #tag…" : "Filter recent clipboard entries…",
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($isSearchFocused)
                .onSubmit {
                    handlePrimaryAction(optionPressed: NSEvent.modifierFlags.contains(.option))
                }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if mode == .snippets {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(title: "All", isSelected: selectedTag == nil && !pinnedOnly) {
                            selectedTag = nil
                            pinnedOnly = false
                        }
                        filterChip(title: "Pinned", icon: "pin.fill", isSelected: pinnedOnly) {
                            pinnedOnly.toggle()
                            if pinnedOnly { selectedTag = nil }
                        }
                        ForEach(allTags, id: \.name) { tag in
                            filterChip(
                                title: "#\(tag.name)",
                                isSelected: selectedTag == tag.name
                            ) {
                                selectedTag = (selectedTag == tag.name) ? nil : tag.name
                                pinnedOnly = false
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func modeTabButton(
        title: String,
        count: Int,
        suffix: String = "",
        target: PopoverMode
    ) -> some View {
        let active = mode == target
        return Button {
            mode = target
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(count)\(suffix)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .opacity(0.8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                active ? Color.accentColor : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var snippetList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredSnippets.isEmpty {
                    ContentUnavailableView(
                        "No Matching Snippets",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Try another keyword or press ⌘N to add a new snippet.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                            snippetRow(snippet: snippet, index: index)
                                .id(snippet.id)
                        }
                    }
                    .padding(8)
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if filteredSnippets.indices.contains(newIndex) {
                    proxy.scrollTo(filteredSnippets[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private var clipboardHistoryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredClipboardEntries.isEmpty {
                    ContentUnavailableView(
                        "No Clipboard History",
                        systemImage: "doc.on.clipboard",
                        description: Text("Copy text anywhere on your Mac to store up to \(clipboardStore.maxEntries) direct-paste clippings.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filteredClipboardEntries.enumerated()), id: \.element.id) { index, entry in
                            clipboardRow(entry: entry, index: index)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if filteredClipboardEntries.indices.contains(newIndex) {
                    proxy.scrollTo(filteredClipboardEntries[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private func clipboardRow(entry: ClipboardHistoryEntry, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.previewLine)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("#\(index + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    if let app = entry.sourceApp, !app.isEmpty {
                        Text("·")
                        Text(app)
                    }
                    Text("·")
                    Text(entry.copiedAt, style: .relative)
                    Text("·")
                    Text("\(entry.characterCount) chars")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button {
                    saveClipboardEntryAsSnippet(entry)
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Save as Snippet")

                Button {
                    clipboardStore.remove(id: entry.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from History")

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
        .onTapGesture {
            onDirectPasteClipboard(entry)
        }
    }

    private func snippetRow(snippet: SnippetRecord, index: Int) -> some View {
        let isSelected = index == selectedIndex

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if snippet.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    if snippet.isSecret {
                        Image(systemName: snippet.requireBiometrics ? "touchid" : "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(snippet.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if !snippet.tags.isEmpty {
                        Text(snippet.tags.prefix(3).map { "#\($0.name)" }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(snippet.safePreviewLine)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if !snippet.isSecret {
                    Button {
                        previewSnippetID = (previewSnippetID == snippet.id) ? nil : snippet.id
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Preview")
                }

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
        .onTapGesture {
            triggerCopy(snippet, shouldAutoPaste: autoPasteByDefault)
        }
    }

    private func previewDrawer(for snippet: SnippetRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snippet.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Close") { previewSnippetID = nil }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(snippet.content)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 90)
        }
        .padding(10)
        .background(.black.opacity(0.03))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button {
                openNewSnippetForm()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("New")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("⌘N")
                        .font(.system(size: 9.5, design: .monospaced))
                        .opacity(0.75)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Add New Snippet (⌘N)")

            if mode == .snippets {
                Button {
                    saveClipboardAsSnippet()
                } label: {
                    Label("From Clip", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save current clipboard text as a snippet")
            } else {
                Button {
                    clipboardStore.clearAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(clipboardStore.entries.isEmpty)
            }

            Spacer()

            Text(mode == .snippets ? "↑↓ · ↵ Copy" : "↑↓ · ↵ Paste")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                onOpenLibrary()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 11))
                    Text("Library")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("⌘L")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Open SnipBar Library (⌘L or ⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Invisible `Cmd+1`...`Cmd+9`, `Cmd+N`, `Cmd+L`, `Cmd+,` bindings.
    private var popoverKeyboardShortcuts: some View {
        HStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { idx in
                Button("") {
                    guard !isCreatingSnippet else { return }
                    if mode == .snippets {
                        guard filteredSnippets.indices.contains(idx) else { return }
                        triggerCopy(filteredSnippets[idx], shouldAutoPaste: autoPasteByDefault)
                    } else {
                        guard filteredClipboardEntries.indices.contains(idx) else { return }
                        onDirectPasteClipboard(filteredClipboardEntries[idx])
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }

            Button("") {
                if !isCreatingSnippet {
                    openNewSnippetForm()
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)

            Button("") {
                onOpenLibrary()
            }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)

            Button("") {
                onOpenLibrary()
            }
            .keyboardShortcut(",", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private func filterChip(
        title: String,
        icon: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func triggerCopy(_ snippet: SnippetRecord, shouldAutoPaste: Bool) {
        errorMessage = nil
        Task { @MainActor in
            do {
                if snippet.isSecret && snippet.requireBiometrics {
                    try await BiometricAuthService.shared.authenticate(
                        reason: "copy secret snippet \"\(snippet.title)\""
                    )
                }

                let rawBody = snippet.isSecret
                    ? snippet.content
                    : expandDynamicVariables(in: snippet.content)

                ClipboardService.shared.copy(
                    rawBody,
                    isSecret: snippet.isSecret,
                    isTransient: snippet.isSecret,
                    autoClearAfterSeconds: snippet.isSecret ? snippet.autoClearSeconds : nil,
                    skipHistoryCapture: snippet.isSecret,
                    historySourceApp: "SnipBar Snippet"
                )

                snippet.usageCount += 1
                snippet.lastUsedAt = .now
                try? modelContext.save()

                onCopyCompleted(snippet.title, shouldAutoPaste)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func expandDynamicVariables(in template: String) -> String {
        var result = template
        if result.contains("{{date}}") {
            let formattedDate = Date.now.formatted(date: .abbreviated, time: .omitted)
            result = result.replacingOccurrences(of: "{{date}}", with: formattedDate)
        }
        if result.contains("{{time}}") {
            let formattedTime = Date.now.formatted(date: .omitted, time: .shortened)
            result = result.replacingOccurrences(of: "{{time}}", with: formattedTime)
        }
        if result.contains("{{clipboard}}") {
            let currentClip = ClipboardService.shared.readPlainText() ?? ""
            result = result.replacingOccurrences(of: "{{clipboard}}", with: currentClip)
        }
        return result
    }

    private func saveClipboardEntryAsSnippet(_ entry: ClipboardHistoryEntry) {
        let title = String(entry.previewLine.prefix(48))
        let record = SnippetRecord(
            title: title.isEmpty ? "Clipboard Snippet" : title,
            content: entry.content
        )
        modelContext.insert(record)
        try? modelContext.save()
        mode = .snippets
    }

    private func saveClipboardAsSnippet() {
        guard let clip = ClipboardService.shared.readPlainText(),
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Clipboard is empty or contains a concealed secret."
            return
        }

        let firstLine = clip
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Clipboard Snippet"
        let title = String(firstLine.prefix(48))

        let record = SnippetRecord(title: title.isEmpty ? "Clipboard Snippet" : title, content: clip)
        modelContext.insert(record)
        try? modelContext.save()
    }
}
