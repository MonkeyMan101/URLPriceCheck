import Foundation

/// Keywords and hints for scoring prices by nearby text (left / right of the match).
struct StoreKeywordProfile {
    let id: String
    /// Substring matched against URL host (e.g. `amazon.`).
    let hostContains: String

    /// Strong signals anywhere in the context window.
    let positiveAnywhere: [String]
    /// Extra score when text appears to the **left** of the price.
    let positiveLeft: [String]
    /// Extra score when text appears to the **right** of the price.
    let positiveRight: [String]
    /// Penalise matches near these phrases (subscriptions, unrelated products, etc.).
    let negativeAnywhere: [String]

    /// If the watch name contains one of these tokens, boost prices near the same word.
    let tierNameHints: [String]

    static let generic = StoreKeywordProfile(
        id: "generic",
        hostContains: "",
        positiveAnywhere: [
            "add to cart", "add to basket", "buy now", "purchase", "current price",
            "sale price", "your price", "now", "only", "price", "was", "save",
            "discount", "offer", "in stock",
        ],
        positiveLeft: ["price:", "now", "sale", "deal", "only"],
        positiveRight: ["inc.", "vat", "incl", "delivery", "shipping", "buy", "cart", "basket"],
        negativeAnywhere: [
            "per month", "/month", "/mo", "monthly", "subscription", "renew",
            "from other", "you may also", "customers also", "sponsored", "advertisement",
            "starting at", "from £", "from $",
        ],
        tierNameHints: []
    )

    static let amazon = StoreKeywordProfile(
        id: "amazon",
        hostContains: "amazon.",
        positiveAnywhere: [
            "add to basket", "add to cart", "buy now", "one-time purchase",
            "purchase price", "deal price", "deal of the day", "limited time deal",
            "price to pay", "save", "in stock", "dispatch from",
            "sold by amazon", "amazon.co.uk", "free delivery", "prime",
        ],
        positiveLeft: [
            "price", "deal", "offer", "pay", "cost", "now", "limited time",
        ],
        positiveRight: [
            "delivery", "dispatch", "in stock", "basket", "cart", "coupon",
            "with prime", "vat", "per unit", "each",
        ],
        negativeAnywhere: [
            "was:", "was ", "list price", "rrp", "typical:", "typical price",
            "strikethrough", "a-text-price", "basisprice",
            "from other sellers", "other sellers", "used from", "pre-owned",
            "subscribe & save", "subscribe and save", "subscription", "per month",
            "/month", "monthly", "kindle unlimited", "audible", "renewal",
            "collect from", "pickup", "trade-in", "sponsored", "compare with similar",
            "frequently bought together", "customers who bought",
        ],
        tierNameHints: []
    )

    static let geforceNow = StoreKeywordProfile(
        id: "geforce",
        hostContains: "nvidia.com",
        positiveAnywhere: [
            "geforce now", "membership", "memberships", "plan", "tier",
            "per month", "/month", "monthly", "billed monthly", "billed annually",
            "annual", "yearly", "subscribe", "upgrade", "free", "priority", "ultimate",
            "performance", "rtx", "cloud gaming",
        ],
        positiveLeft: [
            "plan", "tier", "membership", "ultimate", "priority", "free",
            "starting at", "from", "only", "price",
        ],
        positiveRight: [
            "/month", "per month", "monthly", "a month", "billed", "subscription",
            "12 months", "12 month", "/year", "per year", "annual", "yearly",
            "cancel anytime", "vat", "inc.",
        ],
        negativeAnywhere: [
            "graphics card", "gpu", "geforce rtx", "founders edition", "driver",
            "download driver", "game ready", "hardware", "laptop", "monitor",
            "shield", "omniverse", "workstation", "data center",
        ],
        tierNameHints: ["ultimate", "priority", "free", "performance"]
    )

    /// Fallback for Cult Beauty and other sites without bespoke extractors.
    static let genericRetailer = StoreKeywordProfile(
        id: "generic-retailer",
        hostContains: "",
        positiveAnywhere: [
            "add to bag", "add to basket", "add to cart", "buy now", "purchase",
            "one size", "in stock", "delivery", "free delivery", "pay now",
            "price", "total", "checkout",
        ],
        positiveLeft: ["price", "now", "only", "sale", "offer"],
        positiveRight: [
            "add to bag", "add to basket", "add to cart", "in stock",
            "delivery", "vat", "inc", "each", "per",
        ],
        negativeAnywhere: [
            "you may also", "recommended", "similar products", "frequently bought",
            "sponsored", "from ", "starting at", "gift card", "samples from",
            "spend ", "free gift when you spend", "subscribe",
        ],
        tierNameHints: []
    )

    static let all: [StoreKeywordProfile] = [amazon, geforceNow]

    static func profile(for url: URL?) -> StoreKeywordProfile? {
        guard let host = url?.host?.lowercased() else { return nil }
        if let known = all.first(where: { host.contains($0.hostContains) && !$0.hostContains.isEmpty }) {
            return known
        }
        let isKnownStore = host.contains("xbox.com") || host.contains("amazon.") || host.contains("nvidia.com")
        return isKnownStore ? nil : genericRetailer
    }
}
