import SwiftUI

/// Convenience wrapper for adding a new watch.
struct AddWatchView: View {
    var initialURL: String?

    var body: some View {
        WatchFormView(initialURL: initialURL)
    }
}
