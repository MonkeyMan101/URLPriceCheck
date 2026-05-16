import Foundation

/// Finds a price immediately before/after user hint phrases (e.g. £99.99 before "12 months").
enum HintAnchoredPriceExtractor {

    static func extract(from html: String, hints: CustomKeywordHints) -> DetectedPrice? {
        guard !hints.isEmpty else { return nil }

        let sources = [
            stripTagsKeepPrices(html),
            HTMLTextStripper.visibleText(from: html, limit: 25_000),
        ]

        for text in sources {
            if let price = extractAnnualTwelveMonths(in: text) { return price }

            for hint in hints.right + hints.left {
                guard hint.count >= 3, !hint.contains("class") else { continue }
                if hint.contains("12 month") || hint.contains("year") {
                    if let price = bestPriceBeforePhrase(in: text, phrase: hint) { return price }
                } else {
                    if let price = priceBeforePhraseTight(in: text, phrase: hint) { return price }
                    if let price = priceAfterPhraseTight(in: text, phrase: hint) { return price }
                }
            }
        }
        return nil
    }

    private static func stripTagsKeepPrices(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func extractAnnualTwelveMonths(in text: String) -> DetectedPrice? {
        let patterns = [
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*12\s*months"#,
            #"(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*12\s*months"#,
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*year"#,
        ]
        for pattern in patterns {
            if let raw = firstCapture(text, pattern: pattern),
               let price = parsePrice(raw) {
                return DetectedPrice(amount: price.amount, currency: price.currency, display: price.display, source: "hint-annual")
            }
        }
        return nil
    }

    /// All £ prices before phrase — pick highest when phrase is "12 months" (annual, not £12.43/month).
    private static func bestPriceBeforePhrase(in text: String, phrase: String) -> DetectedPrice? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "([£$€]\\s*\\d{1,3}(?:,\\d{3})*(?:\\.\\d{2})?)([\\s\\S]{0,50}?)\(escaped)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        var best: (price: DetectedPrice, score: Int)?

        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, match.numberOfRanges > 2,
                  let priceRange = Range(match.range(at: 1), in: text),
                  let gapRange = Range(match.range(at: 2), in: text),
                  let parsed = parsePrice(String(text[priceRange])) else { return }

            let gap = String(text[gapRange]).lowercased()
            var score = 0
            if gap.trimmingCharacters(in: .whitespaces).hasPrefix("/") { score += 50 }
            if gap.contains("12 month") { score += 40 }
            if parsed.amount >= 50 { score += 30 }
            if parsed.amount < 20 { score -= 50 }
            if gap.contains("/month") && !gap.contains("12") { score -= 40 }

            let candidate = DetectedPrice(
                amount: parsed.amount, currency: parsed.currency, display: parsed.display, source: "hint-left"
            )
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }

        guard let best, best.score > 0 else { return nil }
        return best.price
    }

    private static func priceBeforePhraseTight(in text: String, phrase: String) -> DetectedPrice? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "([£$€]\\s*\\d{1,3}(?:,\\d{3})*(?:\\.\\d{2})?)\\s{0,15}\(escaped)"
        guard let raw = firstCapture(text, pattern: pattern),
              let price = parsePrice(raw) else { return nil }
        return DetectedPrice(amount: price.amount, currency: price.currency, display: price.display, source: "hint-left")
    }

    private static func priceAfterPhraseTight(in text: String, phrase: String) -> DetectedPrice? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "\(escaped)\\s{0,15}([£$€]\\s*\\d{1,3}(?:,\\d{3})*(?:\\.\\d{2})?)"
        guard let raw = firstCapture(text, pattern: pattern),
              let price = parsePrice(raw) else { return nil }
        return DetectedPrice(amount: price.amount, currency: price.currency, display: price.display, source: "hint-right")
    }

    private static func firstCapture(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func parsePrice(_ raw: String) -> (amount: Decimal, currency: String, display: String)? {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"([£$€])([\d,]+\.?\d*)"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let symR = Range(match.range(at: 1), in: cleaned),
              let amtR = Range(match.range(at: 2), in: cleaned) else { return nil }

        let symbol = String(cleaned[symR])
        let amtStr = String(cleaned[amtR]).replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: amtStr), amount >= 1 else { return nil }

        let currency = symbol == "£" ? "GBP" : symbol == "€" ? "EUR" : "USD"
        let display = amtStr.contains(".") ? "\(symbol)\(amtStr)" : "\(symbol)\(amtStr).00"
        return (amount, currency, display)
    }
}
