import Foundation
import SwiftData

@MainActor
final class PriceCheckService {
    static let shared = PriceCheckService()

    /// Avoid overlapping checks for the same watch (e.g. two timers or timer + manual); `await` can interleave on MainActor.
    private var checkingItemIDs = Set<UUID>()

    private init() {}

    func check(
        item: WatchedItem,
        notifyOnComplete: Bool = true,
        omitRoutineCheckComplete: Bool = false
    ) async {
        guard !checkingItemIDs.contains(item.id) else { return }
        checkingItemIDs.insert(item.id)
        defer { checkingItemIDs.remove(item.id) }

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
                await evaluateAlerts(item: item, price: price, omitRoutineCheckComplete: omitRoutineCheckComplete)
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
        let due = items.filter(\.isDueForCheck)
        guard !due.isEmpty else { return }
        let batch = due.count > 1
        for item in due {
            await check(item: item, notifyOnComplete: true, omitRoutineCheckComplete: batch)
        }
        if batch {
            await postBatchRoutineCheckCompleteIfNeeded(items: due)
        }
    }

    /// Manual "Check all" — same batching as scheduled checks so many watches do not flood notifications at once.
    func checkAllEnabled(context: ModelContext, items: [WatchedItem]) async {
        let enabled = items.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        let batch = enabled.count > 1
        for item in enabled {
            await check(item: item, notifyOnComplete: true, omitRoutineCheckComplete: batch)
        }
        if batch {
            await postBatchRoutineCheckCompleteIfNeeded(items: enabled)
        }
    }

    /// Items that did not already get a price/critical notification; combine their "checked OK" into one banner.
    private func postBatchRoutineCheckCompleteIfNeeded(items: [WatchedItem]) async {
        let routine = items.filter { item in
            guard let price = item.lastPrice, item.lastError == nil else { return false }
            if let c = item.criticalPrice, price <= c { return false }
            if let a = item.alertPrice, price <= a { return false }
            return true
        }
        guard routine.count >= 1 else { return }
        await NotificationManager.shared.notifyCheckBatchSummary(items: routine)
    }

    private func evaluateAlerts(item: WatchedItem, price: DetectedPrice, omitRoutineCheckComplete: Bool) async {
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

        if omitRoutineCheckComplete { return }

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
