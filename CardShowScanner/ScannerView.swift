import SwiftUI
import SwiftData
import UIKit

struct ScannerView: View {
    let session: ScanSession
    let list: CardList
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tcgTrackingConnectionIntroduced") private var connectionIntroduced = false
    @Query private var sessions: [ScanSession]
    @State private var game: String
    @State private var pendingGame: String?
    @State private var confirmGame = false
    @State private var nextSessionID: UUID?
    @State private var model = ScannerViewModel()
    @State private var mode = "Live"
    @State private var showingConnection = false
    @State private var showingReviewConnection = false
    @State private var returningFromConnection = false
    @State private var acknowledgedConnectionInView = false
    @State private var showingListReview = false
    @State private var showingManualSearchPrompt = false
    @State private var showingManualSearch = false
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
                    .onReceive(live.$manualSearchSuggested) { suggested in
                        guard suggested else { return }
                        // Published sends before its stored value changes. Check
                        // current screen/provider state after that update commits.
                        Task { @MainActor in
                            guard live.manualSearchSuggested else { return }
                            guard visible, session.isActive, !model.paused, model.selected == nil,
                                  !showingListReview, !showingConnection, !showingReviewConnection,
                                  !returningFromConnection, !showingManualSearch else {
                                live.resumeAfterManualSearchPrompt(); return
                            }
                            showingManualSearchPrompt = true
                        }
                    }
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
                    .alert("Search for this card manually?", isPresented: $showingManualSearchPrompt) {
                        Button("Search Manually") { openManualSearch() }
                        Button("Keep Scanning", role: .cancel) {
                            model.liveProvider?.resumeAfterManualSearchPrompt()
                            DiagnosticLog.shared.record("scanner.manual_search_declined")
                        }
                    } message: {
                        Text("No stable match after four seconds. Search the saved catalog to add this card to the same list, or keep scanning.")
                    }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .sheet(isPresented: Binding(get: { model.selected != nil }, set: { _ in })) {
            confirmationReview
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showingConnection, onDismiss: finishConnection) { connectionView(inReview: false) }
        .sheet(isPresented: $showingManualSearch, onDismiss: { startIfReady() }) {
            ManualCardSearchView(list: list, game: session.game ?? game, allowsGameChange: false)
        }
        .onAppear {
            visible = true
            DiagnosticLog.shared.record("navigation.scanner_appeared")
            startIfReady()
        }
        .onDisappear {
            visible = false; showingManualSearchPrompt = false; model.stop()
            DiagnosticLog.shared.record("navigation.scanner_disappeared")
        }
        .onChange(of: scenePhase) { _, phase in
            DiagnosticLog.shared.record("app.scene", ["phase": phase == .active ? "active" : (phase == .background ? "background" : "inactive")])
            if phase == .active { startIfReady() }
            else if phase == .background { showingManualSearchPrompt = false; model.stop() }
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
        .navigationDestination(isPresented: $showingListReview) {
            SessionReviewView(session: session, list: list, onContinueScanning: {
                model.paused = false
                showingListReview = false
            }).toolbar(.visible, for: .navigationBar)
        }
        .onChange(of: showingListReview) { _, showing in
            if !showing { startIfReady() }
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
                    model.paused.toggle()
                    if model.paused { model.stop() } else { startIfReady() }
                } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(model.paused ? "Resume camera" : "Pause camera")
                Menu {
                    Picker("Game", selection: $game) { ForEach(CatalogOptions.games, id: \.self) { Text($0) } }
                    Button("Retry Live Scanner") {
                        model.stop(); model.paused = false
                        startIfReady()
                    }.disabled(model.liveProvider == nil)
                    Button("Connect TCGTracking", systemImage: "person.crop.circle") {
                        openConnection()
                    }.disabled(model.liveProvider == nil || model.selectionInProgress || model.saving)
                    Button("Check Database Updates", systemImage: "arrow.down.circle") {
                        model.liveProvider?.refreshDatabase()
                    }.disabled(model.liveProvider == nil || model.paused || model.selected != nil)
                    scanIssueMenu
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

    private var scanIssueMenu: some View {
        Menu {
            ForEach(ScannerIssueKind.allCases, id: \.rawValue) { issue in
                Button(issue.label) { model.liveProvider?.markScanIssue(issue) }
            }
        } label: { Label("Mark Scan Issue", systemImage: "flag") }
            .disabled(model.liveProvider == nil || model.paused || model.selectionInProgress || model.saving)
    }

    private var cameraFooter: some View {
        VStack(spacing: 10) {
            if model.waitingForRemoval {
                Text("Saved. Remove this card, then present the next one.").font(.subheadline)
                Button("Scan Next Card", systemImage: "viewfinder") { model.scanNextCard() }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
            } else {
                Text(model.paused ? "Resume when you're ready" : "Hold a card steady inside the camera")
                    .font(.subheadline)
                if !model.paused {
                    Text("Tilt slightly to reduce glare. Use a light, plain background for dark borders.")
                        .font(.caption).multilineTextAlignment(.center)
                    Button("Search Manually", systemImage: "magnifyingglass") { openManualSearch() }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                        .accessibilityIdentifier("scanner.manualSearch")
                }
            }
            let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates)
            Text("\(totals.quantity) cards • \(totals.market.money) market").font(.subheadline.bold())
            if totals.unpricedQuantity > 0 {
                Text("\(totals.unpricedQuantity) unpriced • partial total").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    guard !showingListReview else { return }
                    // Stop before navigation begins, and keep scene callbacks
                    // from restarting this scanner beneath the review screen.
                    model.stop(); showingListReview = true
                    DiagnosticLog.shared.record("navigation.review_opened", ["phase": "scanner"])
                } label: {
                    Label("View List", systemImage: "list.bullet").frame(minHeight: 44)
                }.buttonStyle(.borderless)
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
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 100)
                                .accessibilityLabel("Captured card")
                        }
                        Text("Tap the correct match to add it, then scan the next card.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ScanReviewDropdown(title: "Condition", value: card.identity.condition, options: CatalogOptions.conditions,
                            accessibilityID: "scanReview.condition", onChange: { model.changeCondition($0) })
                            .disabled(model.selectionInProgress || model.saving || !session.isActive)
                        Text("Condition applies to the card you add. Every new scan starts at Near Mint.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = model.priceMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            if model.priceConnectionRequired && model.liveProvider != nil {
                                Button("Connect TCGTracking", systemImage: "person.crop.circle") {
                                    openConnection(inReview: true)
                                }.disabled(model.selectionInProgress || model.saving)
                            }
                            Button("Retry Market Price") { model.refreshPrice() }.disabled(model.priceLoading || model.selectionInProgress)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 16) {
                            ForEach(Array((model.result?.candidates ?? []).prefix(5))) { candidate in
                                let draft = card.identity.productID == candidate.identity.productID ? card : candidate
                                VStack(alignment: .leading, spacing: 8) {
                                    Button { model.selectAndAdd(candidate, list: list, context: context) } label: {
                                        CandidateMatchTile(candidate: candidate, selected: card, priceLoading: model.priceLoading)
                                    }.buttonStyle(.plain)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityHint("Adds this match using its displayed printing and condition. Use the dropdowns to change them first.")
                                    ScanReviewDropdown(title: "Type / printing", value: draft.identity.printing,
                                        options: model.printings(for: candidate),
                                        accessibilityID: "scanReview.printing." + candidate.identity.productID,
                                        accessibilityContext: candidate.name,
                                        onChange: { model.changePrinting($0, for: candidate) })
                                }.disabled(model.selectionInProgress || model.saving || !session.isActive)
                            }
                        }
                        if model.priceLoading && !model.selectionInProgress { ProgressView("Checking market value…") }


                    }
                }.padding().padding(.top, 8)
            }.navigationTitle("Choose the Card").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { scanIssueMenu }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if model.selectionInProgress { ProgressView("Adding your card…") }
                        Button("Discard & Scan Again") { model.scanNextCard() }.frame(minHeight: 44)
                    }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
                .failureAlert($model.error)
                .fullScreenCover(isPresented: $showingReviewConnection, onDismiss: finishConnection) { connectionView(inReview: true) }
        }
    }

    private func connectionView(inReview: Bool) -> some View {
        TCGTrackingConnectionView(continueTitle: connectionIntroduced ? "Return to Scanner" : "Continue to Scanner") {
            guard !returningFromConnection,
                  inReview ? showingReviewConnection : showingConnection else { return }
            returningFromConnection = true
            // This records an explicit setup choice, never authentication success.
            acknowledgedConnectionInView = true
            connectionIntroduced = true
            OnlineMarketPricing.connectionDidChange()
            // The presenting binding owns dismissal. Updating setup state must
            // not invalidate a child environment dismiss action mid-tap.
            if inReview { showingReviewConnection = false } else { showingConnection = false }
            DiagnosticLog.shared.record("connection.continued", ["phase": inReview ? "review" : "scanner"])
        }
    }
    private func openConnection(inReview: Bool = false) {
        guard !returningFromConnection, !showingConnection, !showingReviewConnection,
              model.suspendForPricingConnection() else { return }
        if inReview { showingReviewConnection = true } else { showingConnection = true }
        DiagnosticLog.shared.record("connection.opened", ["phase": inReview ? "review" : "scanner"])
    }
    private func finishConnection() {
        returningFromConnection = false
        DiagnosticLog.shared.record("connection.closed")
        guard session.isActive else { return }
        if model.selected != nil { model.refreshPrice() }
        startIfReady()
    }
    private func openManualSearch() {
        guard session.isActive, model.selected == nil, !model.selectionInProgress, !model.saving,
              !showingManualSearch else { return }
        showingManualSearchPrompt = false
        // Stop before presenting so camera results cannot interrupt catalog entry.
        showingManualSearch = true; model.stop()
        DiagnosticLog.shared.record("scanner.manual_search_opened")
    }
    private func startIfReady() {
        guard visible, session.isActive, !model.paused, !showingConnection, !showingReviewConnection, !showingListReview,
              !returningFromConnection, !showingManualSearchPrompt, !showingManualSearch else { return }
        if model.liveProvider != nil && !connectionIntroduced && !acknowledgedConnectionInView { openConnection(); return }
        model.start(game: session.game ?? game, list: list, context: context, session: session)
    }

    private func restart() {
        model.stop()
        let provider: any ScannerProvider
        if mode == "Live" { provider = TCGTrackingScannerProvider() } else { provider = MockScannerProvider() }
        model = ScannerViewModel(provider: provider)
        startIfReady()
    }
}

