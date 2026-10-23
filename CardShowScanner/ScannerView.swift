import SwiftUI
import SwiftData
import UIKit

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
    @State private var mode = "Live"
    init(session: ScanSession, list: CardList) {
        self.session = session; self.list = list
        _game = State(initialValue: session.game ?? "Pokémon")
    }
    @State private var visible = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let live = model.liveProvider {
                TCGScannerWebView(provider: live).ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "viewfinder").font(.system(size: 72))
                    Text("MOCK SCANNER").font(.title2.bold())
                    Text("Sample cards only • No camera or live prices")
                }.foregroundStyle(.orange).padding()
            }
            VStack(spacing: 12) {
                cameraHeader
                Spacer(minLength: 0)
                cameraFooter
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .sheet(isPresented: Binding(get: { model.selected != nil }, set: { _ in })) {
            confirmationReview
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onAppear { visible = true; if session.isActive { model.start(game: session.game ?? game, list: list, context: context, session: session) } }
        .onDisappear { visible = false; model.stop() }
        .onChange(of: scenePhase) { _, phase in
            DiagnosticLog.shared.record("app.scene", ["phase": phase == .active ? "active" : (phase == .background ? "background" : "inactive")])
            if phase == .active && visible && !model.paused && session.isActive { model.start(game: session.game ?? game, list: list, context: context, session: session) }
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
        .failureAlert(Binding(get: { model.selected == nil ? model.error : nil }, set: { model.error = $0 }))
    }
    private var cameraHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { model.stop(); dismiss() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel("Back to lists")
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.game ?? game).font(.headline)
                    Text(mode == "Live" ? "LIVE CAMERA" : "MOCK • TESTING ONLY")
                        .font(.caption.bold()).foregroundStyle(mode == "Live" ? Color.white : Color.orange)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.togglePause(game: session.game ?? game, list: list, context: context, session: session)
                } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(model.paused ? "Resume camera" : "Pause camera")
                Menu {
                    Picker("Game", selection: $game) { ForEach(CatalogOptions.games, id: \.self) { Text($0) } }
                    Button("Retry Live Scanner") {
                        model.stop(); model.paused = false
                        model.start(game: session.game ?? game, list: list, context: context, session: session)
                    }.disabled(model.liveProvider == nil)
                    Menu("Developer Testing") {
                        Picker("Scanner source", selection: $mode) {
                            Text("Live Camera").tag("Live")
                            Text("Mock — sample cards").tag("Mock")
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("Scanner options")
            }
            if model.paused { Text("Camera paused").font(.subheadline) }
            else if let live = model.liveProvider { CameraStatusView(provider: live) }
        }.foregroundStyle(.white).padding(8)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
    }

    private var cameraFooter: some View {
        VStack(spacing: 10) {
            if model.waitingForRemoval {
                Text("Saved. Remove the card or replace it with the next copy.").font(.subheadline)
                Button("Scan Next Card", systemImage: "viewfinder") { model.scanNextCard() }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
            } else {
                Text(model.paused ? "Resume when you're ready" : "Hold a card steady inside the camera")
                    .font(.subheadline)
            }
            let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates)
            Text("\(totals.quantity) cards • \(totals.market.money) market").font(.subheadline.bold())
            if totals.unpricedQuantity > 0 {
                Text("\(totals.unpricedQuantity) unpriced • partial total").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                NavigationLink { SessionReviewView(session: session, list: list).toolbar(.visible, for: .navigationBar) } label: {
                    Label("View List", systemImage: "list.bullet").frame(minHeight: 44)
                }
                Spacer()
                if session.isActive { FinishSessionButton(session: session) { model.stop(); dismiss() } }
            }.font(.subheadline)
        }.foregroundStyle(.white).tint(.white).padding(16)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
    }

    private var confirmationReview: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let card = model.selected {
                        if let data = model.result?.capturedImageData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 160)
                                .accessibilityLabel("Captured card")
                        }
                        CardSummaryView(card: card)
                        Picker("Condition", selection: Binding(get: { card.identity.condition }, set: { model.changeCondition($0) })) {
                            ForEach(CatalogOptions.conditions, id: \.self) { Text($0) }
                        }
                        if model.priceLoading { ProgressView("Looking up market value…") }
                        if let message = model.priceMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                        Button("Refresh Market Value") { model.refreshPrice() }.disabled(model.priceLoading)
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

                    }
                }.padding().padding(.top, 8)
            }.navigationTitle("Confirm Card").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        Button("Confirm & Add", systemImage: "checkmark.circle.fill") {
                            model.addSelected(list: list, context: context)
                        }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                            .disabled(!model.confirmed || !session.isActive || model.saving || model.priceLoading)
                        Button("Discard & Scan Again") { model.scanNextCard() }.frame(minHeight: 44)
                    }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
                .failureAlert($model.error)
        }
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
