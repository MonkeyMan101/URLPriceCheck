import Foundation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AlertKind {
    case checkComplete
    case priceAlert
    case criticalAlert
    case error
}

enum NotificationAuthStatus: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

/// Delivers banners on iOS and macOS, including while the app is in the foreground.
private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
        #elseif os(macOS)
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
        #else
        completionHandler([.alert, .sound])
        #endif
    }
}

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private var isConfigured = false

    private init() {}

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = NotificationCenterDelegate.shared
        registerCategories()
    }

    func authorizationStatus() async -> NotificationAuthStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .denied
        }
    }

    @discardableResult
    func requestPermission() async -> Bool {
        configure()
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if #available(iOS 15.0, macOS 12.0, *) {
            options.insert(.timeSensitive)
        }
        do {
            return try await center.requestAuthorization(options: options)
        } catch {
            return false
        }
    }

    func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    func notify(item: WatchedItem, kind: AlertKind, message: String) async {
        configure()
        let settings = await center.notificationSettings()
        let allowed: Bool = {
            switch settings.authorizationStatus {
            case .authorized, .provisional: return true
            #if os(iOS)
            case .ephemeral: return true
            #endif
            default: return false
            }
        }()
        guard allowed else { return }

        let label = productLabel(for: item)
        let content = UNMutableNotificationContent()
        content.title = title(label: label, kind: kind)
        content.body = bodyMessage(label: label, kind: kind, message: message)
        content.subtitle = subtitle(for: kind)
        content.sound = .default

        if kind == .criticalAlert {
            if #available(iOS 15.0, macOS 12.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            content.categoryIdentifier = "CRITICAL_PRICE"
        }

        let request = UNNotificationRequest(
            identifier: "\(item.id.uuidString)-\(kind)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            // Delivery failed silently — price check still completed.
        }
    }

    private func registerCategories() {
        let critical = UNNotificationCategory(
            identifier: "CRITICAL_PRICE",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([critical])
    }

    /// Short product name for notification title/body (truncated when long).
    private func productLabel(for item: WatchedItem, maxLength: Int = 42) -> String {
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return truncate(trimmed, maxLength: maxLength)
        }
        if let url = item.url {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                let slug = path.split(separator: "/").last.map(String.init) ?? path
                let words = slug
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                if !words.isEmpty {
                    return truncate(words, maxLength: maxLength)
                }
            }
            if let host = url.host?.replacingOccurrences(of: "www.", with: "") {
                return truncate(host, maxLength: maxLength)
            }
        }
        return "Watched item"
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: max(1, maxLength - 1))
        return String(text[..<end]) + "…"
    }

    private func title(label: String, kind: AlertKind) -> String {
        switch kind {
        case .checkComplete:
            return "\(label) — checked"
        case .priceAlert:
            return "Price alert · \(label)"
        case .criticalAlert:
            return "CRITICAL · \(label)"
        case .error:
            return "Check failed · \(label)"
        }
    }

    private func bodyMessage(label: String, kind: AlertKind, message: String) -> String {
        switch kind {
        case .checkComplete, .priceAlert, .criticalAlert:
            return "\(label): \(message)"
        case .error:
            return "\(label) — \(message)"
        }
    }

    private func subtitle(for kind: AlertKind) -> String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        switch kind {
        case .checkComplete:
            return "Finished at \(time)"
        case .priceAlert:
            return "At or below your alert price · \(time)"
        case .criticalAlert:
            return "At or below critical price · \(time)"
        case .error:
            return "Failed at \(time)"
        }
    }
}
