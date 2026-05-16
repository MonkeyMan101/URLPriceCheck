import Foundation

/// Raw-HTML extractors tuned for specific retailers (before generic text scoring).
enum StoreHTMLPriceExtractor {

    static func extract(from html: String, pageURL: URL?, productName: String?) -> DetectedPrice? {
        guard let host = pageURL?.host?.lowercased() else { return nil }
        if host.contains("amazon.") {
            return extractAmazon(from: html)
        }
        if host.contains("nvidia.com") {
            return extractGeForceNow(from: html, productName: productName, customHints: nil)
        }
        return nil
    }

    // MARK: - Amazon

    private static func extractAmazon(from html: String) -> DetectedPrice? {
        // Buy-box JSON — current "price to pay" on deal pages (not list/was price).
        let jsonPatterns = [
            #""priceToPay"[^}]{0,500}?"amount"\s*:\s*(\d+\.?\d*)"#,
            #""apexPriceToPay"[^}]{0,500}?"amount"\s*:\s*(\d+\.?\d*)"#,
            #""priceAmount"\s*:\s*(\d+\.?\d*)"#,
            #""currencyAmount"\s*:\s*(\d+\.?\d*)"#,
        ]
        for pattern in jsonPatterns {
            if let p = amazonJSONPrice(html, pattern: pattern) {
                return p
            }
        }

        // Visible deal price block (Limited time deal / priceToPay).
        if let deal = amazonPriceToPayBlock(from: html) {
            return deal
        }

        // All a-offscreen prices — skip "Was:" / list / strikethrough, pick best.
        if let offscreen = bestAmazonOffscreenPrice(from: html) {
            return offscreen
        }

        if let combined = bestAmazonWholeFractionPrice(from: html) {
            return combined
        }

        return nil
    }

    /// Whole + fraction inside Amazon's priceToPay / deal container.
    private static func amazonPriceToPayBlock(from html: String) -> DetectedPrice? {
        let pattern =
            #"(?:priceToPay|PriceToPay|limitedTimeDeal|deal_price)[\s\S]{0,600}?a-price-whole">(\d{1,3}(?:,\d{3})*)<[\s\S]{0,120}?a-price-fraction">(\d{2})<"#
        return amazonWholeFractionMatch(html: html, pattern: pattern, source: "amazon-deal")
    }

