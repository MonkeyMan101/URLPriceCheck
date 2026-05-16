import SwiftUI
import SwiftData

/// Add or edit a watched URL.
struct WatchFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var itemToEdit: WatchedItem?
    var initialURL: String?

    @State private var name = ""
    @State private var urlString = ""
    @State private var alertPriceText = ""
    @State private var criticalPriceText = ""
    @State private var keywordsLeft = ""
    @State private var keywordsRight = ""
    @State private var keywordsNegative = ""
    @State private var intervalHours = 6
    @State private var isPreviewing = false
    @State private var previewPrice: String?
    @State private var previewError: String?
    @State private var detectedName: String?
    @State private var didLoadExisting = false
    @State private var didLoadInitialURL = false

    private var isEditing: Bool { itemToEdit != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormLTRRow("Name", hint: "Leave blank to detect from the page (AI on supported devices)") {
                        TextField("Product name (optional)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                    FormLTRRow("Store URL") {
                        TextField("https://www.example.com/product", text: $urlString)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                } header: {
                    Text("Item")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Button {
                        Task { await preview() }
                    } label: {
                        HStack {
                            Label("Detect price", systemImage: "sparkle.magnifyingglass")
                            Spacer()
                            if isPreviewing { ProgressView() }
                        }
                    }
                    .disabled(!canDetectPrice)

                    if let detectedName, name.trimmingCharacters(in: .whitespaces).isEmpty {
                        FormLTRRow("Detected name") {
                            Text(detectedName)
                                .fontWeight(.medium)
                                .formFieldLTR()
                        }
                    }
                    if let previewPrice {
                        FormLTRRow("Found") {
                            Text(previewPrice)
                                .fontWeight(.semibold)
                                .formFieldLTR()
                        }
                    }
                    if let previewError {
                        Text(previewError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                } header: {
                    Text("Price check")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } footer: {
                    Text("Xbox uses fixed rules. Other stores use keywords below plus smart matching.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                Section {
                    FormLTRRow(
                        "Words to the left of price",
                        hint: "Visible words only — e.g. performance, ultimate, was"
                    ) {
                        TextField("performance, ultimate, was", text: $keywordsLeft, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                    FormLTRRow(
                        "Words to the right of price",
                        hint: "e.g. 12 months, /month — not HTML/CSS code"
                    ) {
                        TextField("12 months, /month", text: $keywordsRight, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                    FormLTRRow(
                        "Words to avoid",
                        hint: "Prices near these are ignored, e.g. other sellers"
                    ) {
                        TextField("other sellers, sponsored", text: $keywordsNegative, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                } header: {
                    Text("Price hints (optional)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    FormLTRRow("Alert at or below") {
                        TextField("20.00", text: $alertPriceText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                    FormLTRRow("Critical at or below") {
                        TextField("15.00", text: $criticalPriceText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .formFieldLTR()
                    }
                } header: {
                    Text("Alert prices")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } footer: {
                    Text("Normal notification at alert; stronger notification at critical.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                Section {
                    Stepper(value: $intervalHours, in: 1 ... 24) {
                        Text("Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("Schedule")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .environment(\.layoutDirection, .leftToRight)
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 620)
            #endif
            .navigationTitle(isEditing ? "Edit watch" : "Add watch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !isEditing {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            pasteURLFromClipboard()
                        } label: {
                            Label("Paste URL", systemImage: "doc.on.clipboard")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear {
                loadExistingIfNeeded()
                loadInitialURLIfNeeded()
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var canDetectPrice: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: urlString.trimmingCharacters(in: .whitespaces)) != nil
            && !isPreviewing
    }

    private var canSave: Bool {
        URL(string: urlString.trimmingCharacters(in: .whitespaces)) != nil
    }

    private func loadExistingIfNeeded() {
        guard !didLoadExisting, let item = itemToEdit else { return }
        didLoadExisting = true
        name = item.name
        urlString = item.urlString
        alertPriceText = decimalString(item.alertPrice)
        criticalPriceText = decimalString(item.criticalPrice)
        keywordsLeft = item.keywordsLeft ?? ""
        keywordsRight = item.keywordsRight ?? ""
        keywordsNegative = item.keywordsNegative ?? ""
        intervalHours = item.checkIntervalHours
    }

    private func loadInitialURLIfNeeded() {
        guard !didLoadInitialURL, itemToEdit == nil else { return }
        didLoadInitialURL = true
        if let initialURL, let normalized = SharedURLParser.normalize(initialURL) {
            urlString = normalized
        }
    }

    private func pasteURLFromClipboard() {
        if let url = SharedURLParser.readPasteboardURL() {
            urlString = url
        }
    }

    private func save() {
        Task {
            await saveAsync()
        }
    }

    private func saveAsync() async {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        var trimmedName = name.trimmingCharacters(in: .whitespaces)
        let left = normalizedKeywords(keywordsLeft)
        let right = normalizedKeywords(keywordsRight)
        let negative = normalizedKeywords(keywordsNegative)

        if trimmedName.isEmpty, let url = URL(string: trimmedURL) {
            if let resolved = await resolveProductName(url: url) {
                trimmedName = resolved
            } else if let detectedName {
                trimmedName = detectedName
            } else {
                trimmedName = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Product"
            }
        }

        if let item = itemToEdit {
            item.name = trimmedName
            item.urlString = trimmedURL
            item.alertPrice = parseDecimal(alertPriceText)
            item.criticalPrice = parseDecimal(criticalPriceText)
            item.keywordsLeft = left
            item.keywordsRight = right
            item.keywordsNegative = negative
            item.checkIntervalHours = intervalHours
            dismiss()
            Task { await PriceCheckService.shared.check(item: item) }
        } else {
            let item = WatchedItem(
                name: trimmedName,
                urlString: trimmedURL,
                alertPrice: parseDecimal(alertPriceText),
                criticalPrice: parseDecimal(criticalPriceText),
                checkIntervalHours: intervalHours,
                keywordsLeft: left,
                keywordsRight: right,
                keywordsNegative: negative
            )
            modelContext.insert(item)
            dismiss()
            Task { await PriceCheckService.shared.check(item: item) }
        }
    }

    private func normalizedKeywords(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func preview() async {
        isPreviewing = true
        previewPrice = nil
        previewError = nil
        detectedName = nil
        defer { isPreviewing = false }

        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            previewError = "Invalid URL"
            return
        }
        let hints = CustomKeywordHints(
            left: CustomKeywordHints.parseList(keywordsLeft),
            right: CustomKeywordHints.parseList(keywordsRight),
            negative: CustomKeywordHints.parseList(keywordsNegative)
        )
        do {
            let html = try await PageFetcher.fetchHTML(url: url)
            var trimmedName = name.trimmingCharacters(in: .whitespaces)
            if trimmedName.isEmpty {
                let resolved = await ProductNameResolver.resolve(html: html, pageURL: url, existingName: nil)
                detectedName = resolved
                trimmedName = resolved ?? ""
            }
            let price = try await StorePriceResolver.bestPrice(
                from: html,
                pageURL: url,
                productName: trimmedName.isEmpty ? nil : trimmedName,
                customHints: hints
            )
            previewPrice = price.display + " · \(sourceLabel(price.source))"
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func resolveProductName(url: URL) async -> String? {
        do {
            let html = try await PageFetcher.fetchHTML(url: url)
            return await ProductNameResolver.resolve(html: html, pageURL: url, existingName: nil)
        } catch {
            return nil
        }
    }

    private func parseDecimal(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return Decimal(string: t.replacingOccurrences(of: ",", with: ""))
    }

    private func decimalString(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private func sourceLabel(_ source: String) -> String {
        if source.hasPrefix("smart-") { return "keyword match" }
        if source.hasPrefix("amazon-") { return "Amazon" }
        if source.hasPrefix("geforce-") { return "GeForce NOW" }
        switch source {
        case "display": return "store page"
        case "json-ld", "listPrice", "msrp", "price": return "structured data"
        case "ai": return "on-device AI"
        default: return source
        }
    }
}
