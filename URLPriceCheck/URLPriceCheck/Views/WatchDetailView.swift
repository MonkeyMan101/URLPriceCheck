import SwiftUI
import SwiftData

struct WatchDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var item: WatchedItem
    @State private var isChecking = false
    @State private var alertText = ""
    @State private var criticalText = ""
    @State private var keywordsLeftText = ""
    @State private var keywordsRightText = ""
    @State private var keywordsNegativeText = ""
    @State private var showingEdit = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                priceCard
                if let error = item.lastError {
                    errorBanner(error)
                }
                keywordHintsSection
                alertsSection
                scheduleSection
                urlSection
                checkButton
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.layoutDirection, .leftToRight)
        .navigationTitle(item.name)
        #if os(macOS)
        .navigationSubtitle(subtitleText)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) { showingDeleteConfirm = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            WatchFormView(itemToEdit: item)
        }
        .confirmationDialog(
            "Delete “\(item.name)”?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteItem() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This watch will be removed permanently.")
        }
        .onAppear {
            alertText = decimalString(item.alertPrice)
            criticalText = decimalString(item.criticalPrice)
            keywordsLeftText = item.keywordsLeft ?? ""
            keywordsRightText = item.keywordsRight ?? ""
            keywordsNegativeText = item.keywordsNegative ?? ""
        }
    }

    private var keywordHintsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Price hints", icon: "text.magnifyingglass")

            FormLTRRow("Left of price", hint: "Words on the page, e.g. performance") {
                TextField("performance, ultimate", text: $keywordsLeftText)
                    .textFieldStyle(.roundedBorder)
                    .formFieldLTR()
                    .onChange(of: keywordsLeftText) { _, v in
                        item.keywordsLeft = v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v
                    }
            }
            FormLTRRow("Right of price", hint: "e.g. 12 months — not HTML") {
                TextField("12 months", text: $keywordsRightText)
                    .textFieldStyle(.roundedBorder)
                    .formFieldLTR()
                    .onChange(of: keywordsRightText) { _, v in
                        item.keywordsRight = v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v
                    }
            }
            FormLTRRow("Avoid") {
                TextField("other sellers", text: $keywordsNegativeText)
                    .textFieldStyle(.roundedBorder)
                    .formFieldLTR()
                    .onChange(of: keywordsNegativeText) { _, v in
                        item.keywordsNegative = v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v
                    }
            }
        }
    }

    private func deleteItem() {
        modelContext.delete(item)
        dismiss()
    }

    // MARK: - Sections

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current price")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let display = item.lastPriceDisplay {
                Text(display)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(priceColor)
            } else {
                Text("—")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if let checked = item.lastCheckedAt {
                Label(checked.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not checked yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Alerts", icon: "bell")

            FormLTRRow("Alert at or below") {
                TextField("20", text: $alertText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .formFieldLTR()
                    .onChange(of: alertText) { _, v in item.alertPrice = parse(v) }
            }
            FormLTRRow("Critical at or below") {
                TextField("15", text: $criticalText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .formFieldLTR()
                    .onChange(of: criticalText) { _, v in item.criticalPrice = parse(v) }
            }

            Text("Normal alert at your target price; stronger notification at critical.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Schedule", icon: "calendar")

            HStack {
                Text("Check every")
                Spacer()
                Stepper(
                    "\(item.checkIntervalHours) hr",
                    value: $item.checkIntervalHours,
                    in: 1 ... 24
                )
                .labelsHidden()
                Text("\(item.checkIntervalHours) hr")
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }

            Toggle("Enabled", isOn: $item.isEnabled)
        }
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Store link", icon: "link")
            if let url = item.url {
                Link(destination: url) {
                    Text(item.urlString)
                        .font(.caption)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    private var checkButton: some View {
        Button {
            Task { await runCheck() }
        } label: {
            HStack {
                Spacer()
                if isChecking {
                    ProgressView()
                        .padding(.trailing, 6)
                }
                Text(isChecking ? "Checking…" : "Check now")
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isChecking)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }

    // MARK: - Helpers

    private var priceColor: Color {
        guard let price = item.lastPrice else { return .primary }
        if let critical = item.criticalPrice, price <= critical { return .red }
        if let alert = item.alertPrice, price <= alert { return .green }
        return .primary
    }

    private var subtitleText: String {
        if let display = item.lastPriceDisplay { return display }
        return item.isEnabled ? "Watching" : "Paused"
    }

    private func runCheck() async {
        isChecking = true
        defer { isChecking = false }
        await PriceCheckService.shared.check(item: item)
    }

    private func parse(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return Decimal(string: t.replacingOccurrences(of: ",", with: ""))
    }

    private func decimalString(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }
}
