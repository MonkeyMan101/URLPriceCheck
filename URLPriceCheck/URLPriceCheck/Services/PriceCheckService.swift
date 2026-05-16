import Foundation
import SwiftData

@MainActor
final class PriceCheckService {
    static let shared = PriceCheckService()

    private init() {}

    func check(item: WatchedItem, notifyOnComplete: Bool = true) async {
        guard let url = item.url else {
            item.lastError = "Invalid URL"
            await NotificationManager.shared.notify(
                item: item,
                kind: .error,
                message: "Invalid URL"
            )
            return
        }

        do {
            let html = try await PageFetcher.fetchHTML(url: url)
            let productName = await ProductNameResolver.resolve(
                html: html,
                pageURL: url,
                existingName: item.name
            ) ?? item.name
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                item.name = productName
            }
            let price = try await StorePriceResolver.bestPrice(
                from: html,
                pageURL: url,
                productName: productName,
                customHints: CustomKeywordHints.from(item: item)
            )
            item.lastPrice = price.amount
            item.lastPriceDisplay = price.display
            item.lastCurrency = price.currency
            item.lastCheckedAt = Date()
            item.lastError = nil

            if notifyOnComplete {
                await evaluateAlerts(item: item, price: price)
            }
        } catch {
            item.lastPrice = nil
            item.lastPriceDisplay = nil
            item.lastCurrency = nil
            item.lastError = error.localizedDescription
            item.lastCheckedAt = Date()
            await NotificationManager.shared.notify(
                item: item,
                kind: .error,
                message: error.localizedDescription
            )
        }
    }

    func checkAllDue(context: ModelContext, items: [WatchedItem]) async {
        for item in items where item.isDueForCheck {
            await check(item: item)
        }
    }

    private func evaluateAlerts(item: WatchedItem, price: DetectedPrice) async {
        let msg = "Current price: \(price.display)"

        if let critical = item.criticalPrice, price.amount <= critical {
            await NotificationManager.shared.notify(
                item: item,
                kind: .criticalAlert,
                message: "\(msg) — at or below critical \(format(critical))!"
            )
            return
        }

        if let alert = item.alertPrice, price.amount <= alert {
            await NotificationManager.shared.notify(
                item: item,
                kind: .priceAlert,
                message: "\(msg) — at or below your alert \(format(alert))."
            )
            return
        }

        await NotificationManager.shared.notify(
            item: item,
            kind: .checkComplete,
            message: msg
        )
    }

    private func format(_ value: Decimal) -> String {
        let n = NSDecimalNumber(decimal: value)
        return String(format: "%.2f", n.doubleValue)
    }
}
