import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchedItem.createdAt, order: .reverse) private var items: [WatchedItem]
    @State private var showingAdd = false
    @State private var addWatchInitialURL: String?
    @State private var isCheckingAll = false
    @State private var itemToEdit: WatchedItem?
    @State private var notificationStatus: NotificationAuthStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No watches yet",
                        systemImage: "tag",
                        description: Text("Add a URL, or share a product page from Safari using Watch in URLPriceCheck.")
                    )
                } else {
                    List {
                        ForEach(items) { item in
                            NavigationLink {
                                WatchDetailView(item: item)
                            } label: {
                                WatchRowView(item: item)
                            }
                            .contextMenu {
                                Button {
                                    itemToEdit = item
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    itemToEdit = item
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.accentColor)
                            }
                        }
                        .onDelete(perform: deleteAtOffsets)
                    }
                }
            }
            .navigationTitle("URLPriceCheck")
            .safeAreaInset(edge: .top, spacing: 0) {
                notificationBanner
            }
            .task {
                await refreshNotificationStatus()
            }
            .onAppear {
                presentPendingSharedURLIfNeeded()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await checkAll() }
                    } label: {
                        if isCheckingAll {
                            ProgressView()
                        } else {
                            Label("Check all", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(items.isEmpty || isCheckingAll)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await enableNotifications() }
                    } label: {
                        Label(
                            "Notifications",
                            systemImage: notificationStatus == .authorized ? "bell.fill" : "bell.badge"
                        )
                    }
                }
            }
            .sheet(isPresented: $showingAdd, onDismiss: { addWatchInitialURL = nil }) {
                AddWatchView(initialURL: addWatchInitialURL)
            }
            .sheet(item: $itemToEdit) { item in
                WatchFormView(itemToEdit: item)
            }
        }
    }

    private func delete(_ item: WatchedItem) {
        modelContext.delete(item)
    }

    private func deleteAtOffsets(_ offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(items[index])
        }
    }

    private func checkAll() async {
        isCheckingAll = true
        defer { isCheckingAll = false }
        for item in items where item.isEnabled {
            await PriceCheckService.shared.check(item: item)
        }
    }

    @ViewBuilder
    private var notificationBanner: some View {
        if notificationStatus == .denied {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications are off")
                        .font(.subheadline.weight(.semibold))
                    Text("Turn on alerts in Settings to get price and check-complete notifications on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Settings") {
                    NotificationManager.shared.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(.orange.opacity(0.12))
        } else if notificationStatus == .notDetermined {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Enable notifications for price alerts and check results.")
                    .font(.caption)
                Spacer(minLength: 0)
                Button("Enable") {
                    Task { await enableNotifications() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5))
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await NotificationManager.shared.authorizationStatus()
    }

    private func enableNotifications() async {
        if notificationStatus == .denied {
            NotificationManager.shared.openSystemSettings()
            return
        }
        _ = await NotificationManager.shared.requestPermission()
        await refreshNotificationStatus()
    }

    private func handleIncomingURL(_ url: URL) {
        guard let parsed = SharedURLStore.ingest(openURL: url) else { return }
        SharedURLStore.shared.setPending(parsed)
        presentAddWatch(with: parsed)
    }

    private func presentPendingSharedURLIfNeeded() {
        guard let pending = SharedURLStore.shared.consumePending() else { return }
        presentAddWatch(with: pending)
    }

    private func presentAddWatch(with url: String) {
        addWatchInitialURL = url
        showingAdd = true
    }
}

#Preview {
    ContentView()
        .modelContainer(for: WatchedItem.self, inMemory: true)
}
