import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

public struct ExportedTagDTO: Codable, Equatable, Sendable {
    public let name: String
    public let color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct ExportedSnippetDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let content: String
    public let tags: [String]
    public let isPinned: Bool
    public let isSecret: Bool
    public let requireBiometrics: Bool
    public let autoClearSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case title
        case content
        case tags
        case isPinned
        case isSecret
        case requireBiometrics
        case autoClearSeconds
    }

    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        tags: [String] = [],
        isPinned: Bool = false,
        isSecret: Bool = false,
        requireBiometrics: Bool = false,
        autoClearSeconds: Int = 30
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.isPinned = isPinned
        self.isSecret = isSecret
        self.requireBiometrics = isSecret ? requireBiometrics : false
        self.autoClearSeconds = autoClearSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.content = try container.decode(String.self, forKey: .content)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let secret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        self.isSecret = secret
        let bio = try container.decodeIfPresent(Bool.self, forKey: .requireBiometrics) ?? false
        self.requireBiometrics = secret ? bio : false
        self.autoClearSeconds = try container.decodeIfPresent(Int.self, forKey: .autoClearSeconds) ?? 30
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(tags, forKey: .tags)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isSecret, forKey: .isSecret)
        try container.encode(requireBiometrics, forKey: .requireBiometrics)
        try container.encode(autoClearSeconds, forKey: .autoClearSeconds)
    }

    public var safePreviewLine: String {
        if isSecret {
            return "••••••••••••••••••••••••"
        }
        return content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SnipBarExportBundle: Codable, Equatable, Sendable {
    public static let expectedFormat = "snipbar-export"
    public static let currentVersion = 1

    public let format: String
    public let version: Int
    public let exportedAt: String
    public let tags: [ExportedTagDTO]
    public let snippets: [ExportedSnippetDTO]

    public init(
        format: String = SnipBarExportBundle.expectedFormat,
        version: Int = SnipBarExportBundle.currentVersion,
        exportedAt: String = ISO8601DateFormatter().string(from: .now),
        tags: [ExportedTagDTO],
        snippets: [ExportedSnippetDTO]
    ) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.tags = tags
        self.snippets = snippets
    }
}

public struct SnippetImportSummary: Equatable, Sendable {
    public let importedCount: Int
    public let skippedDuplicates: Int
    public let createdTags: Int
}

public enum SnippetExchangeError: LocalizedError {
    case emptySelection
    case invalidFormat
    case unsupportedVersion(Int)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select at least one snippet to export."
        case .invalidFormat:
            return "This file is not a valid SnipBar snippet export (.snipbar.json)."
        case .unsupportedVersion(let ver):
            return "Export format version \(ver) is newer than this version of SnipBar."
        case .decodingFailed(let detail):
            return "Could not read snippet export file: \(detail)"
        }
    }
}

/// Portable, human-readable JSON exporter & importer for sharing selective or full
/// SnipBar snippet collections between Macs.
public enum SnippetExchangeService {
    /// Builds a portable `SnipBarExportBundle` containing only the chosen snippets
    /// and the tag definitions referenced by those snippets.
    public static func makeBundle(
        snippets: [SnippetRecord],
        allTags: [TagRecord]
    ) -> SnipBarExportBundle {
        let tagColorByName = Dictionary(
            uniqueKeysWithValues: allTags.map { ($0.name.lowercased(), $0.colorRawValue) }
        )

        var referencedTagNames = Set<String>()
        let exportedSnippets: [ExportedSnippetDTO] = snippets.map { record in
            let names = record.tags.map { TagRecord.normalize($0.name) }.filter { !$0.isEmpty }
            for name in names {
                referencedTagNames.insert(name)
            }
            return ExportedSnippetDTO(
                title: record.title,
                content: record.content,
                tags: names,
                isPinned: record.isPinned,
                isSecret: record.isSecret,
                requireBiometrics: record.requireBiometrics,
                autoClearSeconds: record.autoClearSeconds
            )
        }

        let exportedTags = referencedTagNames
            .sorted()
            .map { name in
                ExportedTagDTO(
                    name: name,
                    color: tagColorByName[name] ?? SnippetTagColor.blue.rawValue
                )
            }

        return SnipBarExportBundle(
            tags: exportedTags,
            snippets: exportedSnippets
        )
    }

