import SwiftUI
import SwiftData
import UIKit

enum ScannerPurpose { case standard, leftoverStock }

/// Counting needs exact identities and copies, not network market-price work.
struct StockCountPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { nil }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        MarketDetails(quote: nil, printings: card.printings)
    }
}

@MainActor struct LeftoverCountCardsView: View {
    @Bindable var list: CardList
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var error: String?

    private var rows: [InventoryCard] {
        list.orderedCards.reversed().filter {
            search.isEmpty || [$0.snapshot.name, $0.snapshot.set, $0.snapshot.number,
                $0.snapshot.identity.printing, $0.snapshot.identity.condition, $0.snapshot.identity.language]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                Text("\(list.quantity) physical cards counted")
                Text("Review printing, condition, language and copies. This count does not record a purchase, sale or inventory adjustment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                NavigationLink { CardEditorView(item: row) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.snapshot.name).font(.headline)
                        Text([row.snapshot.set, row.snapshot.number].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(row.snapshot.identity.printing) · \(row.snapshot.identity.condition) · \(row.snapshot.identity.language) · Qty \(row.quantity)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.swipeActions {
                    Button("Remove", role: .destructive) {
                        guard !context.hasChanges else { error = "Finish saving your current edits, then remove this counted card."; return }
                        let previousCards = list.cards
                        context.delete(row)
                        do { try context.save() } catch {
                            // The context was clean before this synchronous edit.
                            context.rollback()
                            list.cards = previousCards; row.list = list
                            context.processPendingChanges()
                            self.error = "The counted card could not be removed. Your saved count was kept."
                        }
                    }
                }
            }
        }.navigationTitle("Counted Cards").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search counted cards")
            .scrollDismissesKeyboard(.interactively)
            .failureAlert($error)
    }
}

@MainActor struct ScannerView: View {
    let session: ScanSession
    let list: CardList
    let draft: ScanBatchDraft?
    let purpose: ScannerPurpose
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @AppStorage("steadyCardBorder") private var steadyCardBorder = true
    @AppStorage("scannerDetailsCollapsed") private var detailsCollapsed = false
    @AppStorage("scannerCaptureMode") private var captureMode = ScannerCaptureMode.live
    @AppStorage("scannerTextRecognitionEnabled") private var textRecognitionEnabled = false
    @State private var game: String
    @State private var pendingGame: String?
    @State private var confirmGame = false
    @State private var nextDraft: ScanBatchDraft?
    @State private var model: ScannerViewModel
    @State private var mode = "Live"
    @State private var showingConnection = false
    @State private var returningFromConnection = false
    @State private var showingListReview = false
    @State private var showingManualSearchPrompt = false
    @State private var showingManualSearch = false
    @State private var pendingManualSearchFromReview = false
    @State private var manualSearchTransitionReady = false
    @State private var selectedRecentCard: InventoryCard?
    @State private var manualPromptPolicy = ScannerManualSearchPromptPolicy()
    init(session: ScanSession, list: CardList, draft: ScanBatchDraft? = nil, model: ScannerViewModel? = nil,
         purpose: ScannerPurpose = .standard) {
        self.session = session; self.list = list; self.draft = draft
        let purpose: ScannerPurpose = LeftoverStockStore.shared.active?.countListIDs.contains(list.id) == true ? .leftoverStock : purpose
        self.purpose = purpose
        _game = State(initialValue: session.game ?? "Pokémon")
        let scannerModel = model ?? (purpose == .leftoverStock ? ScannerViewModel(pricing: StockCountPricing()) : ScannerViewModel())
        _model = State(initialValue: scannerModel)
        _mode = State(initialValue: scannerModel.liveProvider == nil ? "Mock" : "Live")
    }
    @State private var visible = false
    private var scannerPricing: any MarketPricing {
        if purpose == .leftoverStock { return StockCountPricing() }
        return StandardMarketPricing()
    }
    private var activityState: DiagnosticActivityState {
        .init(selectedCount: min(5, model.result?.candidates.count ?? 0), isPreparing: model.saving || model.selectionInProgress,
              canProceed: session.isActive && !model.saving && !model.selectionInProgress && !model.quickActionCoolingDown && !model.paused,
              blockReason: !session.isActive || model.paused ? .notActive
                  : (model.saving || model.selectionInProgress ? .saving : (model.quickActionCoolingDown ? .preparing : .ready)),
              cardCount: list.quantity)
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let live = model.liveProvider {
                TCGScannerWebView(provider: live).ignoresSafeArea(.container).ignoresSafeArea(.keyboard)
                    .accessibilityIdentifier("scanner.cameraSurface")
                    .onReceive(live.$manualSearchSuggested) { suggested in
                        guard suggested else { return }
                        // Published sends before its stored value changes. Check
                        // current screen/provider state after that update commits.
                        Task { @MainActor in
                            guard live.manualSearchSuggested else { return }
                            guard visible, session.isActive, !model.paused, model.selected == nil,
                                  !showingListReview, !showingConnection,
                                  !returningFromConnection, !showingManualSearch,
                                  !pendingManualSearchFromReview, selectedRecentCard == nil else {
                                live.resumeAfterManualSearchPrompt(); return
                            }
                            guard manualPromptPolicy.shouldPresent(at: ProcessInfo.processInfo.systemUptime) else {
                                // The bridge has paused this attempt for the
                                // suggestion. Suppression must release it too.
                                live.resumeAfterManualSearchPrompt()
                                DiagnosticLog.shared.record("scanner.manual_search_prompt_suppressed", ["reason": "cooldown"], sampleEvery: 15)
                                return
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
            VStack(spacing: 0) {
                cameraHeader
                Spacer(minLength: 0)
                cameraFooter
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .alert("Search for this card manually?", isPresented: $showingManualSearchPrompt) {
                        Button("Search Manually") { openManualSearch() }
                        Button("Keep Scanning", role: .cancel) {
                            DiagnosticLog.shared.activity(.action, screen: .scanner, action: .continueFlow, state: activityState)
                            manualPromptPolicy.declined(at: ProcessInfo.processInfo.systemUptime)
                            model.liveProvider?.resumeAfterManualSearchPrompt()
                            DiagnosticLog.shared.record("scanner.manual_search_declined")
                        }
                    } message: {
                        Text("No stable match after four seconds. Search the saved catalog to add this card to the same list, or keep scanning.")
                    }
            }
        }
        .ignoresSafeArea(.keyboard)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(false)
        .sheet(isPresented: Binding(get: { model.selected != nil }, set: { _ in }), onDismiss: finishRecognitionReview) {
            confirmationReview
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showingConnection, onDismiss: finishConnection) { connectionView }
        .sheet(isPresented: $showingManualSearch, onDismiss: finishManualSearch) {
            ManualCardSearchView(list: list, game: session.game ?? game, allowsGameChange: false, draft: draft,
                                 focusSearchOnAppear: true,
                                 pricing: scannerPricing)
        }
        .sheet(item: $selectedRecentCard, onDismiss: finishRecentCard) { item in
            NavigationStack { CardEditorView(item: item) }
        }
        .onAppear {
            visible = true
            DiagnosticLog.shared.activity(.screen, screen: .scanner, state: activityState)
            DiagnosticLog.shared.record("navigation.scanner_appeared")
            startIfReady()
        }
        .onDisappear {
            DiagnosticLog.shared.activity(.exit, screen: .scanner, state: activityState)
            visible = false; showingManualSearchPrompt = false; model.stop()
            DiagnosticLog.shared.record("navigation.scanner_disappeared")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfReady() }
            else if phase == .background { showingManualSearchPrompt = false; model.stop() }
        }
        .onChange(of: game) { _, newGame in
            guard purpose == .standard else { game = session.game ?? "Pokémon"; return }
            guard newGame != session.game else { return }
            pendingGame = newGame; game = session.game ?? "Pokémon"; confirmGame = true
        }
        .onChange(of: session.isActive) { _, active in if !active { model.stop() } }
        .onChange(of: activityState) { _, state in
            guard visible, !showingManualSearch, !showingListReview, selectedRecentCard == nil else { return }
            DiagnosticLog.shared.activity(.state, screen: model.selected == nil ? .scanner : .scanReview, state: state)
        }
        .confirmationDialog("Start a new scan for another game?", isPresented: $confirmGame) {
            Button("Start New Scan") {
                guard let pendingGame else { return }
                do {
                    let next = try SessionService.prepareDraft(game: pendingGame)
                    model.stop(); nextDraft = next
                } catch { model.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { pendingGame = nil }
        } message: { Text("Saved cards and offers will be kept. The new list is saved when you confirm its first card.") }
        .navigationDestination(item: $nextDraft) { draft in
            DraftScannerDestination(draft: draft)
        }
        .onChange(of: nextDraft?.session.listID) { previous, current in
            if previous != nil && current == nil && nextDraft?.isCommitted == true { nextDraft = nil }
        }
        .navigationDestination(isPresented: $showingListReview) {
            if purpose == .leftoverStock {
                LeftoverCountCardsView(list: list)
                    .toolbar(.visible, for: .navigationBar)
            } else {
                SessionReviewView(session: session, list: list, onContinueScanning: {
                    model.paused = false
                    showingListReview = false
                }).toolbar(.visible, for: .navigationBar)
                    .toolbar(.visible, for: .tabBar)
            }
        }
        .onChange(of: showingListReview) { _, showing in
            if !showing { startIfReady() }
        }
        .onChange(of: mode) { _, _ in restart() }
        .onChange(of: captureMode) { _, selection in
            if let live = model.liveProvider, !live.setCaptureMode(selection) { captureMode = live.captureMode }
        }
        .onChange(of: textRecognitionEnabled) { _, enabled in model.liveProvider?.setTextRecognitionEnabled(enabled) }
        .onChange(of: steadyCardBorder) { _, enabled in model.liveProvider?.setSteadyCardBorder(enabled) }
        .failureAlert(Binding(get: { model.selected == nil ? model.error : nil }, set: { model.error = $0 }))
    }
    private var cameraHeader: some View {
        HStack(spacing: 4) {
                Button {
                    DiagnosticLog.shared.activity(.action, screen: .scanner, action: .close, state: activityState)
                    model.stop(); dismiss()
                } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel("Close scanner").accessibilityIdentifier("scanner.close")
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.game ?? game).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("scanner.game")
                    HStack(spacing: 5) {
                        Circle().fill(model.paused ? Color.secondary : (mode == "Live" ? .green : .orange))
                            .frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(model.paused ? "Paused" : (mode == "Live" ? (captureMode == .photo ? "Photo Scan" : "Live Scan") : "Mock · testing"))
                            .font(.caption2.weight(.semibold)).fixedSize()
                            .accessibilityIdentifier("scanner.mode")
                        if !model.paused, let live = model.liveProvider {
                            ScannerCompactCameraStatus(provider: live)
                        }
                    }.foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    DiagnosticLog.shared.activity(.action, screen: .scanner,
                        action: model.paused ? .resumeScanner : .pauseScanner, state: activityState)
                    model.paused.toggle()
                    if model.paused { model.stop() } else { startIfReady() }
                } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(model.paused ? "Resume camera" : "Pause camera")
                    .accessibilityIdentifier("scanner.pause")
                Menu {
                    if let live = model.liveProvider {
                        ScannerCaptureModeMenu(provider: live, selection: $captureMode,
                            blocked: model.selected != nil || model.selectionInProgress || model.saving || model.paused)
                        Toggle("Text Recognition Fallback", isOn: $textRecognitionEnabled)
                            .accessibilityIdentifier("scanner.textRecognitionOption")
                            .accessibilityHint("Reads card text once after a photo has no match. Live Scan offers Read Card Text.")
                    }
                    if purpose == .standard {
                        Picker("Game", selection: $game) { ForEach(CatalogOptions.games(including: game), id: \.self) { Text($0) } }
                    }
                    Button("Retry Live Scanner") {
                        model.stop(); model.paused = false
                        startIfReady()
                    }.disabled(model.liveProvider == nil)
                    Button("Reset Card Recognition", systemImage: "arrow.clockwise") {
                        DiagnosticLog.shared.activity(.action, screen: .scanner, action: .resetRecognition, state: activityState)
                        model.scanNextCard()
                    }
                        .disabled(model.selectionInProgress || model.saving || captureMode == .photo)
                        .accessibilityIdentifier("scanner.resetRecognition")
                    Button("TCGTracking Account", systemImage: "person.crop.circle") {
                        openConnection()
                    }.disabled(model.liveProvider == nil || model.selectionInProgress || model.saving)
                    Button("Check Database Updates", systemImage: "arrow.down.circle") {
                        model.liveProvider?.refreshDatabase()
                    }.disabled(model.liveProvider == nil || model.paused || model.selected != nil)
                    Toggle("Steady Card Border", isOn: $steadyCardBorder)
                        .disabled(captureMode == .photo || model.liveProvider == nil || model.selected != nil || model.selectionInProgress || model.saving)
                        .accessibilityHint("Briefly retries a recently matched card border after small movements.")
                    scanIssueMenu
                    Menu("Developer Testing") {
                        Picker("Scanner source", selection: $mode) {
                            Text("Live Camera").tag("Live")
                            Text("Mock — sample cards").tag("Mock")
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("Scanner options")
                    .accessibilityIdentifier("scanner.options")
        }.foregroundStyle(.primary).tint(.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, ignoresSafeAreaEdges: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scanner.header")
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
        let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates)
        return VStack(spacing: detailsCollapsed ? 6 : 10) {
            if textRecognitionEnabled, let live = model.liveProvider {
                ScannerTextRecognitionControls(provider: live,
                    enabled: session.isActive && !model.paused && model.selected == nil && !model.saving && !model.selectionInProgress)
            }
            if captureMode == .photo, let live = model.liveProvider {
                ScannerPhotoCaptureControls(provider: live,
                    enabled: session.isActive && !model.paused && model.selected == nil && !model.saving && !model.selectionInProgress,
                    onRetry: {
                        model.stop(); live.preparePhotoRetry(); model.paused = false; startIfReady()
                    })
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(purpose == .leftoverStock ? "\(list.quantity) cards counted" : totals.quantity > 0 && totals.unpricedQuantity == totals.quantity
                         ? "\(totals.quantity) cards • unpriced"
                         : "\(totals.quantity) cards • \(totals.market.money) \(totals.unpricedQuantity > 0 ? "known" : "market")")
                        .font(.subheadline.bold())
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("scanner.totals")
                    if purpose == .standard && totals.unpricedQuantity > 0 {
                        Text(totals.unpricedQuantity == totals.quantity ? "Market prices unavailable" : "\(totals.unpricedQuantity) unpriced • partial total")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("scanner.unpriced")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { detailsCollapsed.toggle() }
                } label: {
                    Image(systemName: detailsCollapsed ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel(detailsCollapsed ? "Show scanned cards" : "Hide scanned cards")
                    .accessibilityValue(detailsCollapsed ? "Collapsed" : "Expanded")
                    .accessibilityHint("Card totals and scan actions stay visible.")
                    .accessibilityIdentifier("scanner.detailsToggle")
            }
            if !detailsCollapsed {
                ScannerRecentCards(list: list, onSelect: openRecentCard)
                    .disabled(model.selectionInProgress || model.saving || model.selected != nil || !session.isActive)
                    .layoutPriority(-1)
            }
            if model.lastAddedCard != nil { scannerQuickActions }
            footerNavigationActions
        }.foregroundStyle(.white).tint(.white).padding(detailsCollapsed ? 12 : 16)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
    }

    private var footerNavigationActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            Button("Search", systemImage: "magnifyingglass") { openManualSearch() }
                .buttonStyle(.borderless).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Search Manually")
                .accessibilityIdentifier("scanner.manualSearch")
            Button {
                guard !showingListReview else { return }
                DiagnosticLog.shared.activity(.action, screen: .scanner, action: .openList, state: activityState)
                // Stop before navigation begins, and keep scene callbacks
                // from restarting this scanner beneath the review screen.
                model.stop(); showingListReview = true
                DiagnosticLog.shared.record("navigation.review_opened", ["phase": "scanner"])
            } label: {
                Label(purpose == .leftoverStock ? "Review Count" : "List", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderless).accessibilityLabel(purpose == .leftoverStock ? "Review Count" : "View List").accessibilityIdentifier("scanner.viewList")
                .disabled(draft?.isCommitted == false)
            if draft?.isCommitted == false {
                Button("Close", systemImage: "xmark") {
                    DiagnosticLog.shared.activity(.action, screen: .scanner, action: .close, state: activityState)
                    model.stop(); dismiss()
                }
                    .frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Close Scan")
                    .accessibilityIdentifier("scanner.finishSession")
            } else if session.isActive {
                FinishSessionButton(session: session, title: purpose == .leftoverStock ? "Finish Count" : "Finish") {
                    DiagnosticLog.shared.activity(.outcome, screen: .scanner, action: .finishSession, state: activityState)
                    model.stop(); dismiss()
                }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("scanner.finishSession")
            }
        }.font(.subheadline)
    }

    private var scannerQuickActions: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                DiagnosticLog.shared.activity(.action, screen: .scanner, action: .undoAdd, state: activityState)
                model.undoLastAdd(list: list, context: context)
            } label: {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "arrow.uturn.backward").frame(minWidth: 44, minHeight: 44)
                } else {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            }.buttonStyle(.bordered).frame(minHeight: 44)
                .disabled(!model.canUndoLastAdd)
                .accessibilityLabel("Undo Last Add")
                .accessibilityIdentifier("scanner.undoLastAdd")
            Button {
                DiagnosticLog.shared.activity(.action, screen: .scanner, action: .addCopy, state: activityState)
                model.addAnotherCopy(list: list, context: context)
            } label: {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "plus.square.on.square").frame(minWidth: 44, minHeight: 44)
                } else {
                    Label("Another Copy", systemImage: "plus.square.on.square")
                }
            }.buttonStyle(.borderedProminent).tint(.blue).frame(minHeight: 44)
                .disabled(!model.canAddAnotherCopy)
                .accessibilityLabel("Add Another Copy")
                .accessibilityIdentifier("scanner.addAnotherCopy")
        }.font(.subheadline)
    }

