import SwiftUI
import SwiftData

struct ScannerView: View {
    let list: CardList
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("defaultGame") private var game = "Pokémon"
    @State private var model = ScannerViewModel()
    @State private var mode = "Mock"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.label).font(.caption.bold()).foregroundStyle(.orange)
                Picker("Game", selection: $game) {
                    ForEach(CatalogOptions.games, id: \.self) { Text($0) }
                }.pickerStyle(.menu)
                Picker("Scanner source", selection: $mode) {
                    Text("Mock").tag("Mock")
                    Text("TCGTracking (experimental)").tag("Live")
                }.pickerStyle(.menu)
                if let live = model.liveProvider {
                    LiveScannerPanel(provider: live) { model.stop(); model.paused = false; model.start(game: game, list: list, context: context) }
                    Text("Live module integration uses your TCGTracking permission. iPhone validation is pending.").font(.caption)
                } else {
                    Text("Synthetic database loaded locally. Sample prices are illustrative.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill") { model.togglePause(game: game, list: list, context: context) }
                    Spacer()
                }.buttonStyle(.bordered)
                if let card = model.selected {
                    CardSummaryView(card: card)
                    Picker("Printing", selection: Binding(get: { card.identity.printing }, set: { model.changePrinting($0) })) {
                        ForEach(card.printings.isEmpty ? [card.identity.printing] : card.printings, id: \.self) { Text($0) }
                    }
                    if card.requiresPrintingSelection == true {
                        Button("Confirm \(card.identity.printing) Printing") { model.confirmPrinting() }.buttonStyle(.bordered)
                        Text("Printing is ambiguous. Confirm a finish before adding.").foregroundStyle(.orange)
                    }
                    Text(model.result?.accepted == true ? "Recognized match — review before adding" : "Ambiguous result — select the correct candidate below")
                        .font(.callout).foregroundStyle(model.confirmed ? .primary : .orange)
                    Text("Possible matches").font(.headline)
                    ForEach(Array((model.result?.candidates ?? []).prefix(5))) { candidate in
                        Button { model.choose(candidate) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(candidate.name).font(.headline)
                                    Text("\(candidate.set) • \(candidate.number) • \(Int(candidate.confidence))%")
                                        .font(.caption)
                                }
                                Spacer()
                                if candidate.id == card.id { Image(systemName: "checkmark.circle.fill") }
                            }.frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                    Button(model.manualAdds > 0 ? "Add Another Copy" : "Add Selected Card", systemImage: "plus.circle.fill") {
                        model.addSelected(list: list, context: context)
                    }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(!model.confirmed)
                    Text("Each tap adds one physical copy. Camera frame updates never count as extra copies.").font(.caption).foregroundStyle(.secondary)
                } else { Text(model.liveProvider == nil ? "Waiting for mock recognition…" : "Start the live camera above, then hold a card steady.") }
                if let session = model.session {
                    GroupBox("Current session") {
                        VStack(alignment: .leading) {
                            Text("\(session.addedQuantity) cards • \(session.knownValue.money) known subtotal")
                            if session.unpricedQuantity > 0 { Text("\(session.unpricedQuantity) unpriced copies") }
                            Button("Reset Session Totals") { model.resetSession(context: context, listName: list.name) }
                        }
                    }
                }
                NavigationLink("Open \(list.name)") { CardListView(list: list) }
            }.padding()
        }.navigationTitle("Scanner")
            .onAppear { model.start(game: game, list: list, context: context) }
            .onDisappear { model.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !model.paused { model.start(game: game, list: list, context: context) }
                else if phase == .background { model.stop() }
            }
            .onChange(of: game) { _, _ in restart() }
            .onChange(of: mode) { _, _ in restart() }
            .failureAlert($model.error)
    }
    private func restart() {
        model.stop()
        let provider: any ScannerProvider
        if mode == "Live" { provider = TCGTrackingScannerProvider() } else { provider = MockScannerProvider() }
        model = ScannerViewModel(provider: provider)
        model.start(game: game, list: list, context: context)
    }
}

struct CardSummaryView: View {
    let card: CardCandidate
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: card.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { Image(systemName: "rectangle.portrait.on.rectangle.portrait").resizable().scaledToFit().padding().foregroundStyle(.secondary) }
            }.frame(width: 84, height: 118).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(card.name).font(.title2.bold())
                Text("\(card.set) • \(card.number)")
                Text(card.identity.printing).foregroundStyle(.secondary)
                Text(card.marketPrice?.money ?? "Price unavailable").font(.headline)
            }
        }
    }
}
