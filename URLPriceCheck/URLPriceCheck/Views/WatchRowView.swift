import SwiftUI

struct WatchRowView: View {
    let item: WatchedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name)
                    .font(.headline)
                Spacer()
                if let display = item.lastPriceDisplay {
                    Text(display)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(priceColor)
                } else if item.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let checked = item.lastCheckedAt {
                Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Never checked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.isEnabled {
                Text("Paused")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var priceColor: Color {
        guard let price = item.lastPrice else { return .primary }
        if let critical = item.criticalPrice, price <= critical { return .red }
        if let alert = item.alertPrice, price <= alert { return .green }
        return .primary
    }
}
