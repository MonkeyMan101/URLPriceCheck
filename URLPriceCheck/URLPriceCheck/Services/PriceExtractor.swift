import Foundation

/// Finds prices in HTML using structured data first, then common patterns.
enum PriceExtractor {

    static func extract(from html: String) -> [DetectedPrice] {
        var found: [DetectedPrice] = []
        found.append(contentsOf: extractJSONLD(from: html))
        found.append(contentsOf: extractEmbeddedStoreJSON(from: html))
        found.append(contentsOf: extractMetaTags(from: html))
        found.append(contentsOf: extractRegex(from: html))
        return dedupe(found)
    }

    /// Picks the price the same way the Python checker does: first visible ``£12.34`` on the page,
    /// not the cheapest ``£4.79`` from unrelated “recommended” products (old logic used ``min()``).
    /// Main product offer from schema.org JSON-LD (ignores unrelated £ prices elsewhere on the page).
    static func productJSONLDPrice(from html: String) -> DetectedPrice? {
        extractProductJSONLDPrice(from: html)
    }

    /// Product title from schema.org JSON-LD on the main Product node.
    static func productJSONLDName(from html: String) -> String? {
        extractProductJSONLDName(from: html)
    }

    static func bestPrice(from html: String) throws -> DetectedPrice {
        if let product = extractProductJSONLDPrice(from: html) {
            return product
        }
        if let display = extractFirstDisplayPrice(from: html) {
            return display
        }
        if let embedded = extractEmbeddedStoreJSON(from: html).first {
            return embedded
        }
        let meta = extractMetaTags(from: html)
        if let first = meta.first {
            return first
        }
        throw PriceExtractionError.noPriceFound
    }

    // MARK: - Python-style first visible price

    /// Matches ``re.findall(r'£\d+\.\d{2}', html)[0]`` — first £ price in document order.
    private static func extractFirstDisplayPrice(from html: String) -> DetectedPrice? {
        let patterns: [(String, String, String)] = [
            (#"£(\d+\.\d{2})"#, "GBP", "£"),
            (#"\$(\d+\.\d{2})"#, "USD", "$"),
            (#"€(\d+\.\d{2})"#, "EUR", "€"),
        ]

        var best: (index: Int, price: DetectedPrice)?

        for (pattern, currency, symbol) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let amountRange = Range(match.range(at: 1), in: html),
                  let amount = parseAmount(String(html[amountRange])) else { continue }

            let display = "\(symbol)\(String(html[amountRange]))"
            let price = DetectedPrice(
                amount: amount,
                currency: currency,
                display: display,
                source: "display"
            )
            let index = match.range.location
            if best == nil || index < best!.index {
                best = (index, price)
            }
        }

        return best?.price
    }

    /// JSON-LD on the main Product / VideoGame node only.
    private static func extractProductJSONLDPrice(from html: String) -> DetectedPrice? {
        forEachProductJSONLD(in: html) { json in
            if let price = productOfferFromJSON(json) { return price }
            return nil
        }
    }

    private static func extractProductJSONLDName(from html: String) -> String? {
        forEachProductJSONLD(in: html) { json in
            if let name = productNameFromJSON(json) { return name }
            return nil
        }
    }

    private static func forEachProductJSONLD<T>(in html: String, _ body: (Any) -> T?) -> T? {
        let pattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        var found: T?
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: html),
                  let data = String(html[jsonRange]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return }
            if let result = body(json) {
                found = result
                stop.pointee = true
            }
        }
        return found
    }

    private static func productNameFromJSON(_ json: Any) -> String? {
        if let dict = json as? [String: Any], let graph = dict["@graph"] as? [Any] {
            for node in graph {
                guard let obj = node as? [String: Any], isProductLike(obj) else { continue }
                if let name = cleanedProductName(obj["name"]) { return name }
            }
        }
        if let dict = json as? [String: Any], isProductLike(dict) {
            return cleanedProductName(dict["name"])
        }
        return nil
    }

