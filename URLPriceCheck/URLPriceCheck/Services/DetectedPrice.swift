import Foundation

struct DetectedPrice: Identifiable, Equatable, Comparable {
    let id = UUID()
    let amount: Decimal
    let currency: String
    let display: String
    let source: String

    static func < (lhs: DetectedPrice, rhs: DetectedPrice) -> Bool {
        lhs.amount < rhs.amount
    }
}

enum PriceExtractionError: LocalizedError {
    case noPriceFound
    case geforceNOWJavaScriptPage

    var errorDescription: String? {
        switch self {
        case .noPriceFound:
            "Could not find a price on this page."
        case .geforceNOWJavaScriptPage:
            "GeForce NOW loads prices with JavaScript on this page. The NVIDIA price API could not be reached or returned no products — try Check again, or use a membership URL with prices in the page HTML."
        }
    }
}
