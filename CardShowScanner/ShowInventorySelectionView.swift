import SwiftUI
import UIKit

/// Selection has its own searchable list; checkout renders only the cart.
@MainActor struct ShowInventorySelectionView: View {
    let store: ShowBudgetStore
    @Binding var quantities: [UUID: Int]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var available: [ShowInventoryItem] { store.inventory.filter { $0.quantity > 0 } }
    private var filtered: [ShowInventoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return available.filter { item in
            query.isEmpty || [item.card.name, item.card.set, item.card.number, item.card.identity.printing,
                item.card.identity.condition, item.card.identity.language].joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }
    private var activityState: DiagnosticActivityState {
        .init(selectedCount: quantities.values.reduce(0, +), cardCount: available.reduce(0) { $0 + $1.quantity })
    }
    var body: some View {
        List {
            if available.isEmpty {
                ContentUnavailableView("No available stock", systemImage: "shippingbox",
                    description: Text("Import your Card Show snapshot or record a purchase first."))
            } else if filtered.isEmpty { ContentUnavailableView.search(text: search) }
            ForEach(filtered) { item in
                let selected = quantities[item.id] ?? 0
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if selected > 0 { quantities.removeValue(forKey: item.id) }
                        else { quantities[item.id] = 1 }
                        DiagnosticLog.shared.activity(.action, screen: .inventorySelection, action: .selectCard, state: activityState)
                    } label: {
                        HStack(spacing: 12) {
                            ShowTransactionCardRow(card: item.card, quantity: item.quantity, quantityTitle: "Available")
                            Image(systemName: selected > 0 ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(selected > 0 ? Color.indigo : Color.secondary)
                        }.frame(minHeight: 76).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(item.card.name), \(item.quantity) available")
                        .accessibilityAddTraits(selected > 0 ? .isSelected : [])
                        .accessibilityIdentifier("showTransaction.stock." + item.id.uuidString)
                    if selected > 0 {
                        Stepper("Quantity: \(selected)", value: Binding(get: { quantities[item.id] ?? 1 },
                            set: {
                                quantities[item.id] = $0
                                DiagnosticLog.shared.activity(.action, screen: .inventorySelection, action: .changeQuantity, state: activityState)
                            }), in: 1...item.quantity)
                            .accessibilityIdentifier("showTransaction.quantity." + item.id.uuidString)
                    }
                }.padding(.vertical, 6)
            }
        }
        .navigationTitle("Select Inventory Cards").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, set, number, or condition")
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(of: .search) { endEditing() }
        .safeAreaInset(edge: .top) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(quantities.values.reduce(0, +)) selected").font(.headline)
                }
                Spacer()
                if !quantities.isEmpty {
                    Button("Clear") {
                        quantities.removeAll()
                        DiagnosticLog.shared.activity(.action, screen: .inventorySelection, action: .clearSelection, state: activityState)
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    DiagnosticLog.shared.activity(.action, screen: .inventorySelection, action: .saveChanges, state: activityState)
                    endEditing(); dismiss()
                }.fontWeight(.semibold)
                    .accessibilityIdentifier("showInventorySelection.done")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { endEditing() }.fixedSize().frame(minWidth: 64, minHeight: 44)
                    .accessibilityIdentifier("showInventorySelection.keyboardDone")
            }
        }
        .onAppear { DiagnosticLog.shared.activity(.screen, screen: .inventorySelection, state: activityState) }
        .onDisappear { endEditing(); DiagnosticLog.shared.activity(.exit, screen: .inventorySelection) }
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
