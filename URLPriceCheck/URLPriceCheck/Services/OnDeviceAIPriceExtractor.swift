import Foundation

/// Uses Apple on-device intelligence to read the main product title from a page.
enum OnDeviceAIProductNameExtractor {

    static func extract(from html: String, pageURL: URL?) async -> String? {
        let context = ProductPageContext.build(html: html, productName: nil, pageURL: pageURL)
        guard context.count > 80 else { return nil }

        if #available(macOS 26.0, iOS 26.0, *) {
            return await AppleIntelligenceProductNameExtractor.extract(
                pageContext: context,
                pageURL: pageURL
            )
        }
        return nil
    }
}

/// Uses Apple on-device intelligence when available; otherwise returns nil.
enum OnDeviceAIPriceExtractor {

    static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return true
        }
        return false
    }

    static func extract(from html: String, productName: String?, pageURL: URL?) async -> DetectedPrice? {
        let context = ProductPageContext.build(html: html, productName: productName, pageURL: pageURL)
        guard context.count > 80 else { return nil }

        if #available(macOS 26.0, iOS 26.0, *) {
            return await AppleIntelligencePriceExtractor.extract(
                pageContext: context,
                productName: productName,
                pageURL: pageURL
            )
        }
        return nil
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
private enum AppleIntelligenceProductNameExtractor {

    static func extract(pageContext: String, pageURL: URL?) async -> String? {
        let host = pageURL?.host ?? "unknown"
        let prompt = """
        Extract the full product title for the MAIN product sold on this e-commerce page.
        Store: \(host)

        Rules:
        - Return only the product name (not the store name, category breadcrumbs, or "add to bag").
        - Ignore "you may also like", recommended products, and navigation.
        - Use the real title from the page context; do not invent a name.

        \(pageContext)

        Reply with ONLY one line of JSON:
        {"name":"<product title>"}
        If unknown: {"name":""}
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return parseNameJSON(from: response.content)
        } catch {
            return nil
        }
    }

    private static func parseNameJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              let data = String(text[start ... end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 200 else { return nil }
        return trimmed
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum AppleIntelligencePriceExtractor {

    static func extract(pageContext: String, productName: String?, pageURL: URL?) async -> DetectedPrice? {
        let host = pageURL?.host ?? "unknown"
        let name = productName ?? "the main product on this page"
        let prompt = """
        You are extracting the single current purchase price for ONE product on an e-commerce page.
        Store: \(host)
        Product: \(name)

        Rules:
        - Return the price the customer pays for "\(name)" (or the main hero product if the name is vague).
        - Ignore recommended products, "you may also like", samples, gift cards, shipping thresholds, and loyalty perks.
        - Prefer structured JSON-LD / "price to pay" / "add to bag" amounts over stray numbers in the page.
        - Use the real price from the context below; do not invent values.

        \(pageContext)

        Reply with ONLY one line of JSON:
        {"amount":<number>,"currency":"<ISO code>","display":"<formatted price>"}
        If no price can be determined:
        {"amount":0,"currency":"","display":""}
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return parseJSON(from: response.content)
        } catch {
            return nil
        }
    }

    private static func parseJSON(from text: String) -> DetectedPrice? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              let data = String(text[start ... end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let amount = decimal(from: obj["amount"]),
              amount > 0,
              let display = obj["display"] as? String, !display.isEmpty else { return nil }

        let currency = (obj["currency"] as? String) ?? "GBP"
        return DetectedPrice(amount: amount, currency: currency, display: display, source: "ai")
    }

    private static func decimal(from value: Any?) -> Decimal? {
        switch value {
        case let n as NSNumber: return Decimal(string: n.stringValue)
        case let s as String: return Decimal(string: s)
        case let d as Double: return Decimal(d)
        default: return nil
        }
    }
}
#endif

// MARK: - Product name resolution

/// Resolves a display name for a watched product from page HTML when the user leaves Name blank.
enum ProductNameResolver {

    static func resolve(
        html: String,
        pageURL: URL?,
        existingName: String?
    ) async -> String? {
        let trimmed = existingName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }

        if let jsonLD = PriceExtractor.productJSONLDName(from: html) {
            return jsonLD
        }
        if let meta = metaProductName(from: html) {
            return meta
        }
        if let heading = firstProductHeading(from: html) {
            return heading
        }
        if let ai = await OnDeviceAIProductNameExtractor.extract(from: html, pageURL: pageURL) {
            return ai
        }
        return fallbackName(from: pageURL)
    }

    private static func metaProductName(from html: String) -> String? {
        let patterns = [
            #"property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
            #"content=["']([^"']+)["'][^>]*property=["']og:title["']"#,
            #"name=["']twitter:title["'][^>]*content=["']([^"']+)["']"#,
            #"<title[^>]*>([^<]+)</title>"#,
        ]
        for pattern in patterns {
            if let raw = firstCapture(in: html, pattern: pattern) {
                if let cleaned = cleanTitle(raw, pageURL: nil) { return cleaned }
            }
        }
        return nil
    }

    private static func firstProductHeading(from html: String) -> String? {
        let pattern = #"<h1[^>]*>([\s\S]*?)</h1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        var found: String?
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { return }
            let inner = String(html[r])
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned = cleanTitle(inner, pageURL: nil), cleaned.count >= 3 {
                found = cleaned
                stop.pointee = true
            }
        }
        return found
    }

    private static func cleanTitle(_ raw: String, pageURL: URL?) -> String? {
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" | ", " – ", " — ", " - "]
        if let host = pageURL?.host?.replacingOccurrences(of: "www.", with: "") {
            for sep in separators {
                if let range = text.range(of: sep + host, options: .caseInsensitive) {
                    text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        for sep in separators {
            if let range = text.range(of: sep, options: .backwards) {
                let tail = String(text[range.upperBound...])
                if tail.count < 30, tail.localizedCaseInsensitiveContains("shop")
                    || tail.localizedCaseInsensitiveContains("beauty")
                    || tail.localizedCaseInsensitiveContains("store") {
                    text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard text.count >= 3, text.count <= 200 else { return nil }
        return text
    }

    private static func fallbackName(from pageURL: URL?) -> String? {
        guard let url = pageURL else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segment = path.split(separator: "/").last.map(String.init) ?? ""
        let words = segment
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard words.count >= 3 else {
            return pageURL?.host?.replacingOccurrences(of: "www.", with: "")
        }
        return words.split(separator: " ")
            .map { word in
                let w = String(word)
                return w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
