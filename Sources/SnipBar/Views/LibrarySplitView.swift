import SwiftData
import SwiftUI

public struct LibrarySplitView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SnippetRecord.updatedAt, order: .reverse) private var snippets: [SnippetRecord]
    @Query(sort: \TagRecord.name) private var tags: [TagRecord]

    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    @ObservedObject private var clipboardStore = ClipboardHistoryStore.shared
    @AppStorage("snipbar.autoPasteByDefault") private var autoPasteByDefault: Bool = false
    @AppStorage("snipbar.hotkeyChoice") private var hotkeyChoice: String = "cmd+shift+space"

    @State private var selectedCategory: String = "all"
    @State private var selectedSnippetID: UUID?
    @State private var selectedClipboardID: UUID?
    @State private var newTagName: String = ""
    @State private var isSecretRevealed: Bool = false
    @State private var hoveredTagName: String?
    @State private var copiedSnippetID: UUID?

    // Selective / All Export & Import state
    @State private var isShowingExportSheet: Bool = false
    @State private var pendingImportBundle: SnipBarExportBundle?
    @State private var pendingImportFileName: String = ""
    @State private var exchangeStatusBanner: String?

    public init() {}

    private var filteredSnippets: [SnippetRecord] {
        switch selectedCategory {
        case "all":
            return snippets
        case "pinned":
            return snippets.filter(\.isPinned)
        case "secrets":
            return snippets.filter(\.isSecret)
        default:
            if selectedCategory.hasPrefix("tag:") {
                let targetTag = String(selectedCategory.dropFirst(4))
                return snippets.filter { $0.tags.contains(where: { $0.name == targetTag }) }
            }
            return snippets
        }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            snippetMasterList
        } detail: {
            snippetDetailEditor
        }
        .frame(minWidth: 920, minHeight: 580)
        .onAppear {
            launchManager.refreshStatus()
            if selectedSnippetID == nil {
                selectedSnippetID = snippets.first?.id
            }
        }
        .onChange(of: selectedSnippetID) { _, _ in
            isSecretRevealed = false
        }
        .sheet(isPresented: $isShowingExportSheet) {
            ExportSnippetsSheet(
                snippets: snippets,
                allTags: tags,
                onExportCompleted: { count, fileName in
                    exchangeStatusBanner = "Exported \(count) snippet\(count == 1 ? "" : "s") to \(fileName)."
                }
            )
        }
        .sheet(item: $pendingImportBundle) { bundle in
            ImportSnippetsSheet(
                fileName: pendingImportFileName,
                bundle: bundle,
                existingSnippets: snippets,
                onConfirmImport: { selected, skipDuplicates in
                    do {
                        let summary = try SnippetExchangeService.importSnippets(
                            selected,
                            tagMetadata: bundle.tags,
                            into: modelContext,
                            skipDuplicates: skipDuplicates
                        )
                        var parts = ["Imported \(summary.importedCount) snippet\(summary.importedCount == 1 ? "" : "s")"]
                        if summary.createdTags > 0 {
                            parts.append("\(summary.createdTags) new tag\(summary.createdTags == 1 ? "" : "s")")
                        }
                        if summary.skippedDuplicates > 0 {
                            parts.append("\(summary.skippedDuplicates) duplicate\(summary.skippedDuplicates == 1 ? "" : "s") skipped")
                        }
                        exchangeStatusBanner = parts.joined(separator: " · ")
                    } catch {
                        exchangeStatusBanner = error.localizedDescription
                    }
                    pendingImportBundle = nil
                },
                onCancel: {
                    pendingImportBundle = nil
                }
            )
        }
        .alert(
            "SnipBar Import / Export",
            isPresented: Binding(
                get: { exchangeStatusBanner != nil },
                set: { if !$0 { exchangeStatusBanner = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                exchangeStatusBanner = nil
            }
        } message: {
            Text(exchangeStatusBanner ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selectedCategory) {
            Section("Library") {
                Label("All Snippets (\(snippets.count))", systemImage: "tray.full")
                    .tag("all")
                Label("Pinned", systemImage: "pin")
                    .tag("pinned")
                Label("Masked Secrets", systemImage: "eye.slash")
                    .tag("secrets")
                Label("Clipboard (\(clipboardStore.entries.count)/\(clipboardStore.maxEntries))", systemImage: "doc.on.clipboard")
                    .tag("clipboard")
            }

            Section("Tags") {
                ForEach(tags, id: \.name) { tag in
                    HStack(spacing: 6) {
                        Label("#\(tag.name)", systemImage: "number")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if hoveredTagName == tag.name || selectedCategory == "tag:\(tag.name)" {
                            Button(role: .destructive) {
                                deleteTag(tag)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete #\(tag.name)")
                        }
                    }
                    .onHover { isHovering in
                        if isHovering {
                            hoveredTagName = tag.name
                        } else if hoveredTagName == tag.name {
                            hoveredTagName = nil
                        }
                    }
                    .contextMenu {
                        Button("Delete #\(tag.name)", role: .destructive) {
                            deleteTag(tag)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", role: .destructive) {
                            deleteTag(tag)
                        }
                    }
                    .tag("tag:\(tag.name)")
                }
                HStack(spacing: 6) {
                    TextField("New tag…", text: $newTagName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createTag)
                    Button("Add", action: createTag)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }

            Section("System & Security") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchManager.isEnabled },
                        set: { launchManager.setEnabled($0) }
                    )
                )
                if launchManager.requiresSystemSettingsApproval {
                    Button("Approve in System Settings…") {
                        launchManager.openSystemLoginItemsSettings()
                    }
                    .font(.caption)
                }

                Toggle("Auto-Paste into Active App", isOn: $autoPasteByDefault)
                    .onChange(of: autoPasteByDefault) { _, enabled in
                        if enabled {
                            _ = AutoPasteService.shared.requestAccessibilityPermissionIfNeeded()
                        }
                    }

                Picker("Snippets Hotkey", selection: $hotkeyChoice) {
                    Text("⌘⇧Space").tag("cmd+shift+space")
                    Text("⌥S").tag("option+s")
                }
                .onChange(of: hotkeyChoice) { _, choice in
                    let combo: HotkeyCombo = (choice == "option+s") ? .optionS : .cmdShiftSpace
                    NotificationCenter.default.post(
                        name: .snipBarDidUpdateHotkey,
                        object: combo
                    )
                }

                Toggle("Clipboard History", isOn: $clipboardStore.isEnabled)
                if clipboardStore.isEnabled {
                    Toggle("Paste on Release ⌘", isOn: $clipboardStore.pasteOnReleaseCommand)
                    Stepper(
                        "Max Clippings: \(clipboardStore.maxEntries)",
                        value: $clipboardStore.maxEntries,
                        in: 10...ClipboardHistoryStore.hardMaxEntries,
                        step: 5
                    )
                    .font(.caption)
                    LabeledContent("Clipboard Hotkey", value: "⌘⇧V")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Share & Transfer") {
                Button {
                    isShowingExportSheet = true
                } label: {
                    Label("Export Snippets…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(snippets.isEmpty)

                Button {
                    openImportPicker()
                } label: {
                    Label("Import Snippets…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 248)
    }

    @ViewBuilder
    private var snippetMasterList: some View {
        if selectedCategory == "clipboard" {
            List(clipboardStore.entries, selection: $selectedClipboardID) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.previewLine)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if let app = entry.sourceApp, !app.isEmpty {
                            Text(app)
                            Text("·")
                        }
                        Text(entry.copiedAt, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(entry.id)
                .contextMenu {
                    Button("Save as Snippet") {
                        promoteClipboardEntryToSnippet(entry)
                    }
                    Button("Delete Clipping", role: .destructive) {
                        clipboardStore.remove(id: entry.id)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        clipboardStore.clearAll()
                        selectedClipboardID = nil
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .disabled(clipboardStore.entries.isEmpty)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } else {
            List(filteredSnippets, selection: $selectedSnippetID) { snippet in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(snippet.title.isEmpty ? "Untitled Snippet" : snippet.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if snippet.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if snippet.isSecret {
                        Image(systemName: snippet.requireBiometrics ? "touchid" : "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snippet.safePreviewLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
            .tag(snippet.id)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isShowingExportSheet = true
                } label: {
                    Label("Export Snippets", systemImage: "square.and.arrow.up")
                }
                .help("Export all or selected snippets to share with another Mac")
                .disabled(snippets.isEmpty)

                Button {
                    openImportPicker()
                } label: {
                    Label("Import Snippets", systemImage: "square.and.arrow.down")
                }
                .help("Import snippets from a .snipbar.json file")

                Button(action: createNewSnippet) {
                    Label("New Snippet", systemImage: "plus")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        }
    }

    @ViewBuilder
    private var snippetDetailEditor: some View {
        if selectedCategory == "clipboard" {
            if let entry = clipboardStore.entries.first(where: { $0.id == selectedClipboardID }) ?? clipboardStore.entries.first {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clipboard Clipping")
                                .font(.title3.weight(.bold))
                            HStack(spacing: 6) {
                                if let app = entry.sourceApp, !app.isEmpty {
                                    Text("Copied from \(app)")
                                    Text("·")
                                }
                                Text(entry.copiedAt, style: .relative)
                                Text("·")
                                Text("\(entry.characterCount) chars")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save as Snippet") {
                            promoteClipboardEntryToSnippet(entry)
                        }
                        .buttonStyle(.bordered)
                        Button("Copy Now") {
                            ClipboardService.shared.copy(entry.content, skipHistoryCapture: true)
                            clipboardStore.promoteToTop(id: entry.id)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .destructive) {
                            clipboardStore.remove(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }

                    ScrollView {
                        Text(entry.content)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(20)
            } else {
                ContentUnavailableView(
                    "Clipboard History Empty",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy text in any app and press ⌘⇧V to cycle and direct-paste up to \(clipboardStore.maxEntries) clippings.")
                )
            }
        } else if let snippet = snippets.first(where: { $0.id == selectedSnippetID }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField(
                        "Snippet Title",
                        text: Binding(
                            get: { snippet.title },
                            set: {
                                snippet.title = $0
                                snippet.updatedAt = .now
                            }
                        )
                    )
                    .font(.title3.weight(.bold))
                    .textFieldStyle(.plain)

                    Button {
                        copySnippetFromLibrary(snippet)
                    } label: {
                        Label(
                            copiedSnippetID == snippet.id ? "Copied" : "Copy",
                            systemImage: copiedSnippetID == snippet.id ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Toggle("Pinned", isOn: Binding(
                        get: { snippet.isPinned },
                        set: {
                            snippet.isPinned = $0
                            snippet.updatedAt = .now
                        }
                    ))
                    .toggleStyle(.button)

                    Button(role: .destructive) {
                        deleteSnippet(snippet)
                    } label: {
                        Image(systemName: "trash")
                    }
                }

                // Tag assignment bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.name) { tag in
                            let assigned = snippet.tags.contains(where: { $0.name == tag.name })
                            Button("#\(tag.name)") {
                                if assigned {
                                    snippet.tags.removeAll { $0.name == tag.name }
                                } else {
                                    snippet.tags.append(tag)
                                }
                                snippet.updatedAt = .now
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(assigned ? .accentColor : .gray.opacity(0.25))
                            .controlSize(.small)
                        }
                    }
                }

                Divider()

                // Secret Masking & Touch ID Confirmation Controls
                HStack(spacing: 16) {
                    Toggle("Sensitive / Masked Secret", isOn: Binding(
                        get: { snippet.isSecret },
                        set: { makeSecret in
                            isSecretRevealed = false
                            snippet.isSecret = makeSecret
                            if !makeSecret {
                                snippet.requireBiometrics = false
                            }
                            snippet.updatedAt = .now
                            try? modelContext.save()
                        }
                    ))

                    if snippet.isSecret {
                        Toggle("Require Touch ID to Copy", isOn: Binding(
                            get: { snippet.requireBiometrics },
                            set: {
                                snippet.requireBiometrics = $0
                                snippet.updatedAt = .now
                                try? modelContext.save()
                            }
                        ))

                        Stepper(
                            "Auto-clear clipboard: \(snippet.autoClearSeconds)s",
                            value: Binding(
                                get: { snippet.autoClearSeconds },
                                set: { snippet.autoClearSeconds = max(5, min(300, $0)) }
                            ),
                            step: 5
                        )
                        .font(.caption)
                    }
                }

                if snippet.isSecret {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Masked Secret Value (Concealed clipboard & Handoff-blocked)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(isSecretRevealed ? "Hide Value" : "Reveal Value") {
                                if isSecretRevealed {
                                    isSecretRevealed = false
                                } else if snippet.requireBiometrics {
                                    Task { @MainActor in
                                        if (try? await BiometricAuthService.shared.authenticate(
                                            reason: "reveal secret \"\(snippet.title)\""
                                        )) != nil {
                                            isSecretRevealed = true
                                        }
                                    }
                                } else {
                                    isSecretRevealed = true
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }

                        if isSecretRevealed {
                            TextField(
                                "Secret value…",
                                text: Binding(
                                    get: { snippet.content },
                                    set: {
                                        snippet.content = $0
                                        snippet.updatedAt = .now
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField(
                                "Enter secret token or password…",
                                text: Binding(
                                    get: { snippet.content },
                                    set: {
                                        snippet.content = $0
                                        snippet.updatedAt = .now
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()
                } else {
                    TextEditor(
                        text: Binding(
                            get: { snippet.content },
                            set: {
                                snippet.content = $0
                                snippet.updatedAt = .now
                            }
                        )
                    )
                    .font(.system(size: 13, design: .monospaced))
                    .padding(6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                "Select a Snippet",
                systemImage: "square.and.pencil",
                description: Text("Choose a snippet from the list or create a new one.")
            )
        }
    }

    private func copySnippetFromLibrary(_ snippet: SnippetRecord) {
        Task { @MainActor in
            if snippet.isSecret && snippet.requireBiometrics {
                guard (try? await BiometricAuthService.shared.authenticate(
                    reason: "copy secret snippet \"\(snippet.title)\""
                )) != nil else {
                    return
                }
            }

            var resolved = snippet.content
            if !snippet.isSecret {
                if resolved.contains("{{date}}") {
                    resolved = resolved.replacingOccurrences(
                        of: "{{date}}",
                        with: Date.now.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                if resolved.contains("{{time}}") {
                    resolved = resolved.replacingOccurrences(
                        of: "{{time}}",
                        with: Date.now.formatted(date: .omitted, time: .shortened)
                    )
                }
                if resolved.contains("{{clipboard}}") {
                    resolved = resolved.replacingOccurrences(
                        of: "{{clipboard}}",
                        with: ClipboardService.shared.readPlainText() ?? ""
                    )
                }
            }

            ClipboardService.shared.copy(
                resolved,
                isSecret: snippet.isSecret,
                isTransient: snippet.isSecret,
                autoClearAfterSeconds: snippet.isSecret ? snippet.autoClearSeconds : nil,
                skipHistoryCapture: snippet.isSecret,
                historySourceApp: "SnipBar Snippet"
            )

            snippet.usageCount += 1
            snippet.lastUsedAt = .now
            try? modelContext.save()

            copiedSnippetID = snippet.id
            try? await Task.sleep(for: .milliseconds(1400))
            if copiedSnippetID == snippet.id {
                copiedSnippetID = nil
            }
        }
    }

    private func createNewSnippet() {
        let created = SnippetRecord(title: "New Snippet", content: "")
        modelContext.insert(created)
        try? modelContext.save()
        selectedSnippetID = created.id
    }

    private func createTag() {
        let normalized = TagRecord.normalize(newTagName)
        guard !normalized.isEmpty, !tags.contains(where: { $0.name == normalized }) else { return }
        let record = TagRecord(name: normalized, color: .blue)
        modelContext.insert(record)
        try? modelContext.save()
        newTagName = ""
    }

    private func deleteTag(_ tag: TagRecord) {
        let deletedName = tag.name
        if selectedCategory == "tag:\(deletedName)" {
            selectedCategory = "all"
        }
        if hoveredTagName == deletedName {
            hoveredTagName = nil
        }
        for snippet in snippets where snippet.tags.contains(where: { $0.name == deletedName }) {
            snippet.tags.removeAll { $0.name == deletedName }
            snippet.updatedAt = .now
        }
        modelContext.delete(tag)
        try? modelContext.save()
    }

    private func promoteClipboardEntryToSnippet(_ entry: ClipboardHistoryEntry) {
        let title = String(entry.previewLine.prefix(48))
        let created = SnippetRecord(
            title: title.isEmpty ? "Clipboard Snippet" : title,
            content: entry.content
        )
        modelContext.insert(created)
        try? modelContext.save()
        selectedCategory = "all"
        selectedSnippetID = created.id
    }

    private func deleteSnippet(_ snippet: SnippetRecord) {
        modelContext.delete(snippet)
        try? modelContext.save()
        selectedSnippetID = snippets.first(where: { $0.id != snippet.id })?.id
    }

    private func openImportPicker() {
        do {
            if let result = try SnippetExchangeService.presentOpenPanel() {
                pendingImportFileName = result.url.lastPathComponent
                pendingImportBundle = result.bundle
            }
        } catch {
            exchangeStatusBanner = error.localizedDescription
        }
    }
}

extension SnipBarExportBundle: Identifiable {
    public var id: String { "\(exportedAt)-\(snippets.count)" }
}

private struct ExportSnippetsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let snippets: [SnippetRecord]
    let allTags: [TagRecord]
    let onExportCompleted: (_ count: Int, _ fileName: String) -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var filterText: String = ""
    @State private var errorMessage: String?

    private var visibleSnippets: [SnippetRecord] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }
        return FuzzySearchEngine.filter(snippets: snippets, rawQuery: trimmed)
    }

    private var selectedSecretCount: Int {
        snippets.filter { selectedIDs.contains($0.id) && $0.isSecret }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Snippets")
                        .font(.headline)
                    Text("Choose all or specific snippets to save as a portable .snipbar.json file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)

            Divider()

            // Quick selection toolbar + filter
            HStack(spacing: 8) {
                TextField("Filter snippets or #tag…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                Button("Non-Secrets") {
                    selectedIDs = Set(snippets.filter { !$0.isSecret }.map(\.id))
                }
                .controlSize(.small)
                Button("Select All") {
                    selectedIDs = Set(snippets.map(\.id))
                }
                .controlSize(.small)
                Button("Clear") {
                    selectedIDs.removeAll()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if selectedSecretCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(selectedSecretCount) masked secret\(selectedSecretCount == 1 ? "" : "s") selected — exported JSON contains plain text. Only share with trusted destinations.")
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            List(visibleSnippets) { snippet in
                let isSelected = selectedIDs.contains(snippet.id)
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(snippet.title.isEmpty ? "Untitled Snippet" : snippet.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if snippet.isSecret {
                                Label("Secret", systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if !snippet.tags.isEmpty {
                                Text(snippet.tags.map { "#\($0.name)" }.joined(separator: " "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(snippet.safePreviewLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected {
                        selectedIDs.remove(snippet.id)
                    } else {
                        selectedIDs.insert(snippet.id)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            HStack {
                Text("\(selectedIDs.count) of \(snippets.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Export \(selectedIDs.count) Snippet\(selectedIDs.count == 1 ? "" : "s")…") {
                    performExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .onAppear {
            // Safe default: pre-select all non-secret snippets so secrets are never accidentally shared
            selectedIDs = Set(snippets.filter { !$0.isSecret }.map(\.id))
        }
    }

    private func performExport() {
        let chosen = snippets.filter { selectedIDs.contains($0.id) }
        do {
            let data = try SnippetExchangeService.encode(snippets: chosen, allTags: allTags)
            if let savedURL = try SnippetExchangeService.presentSavePanel(data: data) {
                onExportCompleted(chosen.count, savedURL.lastPathComponent)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ImportSnippetsSheet: View {
    let fileName: String
    let bundle: SnipBarExportBundle
    let existingSnippets: [SnippetRecord]
    let onConfirmImport: (_ selected: [ExportedSnippetDTO], _ skipDuplicates: Bool) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var skipDuplicates: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Snippets")
                        .font(.headline)
                    Text("\(fileName) · \(bundle.snippets.count) snippet\(bundle.snippets.count == 1 ? "" : "s"), \(bundle.tags.count) tag\(bundle.tags.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)

            Divider()

            HStack(spacing: 10) {
                Toggle("Skip exact duplicates", isOn: $skipDuplicates)
                    .font(.caption)
                Spacer()
                Button("Select New") {
                    selectedIDs = Set(
                        bundle.snippets
                            .filter { !SnippetExchangeService.isDuplicate($0, in: existingSnippets) }
                            .map(\.id)
                    )
                }
                .controlSize(.small)
                Button("Select All") {
                    selectedIDs = Set(bundle.snippets.map(\.id))
                }
                .controlSize(.small)
                Button("Clear") {
                    selectedIDs.removeAll()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List(bundle.snippets) { dto in
                let isSelected = selectedIDs.contains(dto.id)
                let duplicate = SnippetExchangeService.isDuplicate(dto, in: existingSnippets)
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(dto.title.isEmpty ? "Untitled Snippet" : dto.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if duplicate {
                                Text("Already in Library")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                            if dto.isSecret {
                                Label("Secret", systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if !dto.tags.isEmpty {
                                Text(dto.tags.map { "#\($0)" }.joined(separator: " "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(dto.safePreviewLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected {
                        selectedIDs.remove(dto.id)
                    } else {
                        selectedIDs.insert(dto.id)
                    }
                }
            }

            Divider()

            HStack {
                Text("\(selectedIDs.count) of \(bundle.snippets.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Import \(selectedIDs.count) Snippet\(selectedIDs.count == 1 ? "" : "s")") {
                    let chosen = bundle.snippets.filter { selectedIDs.contains($0.id) }
                    onConfirmImport(chosen, skipDuplicates)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
        .onAppear {
            selectedIDs = Set(
                bundle.snippets
                    .filter { !SnippetExchangeService.isDuplicate($0, in: existingSnippets) }
                    .map(\.id)
            )
        }
    }
}

public extension Notification.Name {
    static let snipBarDidUpdateHotkey = Notification.Name("dev.snipbar.didUpdateHotkey")
}