    private var confirmationReview: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let card = model.selected {
                        if model.result?.source == .text {
                            Label("Found from card text. Check the name, number, printing and condition before adding.", systemImage: "text.viewfinder")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("scanReview.textSource")
                        }
                        if let data = model.result?.capturedImageData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 100)
                                .accessibilityLabel("Captured card")
                        }
                        if let metadata = card.marketPriceMetadata {
                            Text(metadata.summary).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("scanReview.priceMetadata")
                        }
                        Text(captureMode == .photo
                             ? "Tap the correct match to add it. The camera stays off until your next photo."
                             : "Tap the correct match to add it, then scan the next card.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let message = model.priceMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Button("Retry Market Price") {
                                DiagnosticLog.shared.activity(.action, screen: .scanReview, action: .retryPrice, state: activityState)
                                model.refreshPrice()
                            }.disabled(model.priceLoading || model.selectionInProgress)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 16) {
                            ForEach(Array((model.result?.candidates ?? []).prefix(5))) { candidate in
                                let draft = card.identity.productID == candidate.identity.productID ? card : candidate
                                VStack(alignment: .leading, spacing: 8) {
                                    ScanReviewDropdown(title: "Type / printing", value: draft.identity.printing,
                                        options: model.printings(for: candidate),
                                        accessibilityID: "scanReview.printing." + candidate.identity.productID,
                                        accessibilityContext: candidate.name,
                                        onChange: {
                                            DiagnosticLog.shared.activity(.action, screen: .scanReview, action: .changePrinting, state: activityState)
                                            model.changePrinting($0, for: candidate)
                                        })
                                    Button {
                                        DiagnosticLog.shared.activity(.action, screen: .scanReview, action: .addCard, state: activityState)
                                        model.selectAndAdd(candidate, list: list, context: context)
                                    } label: {
                                        CandidateMatchTile(candidate: candidate, selected: card, priceLoading: model.priceLoading)
                                    }.buttonStyle(.plain)
                                        .accessibilityIdentifier("scanReview.add." + candidate.identity.productID)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityHint("Adds this match using its displayed printing and condition. Use the dropdowns to change them first.")
                                }.disabled(model.selectionInProgress || model.saving || model.quickActionCoolingDown || !session.isActive)
                            }
                        }
                        if model.priceLoading && !model.selectionInProgress { ProgressView("Checking market value…") }
                        NavigationLink {
                            CardResearchView(card: card)
                        } label: {
                            Label("Market & Graded Research", systemImage: "magnifyingglass")
                        }.disabled(model.selectionInProgress || model.saving)
                            .accessibilityIdentifier("scanReview.marketDetails")
                    }
                }.padding().padding(.top, 8)
            }.navigationTitle("Choose the Card").navigationBarTitleDisplayMode(.inline)
                .onAppear { DiagnosticLog.shared.activity(.screen, screen: .scanReview, state: activityState) }
                .onDisappear { DiagnosticLog.shared.activity(.exit, screen: .scanReview, state: activityState) }
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { scanIssueMenu }
                }
                .safeAreaInset(edge: .top) {
                    if let card = model.selected {
                        VStack(alignment: .leading, spacing: 6) {
                            ScanReviewDropdown(title: "Condition", value: card.identity.condition, options: CatalogOptions.conditions,
                                accessibilityID: "scanReview.condition", onChange: {
                                    DiagnosticLog.shared.activity(.action, screen: .scanReview, action: .changeCondition, state: activityState)
                                    model.changeCondition($0)
                                })
                                .disabled(model.selectionInProgress || model.saving || model.quickActionCoolingDown || !session.isActive)
                            Text("Applies to the card you add. Each new scan starts at Near Mint.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal).padding(.vertical, 8).frame(maxWidth: .infinity)
                            .background(.regularMaterial)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if model.selectionInProgress { ProgressView("Adding your card…") }
                        Button("Search Manually", systemImage: "magnifyingglass") { openManualSearchFromReview() }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(model.selectionInProgress || model.saving || !session.isActive)
                            .accessibilityIdentifier("scanReview.manualSearch")
                        Button(captureMode == .photo ? "Discard Photo" : "Discard & Scan Again") {
                            DiagnosticLog.shared.activity(.action, screen: .scanReview, action: .resetRecognition, state: activityState)
                            model.scanNextCard()
                        }.frame(minHeight: 44)
                            .disabled(model.selectionInProgress || model.saving || !session.isActive)
                    }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
                .failureAlert($model.error)
        }
    }

    private var connectionView: some View {
        TCGTrackingConnectionView(continueTitle: "Return to Scanner") {
            guard !returningFromConnection, showingConnection else { return }
            returningFromConnection = true
            // The presenting binding owns dismissal. Updating setup state must
            // not invalidate a child environment dismiss action mid-tap.
            showingConnection = false
            DiagnosticLog.shared.record("connection.continued", ["phase": "scanner"])
        }
    }
    private func openConnection() {
        guard !returningFromConnection, !showingConnection,
              model.suspendForPricingConnection() else { return }
        showingConnection = true
        DiagnosticLog.shared.activity(.action, screen: .scanner, action: .openConnection, state: activityState)
        DiagnosticLog.shared.record("connection.opened", ["phase": "scanner"])
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
              !showingManualSearch, !pendingManualSearchFromReview, selectedRecentCard == nil,
              model.suspendForManualSearch() else { return }
        showingManualSearchPrompt = false
        showingManualSearch = true
        DiagnosticLog.shared.activity(.action, screen: .scanner, action: .openManualSearch, state: activityState)
        DiagnosticLog.shared.record("scanner.manual_search_opened")
    }
    private func openManualSearchFromReview() {
        guard session.isActive, !showingManualSearch, !pendingManualSearchFromReview,
              model.suspendForManualSearch(discardSelection: true) else { return }
        showingManualSearchPrompt = false
        DiagnosticLog.shared.activity(.action, screen: .scanReview, action: .openManualSearch, state: activityState)
        // Clearing the held result dismisses its sheet. Present the catalog only
        // after that dismissal finishes, with recognition still suspended.
        pendingManualSearchFromReview = true
        manualSearchTransitionReady = false
    }
    private func finishRecognitionReview() {
        if visible { DiagnosticLog.shared.activity(.screen, screen: .scanner, state: activityState) }
        guard pendingManualSearchFromReview else { return }
        manualSearchTransitionReady = true
        startIfReady()
    }
    private func finishManualSearch() {
        if visible { DiagnosticLog.shared.activity(.screen, screen: .scanner, state: activityState) }
        startIfReady()
    }
    private func openRecentCard(_ item: InventoryCard) {
        guard session.isActive, selectedRecentCard == nil, !showingManualSearch,
              !pendingManualSearchFromReview, model.suspendForManualSearch() else { return }
        DiagnosticLog.shared.activity(.action, screen: .scanner, action: .openCard, state: activityState)
        selectedRecentCard = item
    }
    private func finishRecentCard() {
        if visible { DiagnosticLog.shared.activity(.screen, screen: .scanner, state: activityState) }
        startIfReady()
    }
    private func startIfReady() {
        if pendingManualSearchFromReview, manualSearchTransitionReady,
           visible, session.isActive, scenePhase == .active, !model.paused,
           !showingConnection, !returningFromConnection, !showingListReview, selectedRecentCard == nil {
            pendingManualSearchFromReview = false
            manualSearchTransitionReady = false
            showingManualSearch = true
            DiagnosticLog.shared.record("scanner.manual_search_opened")
            return
        }
        guard visible, scenePhase == .active, session.isActive, !showingConnection, !showingListReview,
              !returningFromConnection, !showingManualSearchPrompt, !showingManualSearch,
              !pendingManualSearchFromReview, selectedRecentCard == nil else { return }
        model.resumeAfterManualSearch()
        guard !model.paused else { return }
        model.liveProvider?.setCaptureMode(captureMode)
        model.liveProvider?.setTextRecognitionEnabled(textRecognitionEnabled)
        model.start(game: session.game ?? game, list: list, context: context, session: session, draft: draft)
    }

    private func restart() {
        model.stop()
        let provider: any ScannerProvider
        if mode == "Live" { provider = TCGTrackingScannerProvider() } else { provider = MockScannerProvider() }
        model = ScannerViewModel(provider: provider)
        startIfReady()
    }
}

