import Foundation
import SwiftData

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Schedules periodic checks while the app runs and registers iOS background refresh.
enum BackgroundCheckScheduler {
    static let refreshTaskID = "com.deanwass.URLPriceCheck.refresh"

    static func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task {
                await runBackgroundRefresh(task: refresh)
            }
        }
        #endif
    }

    static func scheduleNextRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if os(iOS)
    private static func runBackgroundRefresh(task: BGAppRefreshTask) async {
        scheduleNextRefresh()
        let container = try? ModelContainer(for: WatchedItem.self)
        guard let container else {
            task.setTaskCompleted(success: false)
            return
        }
        let context = ModelContext(container)
        let items = (try? context.fetch(FetchDescriptor<WatchedItem>())) ?? []
        for item in items where item.isDueForCheck {
            await PriceCheckService.shared.check(item: item)
        }
        task.setTaskCompleted(success: true)
    }
    #endif

    /// Foreground timer — reliable on macOS and iOS while app is active.
    @MainActor
    static func startForegroundTimer(context: ModelContext) {
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            Task { @MainActor in
                let items = (try? context.fetch(FetchDescriptor<WatchedItem>())) ?? []
                await PriceCheckService.shared.checkAllDue(context: context, items: items)
            }
        }
    }
}
