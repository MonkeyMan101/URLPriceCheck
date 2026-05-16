import Foundation
import SwiftData

@Model
final class WatchedItem {
    var id: UUID
    var name: String
    var urlString: String
    var createdAt: Date

    /// Notify when price is at or below this amount.
    var alertPrice: Decimal?
    /// Stronger alert (critical interruption on iOS).
    var criticalPrice: Decimal?

    var lastPrice: Decimal?
    var lastPriceDisplay: String?
    var lastCurrency: String?
    var lastCheckedAt: Date?
    var lastError: String?

    /// How often to check in hours (1–24).
    var checkIntervalHours: Int

    var isEnabled: Bool

    /// Comma-separated words that should appear to the **left** of the price (boost score).
    var keywordsLeft: String?
    /// Comma-separated words that should appear to the **right** of the price.
    var keywordsRight: String?
    /// Comma-separated words to avoid near a price (lower score).
    var keywordsNegative: String?

    init(
        name: String,
        urlString: String,
        alertPrice: Decimal? = nil,
        criticalPrice: Decimal? = nil,
        checkIntervalHours: Int = 6,
        keywordsLeft: String? = nil,
        keywordsRight: String? = nil,
        keywordsNegative: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.urlString = urlString
        self.createdAt = Date()
        self.alertPrice = alertPrice
        self.criticalPrice = criticalPrice
        self.checkIntervalHours = min(24, max(1, checkIntervalHours))
        self.isEnabled = true
        self.keywordsLeft = keywordsLeft
        self.keywordsRight = keywordsRight
        self.keywordsNegative = keywordsNegative
    }

    var url: URL? { URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var isDueForCheck: Bool {
        guard isEnabled else { return false }
        guard let last = lastCheckedAt else { return true }
        let interval = TimeInterval(checkIntervalHours * 3600)
        return Date().timeIntervalSince(last) >= interval
    }
}
