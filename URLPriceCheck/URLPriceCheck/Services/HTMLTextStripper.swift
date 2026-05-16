import Foundation

/// Pulls readable text out of HTML for smart / AI price detection.
enum HTMLTextStripper {

    static func visibleText(from html: String, limit: Int = 12_000) -> String {
        var text = html
        let patterns = [
            #"<script[\s\S]*?</script>"#,
            #"<style[\s\S]*?</style>"#,
            #"<noscript[\s\S]*?</noscript>"#,
            #"<!--[\s\S]*?-->"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#163;", with: "£")
            .replacingOccurrences(of: "&pound;", with: "£")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

// MARK: - AI page context

/// Builds a focused text bundle for on-device AI on boutique / one-off retailer pages.
enum ProductPageContext {

    static func build(html: String, productName: String?, pageURL: URL?) -> String {
        var sections: [String] = []

        if let structured = PriceExtractor.productJSONLDPrice(from: html) {
            sections.append("Structured product price (schema.org): \(structured.display) (\(structured.currency))")
        }

        for snippet in jsonLDOfferSnippets(from: html).prefix(3) {
            sections.append("JSON-LD offer: \(snippet)")
        }

        if let name = productName, !name.isEmpty {
            sections.append("Product to price: \(name)")
            if let window = textWindow(around: name, in: html, radius: 2_500) {
                sections.append("Text near product name:\n\(window)")
            }
        }

        if let url = pageURL?.absoluteString {
            sections.append("Page URL: \(url)")
        }

        let visible = HTMLTextStripper.visibleText(from: html, limit: 10_000)
        sections.append("Page text:\n\(visible)")

        let combined = sections.joined(separator: "\n\n")
        if combined.count <= 14_000 { return combined }
        return String(combined.prefix(14_000))
    }

    private static func jsonLDOfferSnippets(from html: String) -> [String] {
        let pattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }

        var snippets: [String] = []
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: html) else { return }
            let jsonText = String(html[jsonRange])
            guard jsonText.localizedCaseInsensitiveContains("product"),
                  jsonText.localizedCaseInsensitiveContains("price") else { return }
            let compact = jsonText
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            snippets.append(String(compact.prefix(600)))
        }
        return snippets
    }

    private static func textWindow(around needle: String, in html: String, radius: Int) -> String? {
        let visible = HTMLTextStripper.visibleText(from: html, limit: 80_000)
        guard let range = visible.range(of: needle, options: .caseInsensitive) else { return nil }
        let start = visible.index(range.lowerBound, offsetBy: -radius, limitedBy: visible.startIndex) ?? visible.startIndex
        let end = visible.index(range.upperBound, offsetBy: radius, limitedBy: visible.endIndex) ?? visible.endIndex
        return String(visible[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