    public static func encode(bundle: SnipBarExportBundle) throws -> Data {
        guard !bundle.snippets.isEmpty else {
            throw SnippetExchangeError.emptySelection
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    public static func encode(
        snippets: [SnippetRecord],
        allTags: [TagRecord]
    ) throws -> Data {
        let bundle = makeBundle(snippets: snippets, allTags: allTags)
        return try encode(bundle: bundle)
    }

    public static func decode(data: Data) throws -> SnipBarExportBundle {
        let bundle: SnipBarExportBundle
        do {
            bundle = try JSONDecoder().decode(SnipBarExportBundle.self, from: data)
        } catch {
            throw SnippetExchangeError.decodingFailed(error.localizedDescription)
        }

        guard bundle.format == SnipBarExportBundle.expectedFormat else {
            throw SnippetExchangeError.invalidFormat
        }
        guard bundle.version <= SnipBarExportBundle.currentVersion else {
            throw SnippetExchangeError.unsupportedVersion(bundle.version)
        }
        return bundle
    }

    public static func isDuplicate(
        _ dto: ExportedSnippetDTO,
        in existing: [SnippetRecord]
    ) -> Bool {
        let normalizedTitle = dto.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return existing.contains { record in
            record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                && record.content == dto.content
        }
    }

    @MainActor
    public static func importSnippets(
        _ selected: [ExportedSnippetDTO],
        tagMetadata: [ExportedTagDTO],
        into context: ModelContext,
        skipDuplicates: Bool = true
    ) throws -> SnippetImportSummary {
        let existingSnippets = (try? context.fetch(FetchDescriptor<SnippetRecord>())) ?? []
        let existingTags = (try? context.fetch(FetchDescriptor<TagRecord>())) ?? []

        var tagsByName = Dictionary(
            uniqueKeysWithValues: existingTags.map { ($0.name.lowercased(), $0) }
        )
        let incomingColorByName = Dictionary(
            uniqueKeysWithValues: tagMetadata.map { (TagRecord.normalize($0.name), $0.color) }
        )

        var importedCount = 0
        var skippedDuplicates = 0
        var createdTags = 0

        for dto in selected {
            if skipDuplicates && isDuplicate(dto, in: existingSnippets) {
                skippedDuplicates += 1
                continue
            }

            var resolvedTags: [TagRecord] = []
            var seenTagNames = Set<String>()
            for rawTag in dto.tags {
                let normalized = TagRecord.normalize(rawTag)
                guard !normalized.isEmpty, seenTagNames.insert(normalized).inserted else { continue }
                if let existingTag = tagsByName[normalized] {
                    resolvedTags.append(existingTag)
                } else {
                    let colorRaw = incomingColorByName[normalized] ?? SnippetTagColor.blue.rawValue
                    let color = SnippetTagColor(rawValue: colorRaw) ?? .blue
                    let newTag = TagRecord(name: normalized, color: color)
                    context.insert(newTag)
                    tagsByName[normalized] = newTag
                    resolvedTags.append(newTag)
                    createdTags += 1
                }
            }

            let title = dto.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = SnippetRecord(
                title: title.isEmpty ? "Imported Snippet" : title,
                content: dto.content,
                tags: resolvedTags,
                isPinned: dto.isPinned,
                isSecret: dto.isSecret,
                requireBiometrics: dto.isSecret ? dto.requireBiometrics : false,
                autoClearSeconds: max(5, min(300, dto.autoClearSeconds))
            )
            context.insert(record)
            importedCount += 1
        }

        if importedCount > 0 || createdTags > 0 {
            try context.save()
        }

        return SnippetImportSummary(
            importedCount: importedCount,
            skippedDuplicates: skippedDuplicates,
            createdTags: createdTags
        )
    }

    @MainActor
    public static func defaultExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "SnipBar-Snippets-\(formatter.string(from: .now)).snipbar.json"
    }

    @MainActor
    public static func presentSavePanel(data: Data) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export SnipBar Snippets"
        panel.nameFieldStringValue = defaultExportFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        try data.write(to: url, options: [.atomic])
        return url
    }

    @MainActor
    public static func presentOpenPanel() throws -> (url: URL, bundle: SnipBarExportBundle)? {
        let panel = NSOpenPanel()
        panel.title = "Import SnipBar Snippets"
        panel.prompt = "Choose Export File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let bundle = try decode(data: data)
        return (url, bundle)
    }
}
