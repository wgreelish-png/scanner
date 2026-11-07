import SwiftUI

/// Opening this foreground workspace finds the printer; printing stays explicit.
@MainActor struct PriceTagsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ShowBudgetStore
    @State private var approvals = TagApprovalStore.shared
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared
    @State private var gamePreferences = InventoryGamePreferences.shared
    @State private var paperPreferences: LabelPaperPreferences
    @State private var batch: InventoryLabelBatchMode?
    @State private var destination: Destination?

    private enum Destination: Hashable { case custom, bulk, queue, printer }

    init(store: ShowBudgetStore = .shared, paperPreferences: LabelPaperPreferences = .shared) {
        _store = State(initialValue: store)
        _paperPreferences = State(initialValue: paperPreferences)
    }

    private var gameInventory: [ShowInventoryItem] {
        InventoryGameFilter.filtered(store.inventory, game: gamePreferences.selectedGame)
    }
    private var available: [ShowInventoryItem] { gameInventory.filter { $0.quantity > 0 } }
    private var changedIDs: Set<UUID> {
        InventoryLabelBatch.selectedIDs(mode: .priceChanged, inventory: gameInventory,
            store: approvals)
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
                gamePicker
                printerStatus
                VStack(spacing: 12) {
                    batchButton(.all, title: "Print All", subtitle: "One label per available copy, including reprints.",
                        symbol: "square.stack.3d.up.fill", count: available.count)
                    batchButton(.custom, title: "Select Individual Inventory", subtitle: "Choose cards and copies from your inventory.",
                        symbol: "rectangle.stack", count: nil, identifier: "priceTags.chooseCards")
                    batchButton(.priceChanged, title: "Print Price Changed", subtitle: "New cards and saved sticker prices that still need labels.",
                        symbol: "arrow.triangle.2.circlepath", count: approvals.isLoaded ? changedIDs.count : nil)
                    Button { destination = .custom } label: {
                        routeLabel(title: "Custom Price Tag", subtitle: "PokéDen logo, price and copies. No inventory needed.",
                            symbol: "square.and.pencil", count: nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("priceTags.custom")
                    Button { destination = .bulk } label: {
                        routeLabel(title: "2 for $1 Bulk Tags", subtitle: "PokéDen stickers for bulk bins. Choose copies and paper.",
                            symbol: "tray.2", count: nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("priceTags.bulk")
                }
                if !store.isLoaded || !approvals.isLoaded {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.error ?? approvals.error ?? "Saved pricing data is unavailable.")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Reload Saved Data") { store.reload(); approvals.reload() }
                    }
                } else if available.isEmpty {
                    ContentUnavailableView("No available cards", systemImage: "shippingbox",
                        description: Text(gamePreferences.selectedGame.isEmpty
                            ? "Create a custom sticker above, or import inventory to prepare card labels."
                            : "No available cards for \(InventoryGameFilter.title(for: gamePreferences.selectedGame)). Choose All Games or another game to prepare inventory labels."))
                }
                VStack(spacing: 0) {
                    Button { destination = .queue } label: {
                        HStack {
                            Label("Saved Print Queue", systemImage: "tray.full")
                            Spacer()
                            Text(queue.isLoaded ? queue.entries.count.formatted() : "Needs attention")
                                .foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("priceTags.queue")
                    Divider().padding(.vertical, 14)
                    Button { destination = .printer } label: {
                        HStack {
                            Label("Printer Settings", systemImage: "printer")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("priceTags.printer")
                }
                .font(.subheadline.weight(.semibold)).padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                Text("Every selected inventory copy receives a tag. Saved prices and 2 for $1 deals stay unchanged; unavailable and $0 prices leave space to write in. Opening a batch never starts printing.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Price Tags").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ClearLabelPrintQueueButton(identifier: "priceTags.clearQueue")
            }
        }
        .sheet(item: $batch) { mode in
            InventoryLabelFlowView(inventory: gameInventory, mode: mode,
                                   paperPreferences: paperPreferences, onPrintingCompleted: finishPrinting)
        }
        .navigationDestination(item: $destination) { route in
            switch route {
            case .custom:
                CustomPriceTagView(paperPreferences: paperPreferences, onPrintingCompleted: finishPrinting)
            case .bulk:
                CustomPriceTagView(isBulk: true, paperPreferences: paperPreferences, onPrintingCompleted: finishPrinting)
            case .queue:
                LabelPrintQueueView(onPrintingCompleted: finishPrinting)
            case .printer:
                LabelPrinterSettingsView(onPrintingCompleted: finishPrinting)
            }
        }
        .onAppear { printer.startPriceTagsConnection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { printer.startPriceTagsConnection() }
        }
    }

    private func finishPrinting() {
        batch = nil
        destination = nil
    }

    private var gamePicker: some View {
        HStack {
            Text("Game").font(.subheadline.weight(.semibold))
            Spacer()
            Picker("Game", selection: $gamePreferences.selectedGame) {
                Text("All Games").tag("")
                ForEach(InventoryGameFilter.games(in: store.inventory, including: gamePreferences.selectedGame), id: \.self) { game in
                    Text(InventoryGameFilter.title(for: game)).tag(game)
                }
            }
            .pickerStyle(.menu).labelsHidden()
            .accessibilityLabel("Game")
            .accessibilityValue(gamePreferences.selectedGame.isEmpty
                ? "All Games" : InventoryGameFilter.title(for: gamePreferences.selectedGame))
            .accessibilityIdentifier("priceTags.game")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var printerStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(printer.isConnected ? "\(printer.modelName) connected" : "Label printer",
                      systemImage: printer.isConnected ? "checkmark.circle.fill" : "printer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(printer.isConnected ? Color.green : Color.primary)
                    .accessibilityIdentifier("priceTags.printerConnection")
                Spacer()
                if printer.isScanning { ProgressView().accessibilityLabel("Searching for printer") }
            }
            Text(printer.status).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("priceTags.printerStatus")
            LabelRollEstimateView(printer: printer, pendingLabels: queue.pendingCount, identifier: "priceTags.roll")
            if let error = printer.error {
                Text(error).font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("priceTags.printerError")
            }
            if !printer.isConnected {
                ForEach(printer.devices) { device in
                    Button { printer.connect(device.id) } label: {
                        Label(device.name, systemImage: "printer")
                    }
                    .disabled(printer.isPrinting || printer.isConfiguringPaper)
                    .accessibilityIdentifier("priceTags.printerDevice." + device.id.uuidString)
                }
                if !printer.isScanning {
                    Button("Search for Printer") { printer.startSearch() }
                        .disabled(printer.isPrinting || printer.isConfiguringPaper)
                        .accessibilityIdentifier("priceTags.printerSearch")
                }
            }
            Text(paperPreferences.detectedProduct == nil
                 ? "Last used: \(paperPreferences.size.title) · Check the loaded roll"
                 : "Detected from roll: \(paperPreferences.size.title) · \(paperPreferences.detectedProduct?.paperType == 5 ? "Transparent" : "Gap")")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("priceTags.paperSize")
            Text("New labels: \(paperPreferences.pricePosition.title)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("priceTags.pricePosition")
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func batchButton(_ mode: InventoryLabelBatchMode, title: String, subtitle: String,
                             symbol: String, count: Int?, identifier: String? = nil) -> some View {
        Button { batch = mode } label: {
            routeLabel(title: title, subtitle: subtitle, symbol: symbol, count: count)
        }
        .buttonStyle(.plain)
        .disabled(!store.isLoaded || !approvals.isLoaded || available.isEmpty || (mode == .priceChanged && count == 0))
        .accessibilityIdentifier(identifier ?? "priceTags." + (mode == .priceChanged ? "changed" : mode.rawValue))
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

}

/// The same foreground action is available throughout label preparation.
/// It removes saved print work without changing inventory or sticker prices.
@MainActor struct ClearLabelPrintQueueButton: View {
    let identifier: String
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared
    @State private var confirming = false
    @State private var failure: String?

    init(identifier: String = "labels.clearQueue") { self.identifier = identifier }

    private var busy: Bool { queue.isPrinting || printer.isPrinting || printer.isConfiguringPaper }
    private var empty: Bool { queue.isLoaded && queue.entries.isEmpty }

    var body: some View {
        Button { confirming = true } label: {
            Label("Clear Print Queue", systemImage: "trash")
        }
        .disabled(busy || empty)
        .accessibilityIdentifier(identifier)
        .confirmationDialog("Clear the print queue?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Clear Print Queue", role: .destructive) { clearQueue() }
                .accessibilityIdentifier(identifier + ".confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(identifier + ".cancel")
        } message: {
            Text(confirmationMessage)
        }
        .alert("Unable to Clear Print Queue", isPresented: Binding(get: { failure != nil }, set: {
            if !$0 { failure = nil }
        })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private var confirmationMessage: String {
        let message = queue.isLoaded
            ? "This removes all \(queue.entries.count.formatted()) saved labels and their print progress. Inventory and sticker prices stay unchanged."
            : "This discards the unreadable saved print queue. Inventory and sticker prices stay unchanged."
        return queue.uncertainCount > 0 || !queue.isLoaded
            ? message + " Check any uncertain physical labels before preparing another batch."
            : message
    }

    private func clearQueue() {
        do {
            guard !busy else { throw LabelPrinterIssue.printerBusy }
            if queue.isLoaded { try queue.clear() }
            else { try queue.discardSavedQueue() }
        } catch { failure = error.localizedDescription }
    }
}
