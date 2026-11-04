import SwiftUI
import SwiftData

/// A foreground-only workspace. Choosing a batch never starts Bluetooth or prints.
@MainActor struct PriceTagsView: View {
    @Environment(\.modelContext) private var context
    @State private var store: ShowBudgetStore
    @State private var approvals = TagApprovalStore.shared
    @State private var queue = LabelPrintQueue.shared
    @State private var marketQuotes: [UUID: TagMarketQuote] = [:]
    @State private var batch: InventoryLabelBatchMode?

    init(store: ShowBudgetStore = .shared) { _store = State(initialValue: store) }

    private var available: [ShowInventoryItem] { store.inventory.filter { $0.quantity > 0 } }
    private var changedIDs: Set<UUID> {
        InventoryLabelBatch.selectedIDs(mode: .priceChanged, inventory: store.inventory,
            marketQuotes: marketQuotes, store: approvals)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ready for the show").font(.title2.bold())
                    Text("\(available.reduce(0) { $0 + $1.quantity }.formatted()) cards · \(available.count.formatted()) inventory entries")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Choose a batch, check the labels, then print.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    batchButton(.all, title: "Print All", subtitle: "One label per available copy, including reprints.",
                        symbol: "square.stack.3d.up.fill", count: available.count)
                    batchButton(.priceChanged, title: "Print Price Changed", subtitle: "New cards, unprinted tags and prices due for review.",
                        symbol: "arrow.triangle.2.circlepath", count: approvals.isLoaded ? changedIDs.count : nil)
                    NavigationLink { CustomPriceTagView() } label: {
                        routeLabel(title: "Custom Price Tag", subtitle: "Enter a price and copies. No inventory needed.",
                            symbol: "square.and.pencil", count: nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("priceTags.custom")
                }
                if !store.isLoaded || !approvals.isLoaded {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.error ?? approvals.error ?? "Saved pricing data is unavailable.")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Reload Saved Data") { store.reload(); approvals.reload(); refreshQuotes() }
                    }
                } else if available.isEmpty {
                    ContentUnavailableView("No available cards", systemImage: "shippingbox",
                        description: Text("Create a custom sticker above, or import inventory to prepare card labels."))
                }
                VStack(spacing: 0) {
                    Button { batch = .custom } label: {
                        HStack {
                            Label("Choose Inventory Cards", systemImage: "rectangle.stack")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!store.isLoaded || !approvals.isLoaded || available.isEmpty)
                    .accessibilityIdentifier("priceTags.chooseCards")
                    Divider().padding(.vertical, 14)
                    NavigationLink { LabelPrintQueueView() } label: {
                        HStack {
                            Label("Saved Print Queue", systemImage: "tray.full")
                            Spacer()
                            Text(queue.isLoaded ? queue.entries.count.formatted() : "Needs attention")
                                .foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("priceTags.queue")
                    Divider().padding(.vertical, 14)
                    NavigationLink { LabelPrinterSettingsView() } label: {
                        HStack {
                            Label("Printer Settings", systemImage: "printer")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("priceTags.printer")
                }
                .font(.subheadline.weight(.semibold)).padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                Text("Saved manual prices are retained. Bulk cards stay in the 2 for $1 category without individual tags. Opening a batch never starts printing.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Price Tags").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $batch) { mode in
            InventoryLabelFlowView(inventory: store.inventory, marketQuotes: marketQuotes, mode: mode)
        }
        .onAppear { refreshQuotes() }
        .onChange(of: store.inventory) { _, _ in refreshQuotes() }
    }

    private func batchButton(_ mode: InventoryLabelBatchMode, title: String, subtitle: String,
                             symbol: String, count: Int?) -> some View {
        Button { batch = mode } label: {
            routeLabel(title: title, subtitle: subtitle, symbol: symbol, count: count)
        }
        .buttonStyle(.plain)
        .disabled(!store.isLoaded || !approvals.isLoaded || available.isEmpty || (mode == .priceChanged && count == 0))
        .accessibilityIdentifier("priceTags." + (mode == .priceChanged ? "changed" : mode.rawValue))
    }

    private func routeLabel(title: String, subtitle: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    if let count { Text(count.formatted()).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private func refreshQuotes() {
        marketQuotes = TagPricingContext.currentQuotes(inventory: store.inventory, context: context)
    }
}
