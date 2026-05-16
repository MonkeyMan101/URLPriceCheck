import SwiftUI

/// Label above field, both leading-aligned for correct LTR layout on Mac and iOS.
struct FormLTRRow<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Forces left-to-right layout and leading alignment for form fields.
    func formFieldLTR() -> some View {
        self
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .environment(\.layoutDirection, .leftToRight)
            #endif
    }
}
