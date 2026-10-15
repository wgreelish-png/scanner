import SwiftUI
import SwiftData

struct ScannerView: View {
    let session: ScanSession
    let list: CardList
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [ScanSession]
    @State private var game: String
    @State private var pendingGame: String?
    @State private var confirmGame = false
    @State private var nextSessionID: UUID?
    @State private var model = ScannerViewModel()
    @State private var mode = "Mock"
    init(session: ScanSession, list: CardList) {
        self.session = session; self.list = list
        _game = State(initialValue: session.game ?? "Pokémon")
    }
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
                    LiveScannerPanel(provider: live) { model.stop(); model.paused = false; model.start(game: session.game ?? game, list: list, context: context, session: session) }
                    Text("Live module integration uses your TCGTracking permission. iPhone validation is pending.").font(.caption)
                } else {
                    Text("Synthetic database loaded locally. Sample prices are illustrative.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill") { model.togglePause(game: session.game ?? game, list: list, context: context, session: session) }
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
                        .font(.callout).foregroundStyle(model.confirmed ? Color.primary : Color.orange)
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
                        .disabled(!model.confirmed || !session.isActive)
                    Text("Each tap adds one physical copy. Camera frame updates never count as extra copies.").font(.caption).foregroundStyle(.secondary)
                } else { Text(model.liveProvider == nil ? "Waiting for mock recognition…" : "Start the live camera above, then hold a card steady.") }
                Text("Batch: \(list.name)").font(.caption).foregroundStyle(.secondary)
                if session.isActive { FinishSessionButton(session: session) { model.stop(); dismiss() } }
                else { Text("This session is completed. Its list is available for review and export.") }
            }.padding()
        }.navigationTitle("Scanner")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates)
                    Text("\(totals.quantity) cards • \(totals.market.money) market • \(totals.cash.money) cash").font(.subheadline.bold())
                    if totals.unpricedQuantity > 0 { Text("\(totals.unpricedQuantity) unpriced — partial totals").font(.caption).foregroundStyle(.orange) }
                    NavigationLink("View List / Review & Offer") { SessionReviewView(session: session, list: list) }
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
            .onAppear { if session.isActive { model.start(game: session.game ?? game, list: list, context: context, session: session) } }
            .onDisappear { model.stop() }
            .onChange(of: scenePhase) { _, phase in
                DiagnosticLog.shared.record("app.scene", ["phase": phase == .active ? "active" : (phase == .background ? "background" : "inactive")])
                if phase == .active && !model.paused && session.isActive { model.start(game: session.game ?? game, list: list, context: context, session: session) }
                else if phase == .background { model.stop() }
            }
            .onChange(of: game) { _, newGame in
                guard newGame != session.game else { return }
                pendingGame = newGame; game = session.game ?? "Pokémon"; confirmGame = true
            }
            .onChange(of: session.isActive) { _, active in if !active { model.stop() } }
            .confirmationDialog("Finish this batch and start a new game?", isPresented: $confirmGame) {
                Button("Finish & Start New Session") {
                    guard let pendingGame else { return }
                    do {
                        let next = try SessionService.replace(session, game: pendingGame, context: context)
                        model.stop(); nextSessionID = next.id
                    } catch { model.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) { pendingGame = nil }
            } message: { Text("The current list and estimates will be kept. Changing games creates a separate batch.") }
            .navigationDestination(item: $nextSessionID) { id in
                if let next = sessions.first(where: { $0.id == id }) { BatchScannerDestination(session: next) }
            }
            .onChange(of: mode) { _, _ in restart() }
            .failureAlert($model.error)
    }
    private func restart() {
        model.stop()
        let provider: any ScannerProvider
        if mode == "Live" { provider = TCGTrackingScannerProvider() } else { provider = MockScannerProvider() }
        model = ScannerViewModel(provider: provider)
        model.start(game: session.game ?? game, list: list, context: context, session: session)
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
