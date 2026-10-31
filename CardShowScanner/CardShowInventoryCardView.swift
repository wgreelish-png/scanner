import SwiftUI

/// The website owns imported card fields and quantities. Research operates on a
/// value copy; an ordinary duplicate list supports local editing and scanning.
struct CardShowInventoryCardView: View {
    let item: InventoryCard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    private var card: CardCandidate { item.snapshot }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let layout = textSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    layout {
                        AsyncImage(url: card.imageURL) { phase in
                            if let image = phase.image { image.resizable().scaledToFit() }
                            else {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                    .overlay { Image(systemName: "rectangle.portrait").font(.largeTitle).foregroundStyle(.secondary) }
                            }
                        }.frame(width: 104, height: 146).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(card.name).font(.title3.bold()).accessibilityIdentifier("cardShowInventory.cardName")
                            Text(card.set).font(.subheadline).foregroundStyle(.secondary)
                            Text(card.number.isEmpty ? card.identity.game : "#" + card.number + " · " + card.identity.game)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(card.marketPrice?.money ?? "Price unavailable")
                                .font(.title2.bold()).monospacedDigit()
                                .accessibilityIdentifier("cardShowInventory.cardPrice")
                            Text("USD per card · Last imported value").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 4)
                }
                Section("Card details") {
                    LabeledContent("Printing", value: card.identity.printing)
                    LabeledContent("Language", value: card.identity.language)
                    LabeledContent("Condition", value: card.identity.condition)
                    LabeledContent("Quantity", value: item.quantity.formatted()).accessibilityIdentifier("cardShowInventory.cardQuantity")
                    if item.quantity > 1 {
                        LabeledContent("Total market value", value: card.marketPrice.map { ($0 * Decimal(item.quantity)).money } ?? "Price unavailable")
                    }
                }
                Section {
                    NavigationLink { CardResearchView(card: card) } label: {
                        Label("Market & Graded Research", systemImage: "magnifyingglass")
                    }.accessibilityIdentifier("cardShowInventory.cardResearch")
                    Text("Refresh Card Show Inventory to update this saved card. Make an editable copy of the list for local changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Card Details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