    private static func cleanedProductName(_ value: Any?) -> String? {
        let raw: String?
        switch value {
        case let s as String: raw = s
        case let arr as [String]: raw = arr.first
        case let arr as [Any]: raw = arr.first as? String
        default: raw = nil
        }
        guard let raw else { return nil }
        let text = raw
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= 200 else { return nil }
        return text
    }

    private static func productOfferFromJSON(_ json: Any) -> DetectedPrice? {
        if let dict = json as? [String: Any], let graph = dict["@graph"] as? [Any] {
            for node in graph {
                guard let obj = node as? [String: Any], isProductLike(obj),
                      let offers = obj["offers"] else { continue }
                let offerPrices = pricesFromOffers(offers)
                if let first = offerPrices.first {
                    return first
                }
            }
        }
        if let dict = json as? [String: Any], isProductLike(dict), let offers = dict["offers"] {
            return pricesFromOffers(offers).first
        }
        return nil
    }

    // MARK: - JSON-LD (schema.org Product)

    private static func extractJSONLD(from html: String) -> [DetectedPrice] {
        let pattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var results: [DetectedPrice] = []

        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: html) else { return }
            let jsonText = String(html[jsonRange])
            guard let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return }
            results.append(contentsOf: pricesFromJSON(json))
        }
        return results
    }

    private static func pricesFromJSON(_ json: Any) -> [DetectedPrice] {
        if let dict = json as? [String: Any] {
            return pricesFromObject(dict)
        }
        if let array = json as? [[String: Any]] {
            return array.flatMap { pricesFromObject($0) }
        }
        if let array = json as? [Any] {
            return array.flatMap { pricesFromJSON($0) }
        }
        return []
    }

    private static func pricesFromObject(_ obj: [String: Any]) -> [DetectedPrice] {
        var results: [DetectedPrice] = []

        if isProductLike(obj), let offers = obj["offers"] {
            results.append(contentsOf: pricesFromOffers(offers))
        }

        if let graph = obj["@graph"] as? [Any] {
            results.append(contentsOf: graph.flatMap { pricesFromJSON($0) })
        }

        for (_, value) in obj where value is [String: Any] || value is [Any] {
            results.append(contentsOf: pricesFromJSON(value))
        }

        return results
    }

    private static func isProductLike(_ obj: [String: Any]) -> Bool {
        schemaTypes(obj).contains { $0.contains("Product") || $0 == "VideoGame" }
    }

    /// `@type` may be a string or array (e.g. Xbox uses `["Product","VideoGame"]`).
    private static func schemaTypes(_ obj: [String: Any]) -> [String] {
        if let single = obj["@type"] as? String { return [single] }
        if let array = obj["@type"] as? [String] { return array }
        if let array = obj["@type"] as? [Any] {
            return array.compactMap { $0 as? String }
        }
        return []
    }

    private static func pricesFromOffers(_ offers: Any) -> [DetectedPrice] {
        if let dict = offers as? [String: Any] {
            return priceFromOfferDict(dict).map { [$0] } ?? []
        }
        if let array = offers as? [[String: Any]] {
            return array.compactMap { priceFromOfferDict($0) }
        }
        if let array = offers as? [Any] {
            return array.compactMap { item -> DetectedPrice? in
                guard let d = item as? [String: Any] else { return nil }
                return priceFromOfferDict(d)
            }
        }
        return []
    }

    private static func priceFromOfferDict(_ dict: [String: Any]) -> DetectedPrice? {
        let currency = (dict["priceCurrency"] as? String) ?? "GBP"
        if let amount = decimalFrom(dict["price"]) {
            return make(amount: amount, currency: currency, source: "json-ld")
        }
        if let low = dict["lowPrice"] as? String, let amount = parseAmount(low) {
            return make(amount: amount, currency: currency, source: "json-ld")
        }
        if let amount = decimalFrom(dict["lowPrice"]) {
            return make(amount: amount, currency: currency, source: "json-ld")
        }
        return nil
    }

    // MARK: - Xbox / Microsoft store embedded JSON

    private static func extractEmbeddedStoreJSON(from html: String) -> [DetectedPrice] {
        let patterns: [(String, String)] = [
            (#""listPrice"\s*:\s*(\d+(?:\.\d+)?)\s*,\s*"msrp"\s*:\s*\d+(?:\.\d+)?\s*,\s*"currency"\s*:\s*"([A-Z]{3})""#, "listPrice"),
            (#""msrp"\s*:\s*(\d+(?:\.\d+)?)\s*,\s*"currency"\s*:\s*"([A-Z]{3})""#, "msrp"),
            (#""finalPrice"\s*:\s*(\d+(?:\.\d+)?)\s*,\s*"currency"\s*:\s*"([A-Z]{3})""#, "finalPrice"),
            (#""price"\s*:\s*(\d+(?:\.\d+)?)\s*,\s*"priceCurrency"\s*:\s*"([A-Z]{3})""#, "price"),
        ]
        var results: [DetectedPrice] = []
        for (pattern, source) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 2,
                      let amountRange = Range(match.range(at: 1), in: html),
                      let currencyRange = Range(match.range(at: 2), in: html),
                      let amount = parseAmount(String(html[amountRange])) else { return }
                let currency = String(html[currencyRange])
                results.append(make(amount: amount, currency: currency, source: source))
            }
        }
        return results
    }

    // MARK: - Meta tags

    private static func extractMetaTags(from html: String) -> [DetectedPrice] {
        let patterns: [(String, String)] = [
            (#"property=["']product:price:amount["'][^>]*content=["']([^"']+)["']"#, "GBP"),
            (#"property=["']og:price:amount["'][^>]*content=["']([^"']+)["']"#, "GBP"),
            (#"itemprop=["']price["'][^>]*content=["']([^"']+)["']"#, "GBP"),
            (#"name=["']twitter:data1["'][^>]*content=["']([^"']+)["']"#, "GBP"),
        ]
        var results: [DetectedPrice] = []
        for (pattern, defaultCurrency) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: html),
                      let amount = parseAmount(String(html[r])) else { return }
                results.append(make(amount: amount, currency: defaultCurrency, source: "meta"))
            }
        }
        return results
    }

    // MARK: - Regex (currency symbols)

    private static func extractRegex(from html: String) -> [DetectedPrice] {
        if let first = extractFirstDisplayPrice(from: html) {
            return [first]
        }
        let patterns: [(String, String)] = [
            (#"[£\u00a3&#163;]\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "GBP"),
            (#"£\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "GBP"),
            (#"\$\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "USD"),
            (#"€\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#, "EUR"),
            (#"(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*GBP"#, "GBP"),
            (#"(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*USD"#, "USD"),
        ]
        var results: [DetectedPrice] = []
        for (pattern, currency) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: html),
                      let amount = parseAmount(String(html[r])) else { return }
                let symbol = currency == "GBP" ? "£" : currency == "USD" ? "$" : "€"
                let display = "\(symbol)\(formatAmount(amount))"
                results.append(DetectedPrice(amount: amount, currency: currency, display: display, source: "regex"))
            }
        }
        return results
    }

    // MARK: - Helpers

    private static func make(amount: Decimal, currency: String, source: String) -> DetectedPrice {
        let symbol: String
        switch currency.uppercased() {
        case "GBP": symbol = "£"
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        default: symbol = currency + " "
        }
        let display = symbol + formatAmount(amount)
        return DetectedPrice(amount: amount, currency: currency.uppercased(), display: display, source: source)
    }

    private static func decimalFrom(_ value: Any?) -> Decimal? {
        switch value {
        case let n as NSNumber:
            return Decimal(string: n.stringValue)
        case let s as String:
            return parseAmount(s)
        case let d as Double:
            return Decimal(d)
        case let i as Int:
            return Decimal(i)
        default:
            return nil
        }
    }

    private static func parseAmount(_ raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned)
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let n = NSDecimalNumber(decimal: amount)
        return String(format: "%.2f", n.doubleValue)
    }

    private static func dedupe(_ prices: [DetectedPrice]) -> [DetectedPrice] {
        var seen = Set<String>()
        return prices.filter { p in
            let key = "\(p.currency)-\(p.amount)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return p.amount > 0
        }
    }
}
