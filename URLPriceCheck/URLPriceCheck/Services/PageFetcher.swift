import Foundation

enum PageFetcher {
    #if os(iOS)
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    #else
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    #endif

    static func fetchHTML(url: URL) async throws -> String {
        do {
            return try await fetchWithURLSession(url: url)
        } catch {
            #if os(macOS)
            if shouldTryCurlFallback(error) {
                return try await fetchWithCurl(url: url)
            }
            #endif
            throw error
        }
    }

    private static func fetchWithURLSession(url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }
        return html
    }

    #if os(macOS)
    /// Fallback when URLSession SSL verification fails (macOS only — `Process` is unavailable on iOS).
    private static func fetchWithCurl(url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = ["-fsSL", "-A", userAgent, url.absoluteString]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0,
                          let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                        continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                        return
                    }
                    continuation.resume(returning: html)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func shouldTryCurlFallback(_ error: Error) -> Bool {
        let text = String(describing: error)
        if text.contains("CERTIFICATE_VERIFY_FAILED") || text.contains("-1202") {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .secureConnectionFailed {
            return true
        }
        return false
    }
    #endif
}
