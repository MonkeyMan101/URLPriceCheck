import Foundation

/// Scores price candidates using nearby words to the left and right — no network required.
enum SmartPriceFinder {

    private struct Candidate {
        let amount: Decimal
        let currency: String
        let display: String
        let score: Int
    }

    static func find(
        in html: String,
        productName: String?,
        pageURL: URL?,
        customHints: CustomKeywordHints = .empty
    ) -> DetectedPrice? {
        let text = HTMLTextStripper.visibleText(from: html)
        guard !text.isEmpty else { return nil }

        let profile = StoreKeywordProfile.profile(for: pageURL) ?? StoreKeywordProfile.generic
        let nameTokens: [String] = productName?
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 } ?? []

        var candidates: [Candidate] = []

        let patterns: [(String, String, String)] = [
            (#"£\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "GBP", "£"),
            (#"\$\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "USD", "$"),
            (#"€\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "EUR", "€"),
            (#"(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*(?:GBP|USD|EUR)"#, "GBP", "£"),
        ]

        for (pattern, defaultCurrency, symbol) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let amountRange = Range(match.range(at: 1), in: text),
                      let amount = parseAmount(String(text[amountRange])),
                      isReasonableProductPrice(amount) else { return }

                let (left, right, anywhere) = contextWindows(
                    in: text,
                    matchLocation: match.range.location,
                    matchLength: match.range.length,
                    leftChars: 140,
                    rightChars: 140
                )

                let score = scoreContext(
                    left: left,
                    right: right,
                    anywhere: anywhere,
                    profile: profile,
                    customHints: customHints,
                    nameTokens: nameTokens,
                    matchIndex: match.range.location,
                    amount: amount
                )

                let display = formatDisplay(
                    amount: amount,
                    currency: defaultCurrency,
                    symbol: symbol
                )
                candidates.append(
                    Candidate(amount: amount, currency: defaultCurrency, display: display, score: score)
                )
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }), best.score > 0 else {
            return nil
        }

        return DetectedPrice(
            amount: best.amount,
            currency: best.currency,
            display: best.display,
            source: "smart-\(profile.id)"
        )
    }

    // MARK: - Context scoring

    private static func contextWindows(
        in text: String,
        matchLocation: Int,
        matchLength: Int,
        leftChars: Int,
        rightChars: Int
    ) -> (left: String, right: String, anywhere: String) {
        let utf16 = text.utf16.count
        let leftStart = max(0, matchLocation - leftChars)
        let leftLen = matchLocation - leftStart
        let rightStart = matchLocation + matchLength
        let rightLen = min(rightChars, utf16 - rightStart)

        func slice(_ location: Int, _ length: Int) -> String {
            guard length > 0, let r = Range(NSRange(location: location, length: length), in: text) else {
                return ""
            }
            return String(text[r]).lowercased()
        }

        let left = slice(leftStart, leftLen)
        let right = slice(rightStart, rightLen)
        return (left, right, left + " " + right)
    }

    private static func scoreContext(
        left: String,
        right: String,
        anywhere: String,
        profile: StoreKeywordProfile,
        customHints: CustomKeywordHints,
        nameTokens: [String],
        matchIndex: Int,
        amount: Decimal
    ) -> Int {
        var score = 0

        for kw in profile.positiveAnywhere where anywhere.contains(kw) { score += 4 }
        for kw in profile.positiveLeft where left.contains(kw) { score += 5 }
        for kw in profile.positiveRight where right.contains(kw) { score += 5 }
        for kw in profile.negativeAnywhere where anywhere.contains(kw) { score -= 8 }

        for kw in customHints.left where left.contains(kw) { score += 7 }
        for kw in customHints.right where right.contains(kw) { score += 7 }
        for kw in customHints.negative where anywhere.contains(kw) { score -= 10 }

        if customHints.wantsAnnualPlan, anywhere.contains("12 month") {
            score += 12
        }

        if profile.id == "geforce" {
            if anywhere.contains("12 month"), amount < 25 { score -= 60 }
            if right.trimmingCharacters(in: .whitespaces).hasPrefix("/")
                || anywhere.contains("/12") { score += 25 }
            if amount >= 50 { score += 15 }
        }

        if profile.id == "amazon" {
            if left.contains("was:") || left.hasSuffix("was") || anywhere.contains("was:") { score -= 50 }
            if anywhere.contains("list price") || anywhere.contains("typical:") { score -= 40 }
            if anywhere.contains("limited time deal") || anywhere.contains("deal price") { score += 25 }
            if left.contains("now") || anywhere.contains("price to pay") { score += 15 }
        }

        for token in nameTokens where anywhere.contains(token) { score += 6 }

        for tier in profile.tierNameHints {
            if anywhere.contains(tier) { score += 8 }
        }

        // Main product / hero content usually appears earlier on the page.
        if matchIndex < 6_000 { score += 3 }
        else if matchIndex < 15_000 { score += 1 }
        else { score -= 2 }

        return score
    }

    private static func isReasonableProductPrice(_ amount: Decimal) -> Bool {
        amount >= 0.5 && amount <= 9_999
    }

    private static func parseAmount(_ raw: String) -> Decimal? {
        Decimal(string: raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func formatDisplay(amount: Decimal, currency: String, symbol: String) -> String {
        let n = NSDecimalNumber(decimal: amount)
        let formatted = String(format: "%.2f", n.doubleValue)
        switch currency {
        case "USD": return "$\(formatted)"
        case "EUR": return "€\(formatted)"
        default: return "£\(formatted)"
        }
    }
}
