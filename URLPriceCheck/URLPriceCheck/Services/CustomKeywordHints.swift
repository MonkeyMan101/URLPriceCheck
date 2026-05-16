import Foundation

/// User-provided words/phrases (comma-separated in the UI) merged with store defaults.
struct CustomKeywordHints: Sendable {
    var left: [String] = []
    var right: [String] = []
    var negative: [String] = []

    static let empty = CustomKeywordHints()

    static func from(item: WatchedItem) -> CustomKeywordHints {
        CustomKeywordHints(
            left: parseList(item.keywordsLeft),
            right: parseList(item.keywordsRight),
            negative: parseList(item.keywordsNegative)
        )
    }

    static func parseList(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var results: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let token = sanitizeToken(String(part))
            if !token.isEmpty { results.append(token) }
        }
        return results
    }

    /// Strips HTML and keeps human-readable hint words (not CSS class names).
    private static func sanitizeToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("<") {
            s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        if s.contains("class=") || s.contains("data-testid") {
            return ""
        }
        s = s.lowercased()
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wantsAnnualPlan: Bool {
        let annualPhrases = ["12 months", "12 month", "/year", "per year", "annual", "yearly", "billed annually"]
        return right.contains { r in annualPhrases.contains(where: { r.contains($0) }) }
            || left.contains { l in annualPhrases.contains(where: { l.contains($0) }) }
    }

    var isEmpty: Bool { left.isEmpty && right.isEmpty && negative.isEmpty }
}
