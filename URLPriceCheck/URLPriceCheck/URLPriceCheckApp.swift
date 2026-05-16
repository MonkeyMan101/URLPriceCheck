import SwiftUI
import SwiftData
import Foundation
import Observation

#if os(iOS)
import UIKit

/// Schedules background price checks when the app leaves the foreground.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundCheckScheduler.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundCheckScheduler.scheduleNextRefresh()
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        if let parsed = SharedURLStore.ingest(openURL: url) {
            Task { @MainActor in
                SharedURLStore.shared.setPending(parsed)
            }
            return true
        }
        return false
    }
}
#endif

@main
struct URLPriceCheckApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var macAppDelegate
    #endif

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([WatchedItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(sharedModelContainer)
                .task {
                    NotificationManager.shared.configure()
                    _ = await NotificationManager.shared.requestPermission()
                    BackgroundCheckScheduler.scheduleNextRefresh()
                }
                .onAppear {
                    let context = ModelContext(sharedModelContainer)
                    BackgroundCheckScheduler.startForegroundTimer(context: context)
                }
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 640)
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        #endif
    }
}

#if os(macOS)
import AppKit

/// Opens https:// and urlpricecheck:// links on macOS.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let parsed = SharedURLStore.ingest(openURL: url) else { return }
        Task { @MainActor in
            SharedURLStore.shared.setPending(parsed)
        }
    }
}
#endif

// MARK: - Shared URL handling (merged here so the target always compiles this code)

/// Holds a URL passed in from Share, Open URL, or the clipboard.
@MainActor
@Observable
final class SharedURLStore {
    static let shared = SharedURLStore()

    private(set) var pendingURL: String?
    static let appGroupID = "group.com.deanwass.URLPriceCheck"
    private static let pendingKey = "pendingSharedURL"

    private init() {
        pendingURL = Self.loadFromAppGroup()
    }

    func setPending(_ urlString: String?) {
        let normalized = urlString.flatMap { SharedURLParser.normalize($0) }
        pendingURL = normalized
        if let normalized {
            UserDefaults(suiteName: Self.appGroupID)?.set(normalized, forKey: Self.pendingKey)
        } else {
            UserDefaults(suiteName: Self.appGroupID)?.removeObject(forKey: Self.pendingKey)
        }
    }

    func consumePending() -> String? {
        let value = pendingURL
        setPending(nil)
        return value
    }

    static func loadFromAppGroup() -> String? {
        guard let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: pendingKey) else { return nil }
        return SharedURLParser.normalize(raw)
    }

    /// `urlpricecheck://add?url=https://...` or a plain https URL.
    static func ingest(openURL: URL) -> String? {
        if openURL.scheme?.lowercased() == "urlpricecheck" {
            if let components = URLComponents(url: openURL, resolvingAgainstBaseURL: false),
               let queryURL = components.queryItems?.first(where: { $0.name == "url" })?.value {
                return SharedURLParser.normalize(queryURL)
            }
            return nil
        }
        if openURL.scheme?.lowercased() == "https" || openURL.scheme?.lowercased() == "http" {
            return SharedURLParser.normalize(openURL.absoluteString)
        }
        return nil
    }

    static func deepLink(for storeURL: String) -> URL? {
        guard let encoded = storeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "urlpricecheck://add?url=\(encoded)")
    }
}

enum SharedURLParser {

    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return url.absoluteString
        }

        if trimmed.lowercased().hasPrefix("www."),
           let url = URL(string: "https://\(trimmed)"),
           url.host != nil {
            return url.absoluteString
        }

        if let extracted = extractHTTPURL(from: trimmed) {
            return extracted
        }

        return nil
    }

    static func extractHTTPURL(from text: String) -> String? {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        var url = String(text[range])
        while let last = url.last, ".,);]".contains(last) {
            url.removeLast()
        }
        return normalize(url)
    }

    #if os(iOS)
    static func readPasteboardURL() -> String? {
        let pasteboard = UIPasteboard.general
        if let url = pasteboard.url {
            return normalize(url.absoluteString)
        }
        if let string = pasteboard.string {
            return normalize(string) ?? extractHTTPURL(from: string)
        }
        return nil
    }
    #elseif os(macOS)
    static func readPasteboardURL() -> String? {
        let pasteboard = NSPasteboard.general
        if let url = pasteboard.string(forType: .URL).flatMap({ URL(string: $0) }) {
            return normalize(url.absoluteString)
        }
        if let string = pasteboard.string(forType: .string) {
            return normalize(string) ?? extractHTTPURL(from: string)
        }
        return nil
    }
    #endif
}
