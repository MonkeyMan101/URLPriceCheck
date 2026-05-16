import Foundation

/// Routes price extraction: Xbox keeps the proven path; other stores get smart + AI fallbacks.
enum StorePriceResolver {

    static func isXboxStore(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.contains("xbox.com")
    }

    private static func usesStoreSpecificExtraction(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.contains("amazon.") || host.contains("nvidia.com")
    }

    /// Boutique / one-off retailers (Cult Beauty, etc.) — no bespoke HTML rules; AI + JSON-LD work best.
    private static func isGenericRetailer(_ url: URL?) -> Bool {
        !isXboxStore(url) && !usesStoreSpecificExtraction(url)
    }

    static func bestPrice(
        from html: String,
        pageURL: URL?,
        productName: String?,
        customHints: CustomKeywordHints = .empty
    ) async throws -> DetectedPrice {
        if isXboxStore(pageURL) {
            return try PriceExtractor.bestPrice(from: html)
        }

        let isNVIDIA = pageURL?.host?.lowercased().contains("nvidia.com") == true
        let isGeneric = isGenericRetailer(pageURL)
        let geforceSPA = isNVIDIA && GeForceNOWPaywallPriceFetcher.isJavaScriptProductMatrix(html)

        if !customHints.isEmpty,
           let hinted = HintAnchoredPriceExtractor.extract(from: html, hints: customHints) {
            return hinted
        }

        // Product-matrix pages have no prices in HTML — use NVIDIA's paywall API (same as the website app).
        if isNVIDIA, geforceSPA || !html.contains("£"),
           let apiPrice = await GeForceNOWPaywallPriceFetcher.fetchPrice(
            productName: productName,
            pageURL: pageURL
           ) {
            return apiPrice
        }

        // GeForce NOW: annual £99.99/12 months must win over monthly £12.43.
        if isNVIDIA,
           let annual = GeForceAnnualPriceExtractor.extract(
            from: html,
            productName: productName,
            hints: customHints
           ) {
            return annual
        }

        if isNVIDIA,
           let geforce = StoreHTMLPriceExtractor.extractGeForceNow(
            from: html,
            productName: productName,
            customHints: customHints
           ) {
            return geforce
        }

        if let store = StoreHTMLPriceExtractor.extract(from: html, pageURL: pageURL, productName: productName) {
            return store
        }

        // One-off retailers: schema.org product offer (e.g. Cult Beauty £244) before unrelated £ prices on page.
        if isGeneric, let jsonLD = PriceExtractor.productJSONLDPrice(from: html) {
            return jsonLD
        }

        // Boutique sites: on-device AI finds the hero product price when heuristics would grab "recommended" items.
        if isGeneric,
           let ai = await OnDeviceAIPriceExtractor.extract(
            from: html,
            productName: productName,
            pageURL: pageURL
           ) {
            return ai
        }

        if let smart = SmartPriceFinder.find(
            in: html,
            productName: productName,
            pageURL: pageURL,
            customHints: customHints
        ) {
            return smart
        }

        if !usesStoreSpecificExtraction(pageURL), let structured = try? PriceExtractor.bestPrice(from: html) {
            return structured
        }

        // Last resort for known stores only (never for empty GeForce pages — AI example bug).
        if !isNVIDIA,
           let ai = await OnDeviceAIPriceExtractor.extract(
            from: html,
            productName: productName,
            pageURL: pageURL
           ) {
            return ai
        }

        if geforceSPA {
            throw PriceExtractionError.geforceNOWJavaScriptPage
        }

        throw PriceExtractionError.noPriceFound
    }
}
