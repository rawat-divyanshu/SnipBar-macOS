import Foundation
import SwiftData

public enum SnippetTagColor: String, Codable, CaseIterable, Sendable {
    case blue
    case emerald
    case amber
    case rose
    case violet
    case slate

    public var label: String {
        switch self {
        case .blue: return "Ocean Blue"
        case .emerald: return "Forest Green"
        case .amber: return "Warm Amber"
        case .rose: return "Signal Rose"
        case .violet: return "Studio Violet"
        case .slate: return "Neutral Slate"
        }
    }
}

@Model
public final class TagRecord {
    @Attribute(.unique) public var name: String
    public var colorRawValue: String
    public var createdAt: Date

    @Relationship(inverse: \SnippetRecord.tags)
    public var snippets: [SnippetRecord] = []

    public var color: SnippetTagColor {
        get { SnippetTagColor(rawValue: colorRawValue) ?? .slate }
        set { colorRawValue = newValue.rawValue }
    }

    public init(name: String, color: SnippetTagColor = .blue, createdAt: Date = .now) {
        self.name = TagRecord.normalize(name)
        self.colorRawValue = color.rawValue
        self.createdAt = createdAt
    }

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
    }
}

/// Persisted snippet model in SwiftData (`~/Library/Application Support/SnipBar`, `chmod 0700`).
/// When `isSecret == true`, SnipBar masks UI previews (`••••••••`), excludes the body from
/// fuzzy search, optionally gates copying behind Touch ID (`BiometricAuthService`), blocks
/// Universal Clipboard Handoff, marks clipboard writes `ConcealedType`, and auto-clears after 30s.
@Model
public final class SnippetRecord {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var content: String
    public var isPinned: Bool
    public var isSecret: Bool
    public var requireBiometrics: Bool
    public var autoClearSeconds: Int
    public var usageCount: Int
    public var lastUsedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var tags: [TagRecord] = []

    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        tags: [TagRecord] = [],
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
        self.usageCount = 0
        self.lastUsedAt = nil
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Masked single-line preview for list rows when `isSecret` is enabled.
    public var safePreviewLine: String {
        if isSecret {
            return "••••••••••••••••••••••••"
        }
        return content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
