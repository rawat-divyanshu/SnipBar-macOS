import Foundation

/// Unicode-safe fuzzy search engine for SnipBar.
/// Supports inline `#tag` tokens, subsequence character scoring with word-boundary bonuses,
/// and smart empty-query sorting (Pinned first, then Recently Used / Frequently Used).
/// SECURITY: Never indexes secret payloads (`plainContent` is empty when `isSecret == true`),
/// matching secrets strictly by title and tags so secret contents cannot be probed via timing/search.
public enum FuzzySearchEngine {
    public static func filter(
        snippets: [SnippetRecord],
        rawQuery: String,
        selectedTag: String? = nil,
        pinnedOnly: Bool = false
    ) -> [SnippetRecord] {
        let tokens = rawQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let hashTags = tokens
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .map { String($0.dropFirst()).lowercased() }

        let textTokens = tokens.filter { !$0.hasPrefix("#") }

        var scored: [(snippet: SnippetRecord, score: Double)] = []
        scored.reserveCapacity(snippets.count)

        for snippet in snippets {
            if pinnedOnly && !snippet.isPinned { continue }

            if let selectedTag {
                let matchesSelected = snippet.tags.contains {
                    $0.name.caseInsensitiveCompare(selectedTag) == .orderedSame
                }
                if !matchesSelected { continue }
            }

            if !hashTags.isEmpty {
                let matchesAllHashes = hashTags.allSatisfy { needle in
                    snippet.tags.contains { $0.name.localizedCaseInsensitiveContains(needle) }
                }
                if !matchesAllHashes { continue }
            }

            if textTokens.isEmpty {
                scored.append((snippet, snippet.isPinned ? 1_000 : 100))
                continue
            }

            var totalScore = 0.0
            var matchedAll = true

            for token in textTokens {
                let titleScore = Double(tokenScore(query: token, target: snippet.title)) * 2.2
                let tagScore = snippet.tags
                    .map { Double(tokenScore(query: token, target: $0.name)) * 1.8 }
                    .max() ?? 0.0
                let bodyScore = snippet.isSecret
                    ? 0.0
                    : Double(tokenScore(query: token, target: snippet.content))

                let best = max(titleScore, max(tagScore, bodyScore))
                if best <= 0 {
                    matchedAll = false
                    break
                }
                totalScore += best
            }

            if matchedAll {
                if snippet.isPinned { totalScore += 45 }
                totalScore += Double(min(snippet.usageCount, 25))
                scored.append((snippet, totalScore))
            }
        }

        scored.sort { lhs, rhs in
            if textTokens.isEmpty {
                if lhs.snippet.isPinned != rhs.snippet.isPinned {
                    return lhs.snippet.isPinned && !rhs.snippet.isPinned
                }
                let lhsDate = lhs.snippet.lastUsedAt ?? lhs.snippet.updatedAt
                let rhsDate = rhs.snippet.lastUsedAt ?? rhs.snippet.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.snippet.usageCount > rhs.snippet.usageCount
            }
            return lhs.score > rhs.score
        }

        return scored.map(\.snippet)
    }

    private static func tokenScore(query: String, target: String) -> Int {
        guard !query.isEmpty, !target.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let t = Array(target.lowercased())

        // Fast exact substring check with boundary bonus
        if let range = target.range(of: query, options: .caseInsensitive) {
            let offset = target.distance(from: target.startIndex, to: range.lowerBound)
            let isBoundary = offset == 0 || isWordSeparator(t[max(0, offset - 1)])
            return 100 + (isBoundary ? 30 : 0) - min(offset, 40)
        }

        var qi = 0
        var score = 0
        var consecutive = 0

        for ti in t.indices where qi < q.count {
            if t[ti] == q[qi] {
                consecutive += 1
                score += 8 + consecutive * 4
                if ti == 0 || isWordSeparator(t[ti - 1]) {
                    score += 10
                }
                qi += 1
            } else {
                consecutive = 0
            }
        }

        return qi == q.count ? score : 0
    }

    private static func isWordSeparator(_ ch: Character) -> Bool {
        ch.isWhitespace || ch == "-" || ch == "_" || ch == "/" || ch == "." || ch == "#"
    }
}