private struct ScannerCompactCameraStatus: View {
    @ObservedObject var provider: TCGTrackingScannerProvider
    var body: some View {
        Text(provider.status).font(.caption2).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("scanner.cameraStatus")
    }
}

/// Reversing scan-order metadata affects display only; saved row order is kept.
private struct ScannerRecentCards: View {
    let list: CardList
    let onSelect: (InventoryCard) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let cards = Array(list.orderedCards.reversed())
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scanned cards").font(.caption.weight(.semibold))
                Spacer()
                Text("Newest first").font(.caption2)
            }.foregroundStyle(.white.opacity(0.8))
            if cards.isEmpty {
                Text("Cards you add appear here. Tap a card to review or edit it.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .accessibilityIdentifier("scanner.recentCards.empty")
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(cards) { item in
                                Button { onSelect(item) } label: {
                                    ScannerRecentCardRow(item: item, newest: item.id == cards.first?.id)
                                }.buttonStyle(.plain).id(item.id)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityHint("Review or edit this scanned card.")
                                    .accessibilityIdentifier("scanner.recentCard." + item.id.uuidString)
                                if item.id != cards.last?.id { Divider().overlay(.white.opacity(0.15)) }
                            }
                        }
                    }
                    .onChange(of: cards.first?.id) { _, id in
                        if let id { reader.scrollTo(id, anchor: .top) }
                    }
                }
                .frame(minHeight: 0, maxHeight: dynamicTypeSize.isAccessibilitySize ? 220 : 190)
                .layoutPriority(-1)
                .accessibilityIdentifier("scanner.recentCards")
            }
        }
    }
}

private struct ScannerRecentCardRow: View {
    let item: InventoryCard
    let newest: Bool

    var body: some View {
        let card = item.snapshot
        HStack(spacing: 10) {
            AsyncImage(url: card.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { Image(systemName: "rectangle.portrait").foregroundStyle(.white.opacity(0.7)) }
            }.frame(width: 32, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .accessibilityIdentifier(newest ? "scanner.lastAdded" : "scanner.recentName." + item.id.uuidString)
                Text([card.set, card.number].filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.caption2).lineLimit(1).foregroundStyle(.white.opacity(0.75))
                Text("\(card.identity.printing) • \(card.identity.condition) • Qty \(item.quantity)")
                    .font(.caption2).lineLimit(1).foregroundStyle(.white.opacity(0.75))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(card.marketPrice?.money ?? "Unpriced").font(.subheadline.weight(.semibold)).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.65))
        }.frame(minHeight: 68).contentShape(Rectangle())
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