    private static func bestAmazonWholeFractionPrice(from html: String) -> DetectedPrice? {
        let pattern = #"a-price-whole">(\d{1,3}(?:,\d{3})*)<[\s\S]{0,120}?a-price-fraction">(\d{2})<"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        var best: (DetectedPrice, Int)?
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let price = wholeFractionFromMatch(match, in: html, source: "amazon-whole") else { return }
            let context = amazonContext(before: match.range.location, in: html, length: 320)
            let score = amazonPriceContextScore(context)
            if best == nil || score > best!.1 {
                best = (price, score)
            }
        }
        return best?.0
    }

    private static func amazonWholeFractionMatch(
        html: String,
        pattern: String,
        source: String
    ) -> DetectedPrice? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
            return nil
        }
        return wholeFractionFromMatch(match, in: html, source: source)
    }

    private static func wholeFractionFromMatch(
        _ match: NSTextCheckingResult,
        in html: String,
        source: String
    ) -> DetectedPrice? {
        guard match.numberOfRanges > 2,
              let wholeRange = Range(match.range(at: 1), in: html),
              let fracRange = Range(match.range(at: 2), in: html) else { return nil }

        let whole = String(html[wholeRange]).replacingOccurrences(of: ",", with: "")
        let frac = String(html[fracRange])
        guard let amount = Decimal(string: "\(whole).\(frac)") else { return nil }

        let symbol = html.contains("£") ? "£" : html.contains("€") ? "€" : "$"
        let currency = symbol == "£" ? "GBP" : symbol == "€" ? "EUR" : "USD"
        return DetectedPrice(
            amount: amount,
            currency: currency,
            display: "\(symbol)\(whole).\(frac)",
            source: source
        )
    }

    private static func bestAmazonOffscreenPrice(from html: String) -> DetectedPrice? {
        let pattern = #"class="a-offscreen"[^>]*>\s*([£$€]\s*[\d,]+\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        var best: (DetectedPrice, Int)?
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let priceRange = Range(match.range(at: 1), in: html),
                  let price = priceWithSource(String(html[priceRange]), source: "amazon-offscreen") else { return }

            let context = amazonContext(before: match.range.location, in: html, length: 400)
            let score = amazonPriceContextScore(context)
            if best == nil || score > best!.1 {
                best = (price, score)
            }
        }
        return best?.0
    }

    private static func amazonContext(before location: Int, in html: String, length: Int) -> String {
        let start = max(0, location - length)
        let len = min(length, location - start)
        guard len > 0, let range = Range(NSRange(location: start, length: len), in: html) else {
            return ""
        }
        return String(html[range]).lowercased()
    }

    /// Higher score = more likely the current price (not "Was" / RRP).
    private static func amazonPriceContextScore(_ context: String) -> Int {
        var score = 0
        if context.contains("pricetopay") || context.contains("price_to_pay") { score += 50 }
        if context.contains("limitedtimedeal") || context.contains("limited time deal") { score += 45 }
        if context.contains("dealprice") || context.contains("deal_price") { score += 35 }
        if context.contains("buybox") || context.contains("buy-box") { score += 20 }
        if context.contains("add-to-cart") || context.contains("addtocart") { score += 15 }
        if context.contains("reinventprice") { score += 25 }

        if context.contains("a-text-price") || context.contains("basisprice") {
            score -= 50
        }
        if context.contains("was:") || context.contains(">was<") || context.contains("typical:") { score -= 60 }
        if context.contains("list price") || context.contains("rrp") || context.contains("strikethrough") {
            score -= 40
        }
        if context.contains("saving") && !context.contains("pricetopay") { score -= 10 }
        return score
    }

    private static func amazonJSONPrice(_ html: String, pattern: String) -> DetectedPrice? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: html),
              let amount = Decimal(string: String(html[r])) else { return nil }

        let symbol = html.contains("£") ? "£" : html.contains("€") ? "€" : "$"
        let currency = symbol == "£" ? "GBP" : symbol == "€" ? "EUR" : "USD"
        let display = "\(symbol)\(String(format: "%.2f", NSDecimalNumber(decimal: amount).doubleValue))"
        return DetectedPrice(amount: amount, currency: currency, display: display, source: "amazon-json")
    }

    // MARK: - GeForce NOW

    static func extractGeForceNow(
        from html: String,
        productName: String?,
        customHints: CustomKeywordHints? = nil
    ) -> DetectedPrice? {
        let rawStripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Annual plans first: £99.99/12 months (common on Performance tier).
        let annualPatterns = [
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*12\s*months"#,
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*year"#,
            #"([£$€]\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*/\s*\d+\s*months"#,
            #"data-testid[^"]*price[^"]*"[^>]*>\s*([£$€]\s*[\d,]+\.?\d*)"#,
        ]
        for pattern in annualPatterns {
            if let raw = firstMatch(in: rawStripped, pattern: pattern, group: 1),
               let price = priceWithSource(raw, source: "geforce-annual") {
                return price
            }
        }
        if customHints?.wantsAnnualPlan == true,
           let hintPrice = HintAnchoredPriceExtractor.extract(from: html, hints: customHints!) {
            return hintPrice
        }

        let text = HTMLTextStripper.visibleText(from: html, limit: 20_000)
        let nameLower = productName?.lowercased() ?? ""

        // Prefer tier named in the watch (e.g. "Performance" → price near tier name).
        let tiers = ["ultimate", "priority", "free", "performance", "perfomace", "perfomance"]
        let preferredTier = tiers.first { nameLower.contains($0) }
            ?? tiers.first { text.lowercased().contains($0) }

        if let tier = preferredTier {
            let afterTier = "\(tier)[\\s\\S]{0,140}?([£$€]\\s*\\d+(?:\\.\\d{2})?)"
            if let price = firstMatch(text, pattern: afterTier, group: 1, caseInsensitive: true) {
                return priceWithSource(price, source: "geforce-tier")
            }
            let beforeTier = "([£$€]\\s*\\d+(?:\\.\\d{2})?)[\\s\\S]{0,140}?\(tier)"
            if let price = firstMatch(text, pattern: beforeTier, group: 1, caseInsensitive: true) {
                return priceWithSource(price, source: "geforce-tier")
            }
        }

        // Membership page: price with /month nearby.
        if let price = firstMatch(
            text,
            pattern: #"([£$€]\s*\d+(?:\.\d{2})?)\s*(?:/month|per month|a month)"#
        ) {
            return priceWithSource(price, source: "geforce-monthly")
        }
        if let price = firstMatch(
            text,
            pattern: #"(?:/month|per month|a month)[\s\S]{0,40}?([£$€]\s*\d+(?:\.\d{2})?)"#
        ) {
            return priceWithSource(price, source: "geforce-monthly")
        }

        return nil
    }

    // MARK: - Helpers

    private static func firstMatch(
        _ html: String,
        pattern: String,
        group: Int = 1,
        caseInsensitive: Bool = true
    ) -> String? {
        firstMatch(in: html, pattern: pattern, group: group, caseInsensitive: caseInsensitive)
    }

    private static func firstMatch(
        in text: String,
        pattern: String,
        group: Int = 1,
        caseInsensitive: Bool = true
    ) -> String? {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let r = Range(match.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    private static func priceWithSource(_ raw: String, source: String) -> DetectedPrice? {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"([£$€])([\d,]+\.?\d*)"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let symRange = Range(match.range(at: 1), in: cleaned),
              let amtRange = Range(match.range(at: 2), in: cleaned) else { return nil }

        let symbol = String(cleaned[symRange])
        let amountStr = String(cleaned[amtRange]).replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: amountStr) else { return nil }

        let currency: String
        switch symbol {
        case "£": currency = "GBP"
        case "€": currency = "EUR"
        default: currency = "USD"
        }

        let display: String
        if amountStr.contains(".") {
            display = "\(symbol)\(amountStr)"
        } else {
            display = "\(symbol)\(amountStr).00"
        }

        return DetectedPrice(amount: amount, currency: currency, display: display, source: source)
    }
}
