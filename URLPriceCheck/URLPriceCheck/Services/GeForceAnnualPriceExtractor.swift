import Foundation

/// GeForce NOW annual pricing (£99.99/12 months) — avoids grabbing monthly £12.43.
enum GeForceAnnualPriceExtractor {

    static func extract(
        from html: String,
        productName: String?,
        hints: CustomKeywordHints = .empty
    ) -> DetectedPrice? {
        let raw = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // 1) Tight annual patterns (highest priority).
        let tightPatterns = [
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*12\s*months"#,
            #"(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*12\s*months"#,
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*year"#,
            #"(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*year"#,
        ]
        for pattern in tightPatterns {
            if let price = firstPrice(in: raw, pattern: pattern, source: "geforce-annual") {
                return price
            }
        }

        // 2) Split HTML price tags: £ 99 . 99 / 12 months
        let splitPattern = #"£\s*(\d{1,3})\s*[\.\s,]*(\d{2})\s*/\s*12\s*months"#
        if let price = firstPrice(in: raw, pattern: splitPattern, source: "geforce-annual", fractionGroup: 2) {
            return price
        }

        // 3) data-testid="price" blocks (React site).
        let testIdPatterns = [
            #"data-testid\s*=\s*[\"']price[\"'][^>]*>\s*([£$€]\s*[\d,]+\.?\d*)"#,
            #"data-testid\s*=\s*[\"']price[\"'][^£$€\d]{0,40}([£$€]\s*[\d,]+\.?\d*)"#,
        ]
        for pattern in testIdPatterns {
            if let price = firstPrice(in: raw, pattern: pattern, source: "geforce-testid") {
                if price.amount >= 25 { return price }
            }
        }

        // 4) All prices near "12 months" — pick best (usually £99.99 not £12.43).
        if let best = bestPriceNearTwelveMonths(in: raw, hints: hints) {
            return best
        }

        // 5) Tier + annual (Performance, Ultimate, …).
        if let tier = preferredTier(productName: productName, in: raw) {
            let tierPattern = "\(NSRegularExpression.escapedPattern(for: tier))[\\s\\S]{0,200}?([£$€]\\s*\\d{1,3}(?:,\\d{3})*(?:\\.\\d{2})?)\\s*/\\s*12\\s*months"
            if let price = firstPrice(in: raw, pattern: tierPattern, source: "geforce-tier-annual") {
                return price
            }
        }

        return nil
    }

    // MARK: - Near "12 months"

    private struct Scored {
        let price: DetectedPrice
        let score: Int
    }

    private static func bestPriceNearTwelveMonths(in text: String, hints: CustomKeywordHints) -> DetectedPrice? {
        let phrases = ["12 months", "12 month", "/year", "per year"] + hints.right.filter { $0.contains("month") || $0.contains("year") }
        let uniquePhrases = Array(Set(phrases)).filter { $0.count >= 3 }

        var scored: [Scored] = []
        let pricePattern = #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#
        guard let regex = try? NSRegularExpression(pattern: pricePattern, options: .caseInsensitive) else { return nil }

        for phrase in uniquePhrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let bridge = "([\\s\\S]{0,25}?)\(escaped)"
            guard (try? NSRegularExpression(pattern: bridge, options: .caseInsensitive)) != nil else { continue }

            regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let priceRange = Range(match.range(at: 1), in: text),
                      let parsed = parseRawPrice(String(text[priceRange])) else { return }

                let priceEnd = match.range.location + match.range.length
                let searchStart = priceEnd
                let searchLen = min(60, text.utf16.count - searchStart)
                guard searchLen > 0, let bridgeRange = Range(NSRange(location: searchStart, length: searchLen), in: text) else { return }
                let gap = String(text[bridgeRange])

                var score = 0
                if gap.contains("12 month") || gap.contains("/12") { score += 50 }
                if gap.trimmingCharacters(in: .whitespaces).hasPrefix("/") { score += 40 }
                if parsed.amount >= 50 { score += 30 }
                if parsed.amount >= 25 { score += 10 }
                if parsed.amount < 20 { score -= 40 } // monthly plans like £12.43
                if gap.lowercased().contains("/month") && !gap.contains("12") { score -= 30 }

                scored.append(Scored(price: DetectedPrice(
                    amount: parsed.amount,
                    currency: parsed.currency,
                    display: parsed.display,
                    source: "geforce-near-12mo"
                ), score: score))
            }
        }

        return scored.max(by: { $0.score < $1.score })?.price
    }

    // MARK: - Helpers

    private static func preferredTier(productName: String?, in text: String) -> String? {
        let tiers = ["performance", "ultimate", "priority", "free", "perfomace", "perfomance"]
        let name = productName?.lowercased() ?? ""
        if let t = tiers.first(where: { name.contains($0) }) { return t }
        return tiers.first { text.lowercased().contains($0) }
    }

    private static func firstPrice(
        in text: String,
        pattern: String,
        source: String,
        fractionGroup: Int? = nil
    ) -> DetectedPrice? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let r1 = Range(match.range(at: 1), in: text) else { return nil }

        if let fg = fractionGroup, match.numberOfRanges > fg,
           let r2 = Range(match.range(at: fg), in: text) {
            let whole = String(text[r1]).replacingOccurrences(of: ",", with: "")
            let frac = String(text[r2])
            guard let amount = Decimal(string: "\(whole).\(frac)") else { return nil }
            return DetectedPrice(amount: amount, currency: "GBP", display: "£\(whole).\(frac)", source: source)
        }

        let raw = String(text[r1])
        if raw.first?.isNumber == true, !raw.contains("£"), !raw.contains("$") {
            guard let amount = Decimal(string: raw.replacingOccurrences(of: ",", with: "")) else { return nil }
            let display = "£\(String(format: "%.2f", NSDecimalNumber(decimal: amount).doubleValue))"
            return DetectedPrice(amount: amount, currency: "GBP", display: display, source: source)
        }

        guard let parsed = parseRawPrice(raw) else { return nil }
        return DetectedPrice(amount: parsed.amount, currency: parsed.currency, display: parsed.display, source: source)
    }

    private static func parseRawPrice(_ raw: String) -> (amount: Decimal, currency: String, display: String)? {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"([£$€]?)([\d,]+\.?\d*)"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let amtR = Range(match.range(at: 2), in: cleaned) else { return nil }

        let symR = Range(match.range(at: 1), in: cleaned).map { String(cleaned[$0]) } ?? "£"
        let amtStr = String(cleaned[amtR]).replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: amtStr), amount >= 1 else { return nil }

        let symbol = symR.isEmpty ? "£" : symR
        let currency = symbol == "£" ? "GBP" : symbol == "€" ? "EUR" : "USD"
        let display = amtStr.contains(".") ? "\(symbol)\(amtStr)" : "\(symbol)\(amtStr).00"
        return (amount, currency, display)
    }
}
