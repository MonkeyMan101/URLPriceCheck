import Foundation

/// Fetches GeForce NOW membership prices from NVIDIA's paywall API (same source as the product-matrix React app).
enum GeForceNOWPaywallPriceFetcher {

    private static let serverInfoURL = URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo")!
    private static let productsBaseURL = URL(string: "https://api-prod.nvidia.com/gfn-paywall-api/api/v2/products")!

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Product-matrix pricing is injected by JavaScript (`gfn-home` / `gfn-product-matrix` bundles).
    static func isJavaScriptProductMatrix(_ html: String) -> Bool {
        html.contains("gfn-home-root")
            || html.contains("gfn-product-matrix")
            || html.contains("/assets/gfn-home/bundle.js")
            || (html.contains("id=\"product-matrix\"") && html.contains("gfn-home"))
    }

    static func fetchPrice(productName: String?, pageURL: URL?) async -> DetectedPrice? {
        guard let serverId = try? await fetchServerId() else { return nil }
        let locale = paywallLocale(from: pageURL)
        guard let products = try? await fetchProducts(locale: locale, vpcId: serverId) else { return nil }
        return pickPrice(from: products, productName: productName, locale: locale)
    }

    // MARK: - API

    private static func fetchServerId() async throws -> String {
        var request = URLRequest(url: serverInfoURL, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["requestStatus"] as? [String: Any],
              let serverId = status["serverId"] as? String, !serverId.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return serverId
    }

    private static func fetchProducts(locale: String, vpcId: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: productsBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "locale", value: locale),
            URLQueryItem(name: "vpcId", value: vpcId),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.nvidia.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.nvidia.com/en-gb/geforce-now/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if (json["status"] as? String)?.lowercased() == "failure" {
            throw URLError(.cannotLoadFromNetwork)
        }
        return extractProductDictionaries(from: json)
    }

    private static func extractProductDictionaries(from json: [String: Any]) -> [[String: Any]] {
        if let list = json["products"] as? [[String: Any]] { return list }
        if let list = json["data"] as? [[String: Any]] { return list }
        if let data = json["data"] as? [String: Any], let list = data["products"] as? [[String: Any]] {
            return list
        }
        return []
    }

    // MARK: - Product selection

    private static func pickPrice(
        from products: [[String: Any]],
        productName: String?,
        locale: String
    ) -> DetectedPrice? {
        guard !products.isEmpty else { return nil }

        let nameHint = productName?.lowercased() ?? ""
        let tierHints = ["performance", "ultimate", "priority", "free", "perfomace", "perfomance"]
        let preferredTier = tierHints.first { nameHint.contains($0) }
            ?? tierHints.first { tier in
                products.contains { productTier($0)?.lowercased().contains(tier) == true }
            }

        let yearly = products.filter { isYearlyRecurrence($0) }
        let pool = yearly.isEmpty ? products : yearly

        let candidates: [[String: Any]]
        if let tier = preferredTier {
            let matched = pool.filter { productMatchesTier($0, tier: tier) }
            candidates = matched.isEmpty ? pool : matched
        } else {
            candidates = pool
        }

        let ranked = candidates.compactMap { (product: [String: Any]) -> (DetectedPrice, Int)? in
            guard let price = priceFromProduct(product, locale: locale) else { return nil }
            var score = 0
            if isYearlyRecurrence(product) { score += 50 }
            if price.amount >= 50 { score += 30 }
            if price.amount >= 25 { score += 10 }
            if price.amount < 20 { score -= 40 }
            if let tier = preferredTier, productMatchesTier(product, tier: tier) { score += 40 }
            return (price, score)
        }

        return ranked.max(by: { $0.1 < $1.1 })?.0
    }

    private static func productMatchesTier(_ product: [String: Any], tier: String) -> Bool {
        let haystack = [
            productTier(product),
            product["displayName"] as? String,
            product["name"] as? String,
            product["productType"] as? String,
            product["subType"] as? String,
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains(tier)
    }

    private static func productTier(_ product: [String: Any]) -> String? {
        product["membershipTier"] as? String ?? product["productType"] as? String
    }

    private static func isYearlyRecurrence(_ product: [String: Any]) -> Bool {
        let r = (product["recurrence"] as? String)?.uppercased() ?? ""
        return r == "YEARLY" || r.contains("YEAR")
    }

    private static func priceFromProduct(_ product: [String: Any], locale: String) -> DetectedPrice? {
        let keys = ["finalDiscountedPrice", "productPrice", "price", "amount"]
        for key in keys {
            if let amount = decimal(from: product[key]), amount > 0 {
                return makePrice(amount: amount, currency: currencyCode(for: locale), locale: locale)
            }
        }
        return nil
    }

    private static func decimal(from value: Any?) -> Decimal? {
        switch value {
        case let n as NSNumber: return Decimal(string: n.stringValue)
        case let d as Double: return Decimal(d)
        case let i as Int: return Decimal(i)
        case let s as String: return Decimal(string: s.replacingOccurrences(of: ",", with: ""))
        case let dict as [String: Any]:
            return decimal(from: dict["amount"]) ?? decimal(from: dict["value"])
        default: return nil
        }
    }

    private static func makePrice(amount: Decimal, currency: String, locale: String) -> DetectedPrice {
        let symbol = currency == "GBP" ? "£" : currency == "EUR" ? "€" : "$"
        let formatted = String(format: "%.2f", NSDecimalNumber(decimal: amount).doubleValue)
        return DetectedPrice(
            amount: amount,
            currency: currency,
            display: "\(symbol)\(formatted)",
            source: "geforce-paywall-api"
        )
    }

    private static func currencyCode(for locale: String) -> String {
        if locale.hasSuffix("_GB") || locale.contains("GB") { return "GBP" }
        if locale.hasSuffix("_EU") || locale.contains("IE") { return "EUR" }
        return "USD"
    }

    /// Maps `/en-gb/` path segments to paywall `locale` (e.g. `en_GB`), matching NVIDIA's site config.
    static func paywallLocale(from pageURL: URL?) -> String {
        for segment in pageURL?.path.lowercased().split(separator: "/") ?? [] {
            let parts = segment.split(separator: "-")
            if parts.count == 2, parts[0].count == 2, parts[1].count == 2 {
                return "\(parts[0])_\(parts[1].uppercased())"
            }
        }
        return "en_GB"
    }
}
