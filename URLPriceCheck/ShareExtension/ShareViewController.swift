import UIKit
import UniformTypeIdentifiers

private enum ShareURLSupport {
    static let appGroupID = "group.com.deanwass.URLPriceCheck"
    static let pendingKey = "pendingSharedURL"

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
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range, in: trimmed) else { return nil }
        return normalize(String(trimmed[range]))
    }

    static func deepLink(for storeURL: String) -> URL? {
        guard let encoded = storeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "urlpricecheck://add?url=\(encoded)")
    }
}

/// Receives a shared web URL and opens the main app with the add-watch flow.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await processSharedItems() }
    }

    private func processSharedItems() async {
        defer { extensionContext?.completeRequest(returningItems: nil) }

        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(from: provider) {
                        finish(with: url.absoluteString)
                        return
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await loadText(from: provider),
                       let normalized = ShareURLSupport.normalize(text) {
                        finish(with: normalized)
                        return
                    }
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    private func finish(with urlString: String) {
        guard let normalized = ShareURLSupport.normalize(urlString) else { return }
        UserDefaults(suiteName: ShareURLSupport.appGroupID)?.set(normalized, forKey: ShareURLSupport.pendingKey)
        if let deepLink = ShareURLSupport.deepLink(for: normalized) {
            extensionContext?.open(deepLink, completionHandler: nil)
        }
    }
}