/// A separate menu button keeps opening an option from confirming the card.
private struct ScanReviewDropdown: View {
    let title: String
    let value: String
    let options: [String]
    let accessibilityID: String
    var accessibilityContext: String? = nil
    let onChange: (String) -> Void
    var body: some View {
        Menu {
            Picker(title, selection: Binding(get: { value }, set: onChange)) {
                ForEach(options, id: \.self) { Text($0) }
            }.pickerStyle(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption.bold())
                }
                Text(value).font(.subheadline.bold()).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.borderless)
            .accessibilityLabel(accessibilityContext.map { title + " for " + $0 } ?? title)
            .accessibilityValue(value).accessibilityIdentifier(accessibilityID)
    }
}

/// Full artwork at the available column width; metadata stays readable below it.
struct CandidateMatchTile: View {
    let candidate: CardCandidate
    let selected: CardCandidate
    let priceLoading: Bool
    private var isSelected: Bool { candidate.identity.productID == selected.identity.productID }
    private var artworkURL: URL? {
        guard let url = candidate.imageURL, url.scheme == "https", url.host == "cdn.tcgtracking.com", url.query == nil,
              url.path.range(of: #"^/product/[0-9]+_200w\.jpg$"#, options: .regularExpression) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return candidate.imageURL }
        // The public detail response supplies this 400px format for full artwork.
        components.path = url.path.replacingOccurrences(of: "_200w.jpg", with: "_400w.jpg")
        return components.url ?? url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.secondary.opacity(0.08)
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { Image(systemName: "rectangle.portrait").font(.largeTitle).foregroundStyle(.secondary) }
                }.padding(4)
            }.aspectRatio(5.0 / 7.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            Text(candidate.name).font(.headline).foregroundStyle(.primary)
            Text("\(candidate.set) • \(candidate.number)").font(.caption).foregroundStyle(.secondary)
            Text("\(isSelected ? selected.identity.printing : candidate.identity.printing) • \(selected.identity.condition)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                if isSelected {
                    Text(priceLoading ? "Checking market value…" : (selected.marketPrice?.money ?? "Price unavailable"))
                        .font(.caption.bold()).foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(.secondary.opacity(0.25), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
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
