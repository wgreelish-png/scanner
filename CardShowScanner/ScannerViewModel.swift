import Foundation
import SwiftData
import Observation
import UIKit
import AudioToolbox

/// A settled recognition is a review snapshot. A candidate tap explicitly confirms it.
@MainActor @Observable final class ScannerViewModel {
    var result: ScanResult?
    var selected: CardCandidate?
    var confirmed = false
    var paused = false
    var error: String?
    var session: ScanSession?
    var waitingForRemoval = false
    var selectionInProgress = false
    private var pendingConfirmation: (@MainActor () -> Void)?
    var saving = false
    var priceLoading = false
    var priceMessage: String?
    var priceConnectionRequired = false
    private var candidatePrintings: [String: [String]] = [:]
    private var consumer: Task<Void, Never>?
    private var priceTask: Task<Void, Never>?
    private var printingOptionsTask: Task<Void, Never>?
    private var confirmationDeadline: Task<Void, Never>?
    private let confirmationTimeout: Duration
    private let quickActionCooldown: Duration
    private var quickActionTask: Task<Void, Never>?
    private(set) var quickActionCoolingDown = false
    private var priceRequestID = UUID()
    private var savedRecognitionRef: String?
    private var savedRecognitionEpisode: UUID?
    private var actionList: CardList?
    private struct SavedAddition {
        let receipt: ScannerAddReceipt
        var review: ScanResult?
        let printings: [String: [String]]
    }
    private var additions: [SavedAddition] = []
    private let provider: any ScannerProvider
    private let pricing: any MarketPricing
    // Injection makes a failed transaction/retry testable without corrupting a store.
    private let saveCard: @MainActor (CardCandidate, ScanSession, CardList, ModelContext, String?) throws -> Void
    private let undoCard: @MainActor (ScannerAddReceipt, ScanSession, CardList, ModelContext) throws -> Void
    var label: String { provider.label }
    var liveProvider: TCGTrackingScannerProvider? { provider as? TCGTrackingScannerProvider }
    private var currentAddition: SavedAddition? {
        guard let last = additions.last, let session, let list = actionList,
              SessionService.canUndoScannerAdd(last.receipt, session: session, list: list) else { return nil }
        return last
    }
    var lastAddedCard: CardCandidate? { currentAddition?.receipt.card }
    var canUndoLastAdd: Bool {
        selected == nil && !saving && !selectionInProgress && !quickActionCoolingDown && currentAddition != nil
    }
    var canAddAnotherCopy: Bool { canUndoLastAdd }
    init(provider: (any ScannerProvider)? = nil, pricing: any MarketPricing = StandardMarketPricing(),
         confirmationTimeout: Duration = .seconds(4),
         quickActionCooldown: Duration = .milliseconds(500),
         saveCard: @escaping @MainActor (CardCandidate, ScanSession, CardList, ModelContext, String?) throws -> Void = {
             try SessionService.add($0, session: $1, list: $2, context: $3, recognitionRef: $4)
         }, undoCard: @escaping @MainActor (ScannerAddReceipt, ScanSession, CardList, ModelContext) throws -> Void = {
             try SessionService.undoScannerAdd($0, session: $1, list: $2, context: $3)
         }) {
        self.provider = provider ?? TCGTrackingScannerProvider()
        self.pricing = pricing; self.saveCard = saveCard; self.confirmationTimeout = confirmationTimeout
        self.quickActionCooldown = quickActionCooldown; self.undoCard = undoCard
    }
    func start(game: String, list: CardList, context: ModelContext, session: ScanSession) {
        guard consumer == nil, !paused else { return }
        guard session.isActive, session.listID == list.id, session.game == game else {
            error = BatchFailure.unavailable.localizedDescription; return
        }
        self.session = session; actionList = list
        DiagnosticLog.shared.record("scanner.start", ["provider": liveProvider == nil ? "mock" : "live"])
        if selected == nil { waitingForRemoval = false; savedRecognitionRef = nil; savedRecognitionEpisode = nil }
        Task { [pricing] in await pricing.prepare() }
        provider.start(game: game)
        let stream = provider.results
        consumer = Task { [weak self] in
            for await scan in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(scan)
            }
        }
    }
    func receive(_ scan: ScanResult) {
        guard !paused, !saving, selected == nil else {
            DiagnosticLog.shared.record("recognition.held", sampleEvery: 5); return
        }
        if !scan.visible { waitingForRemoval = false; savedRecognitionRef = nil; savedRecognitionEpisode = nil; return }
        guard !scan.same, let first = scan.candidates.first else { return }
        if waitingForRemoval {
            // The bridge has already settled these full results. A different
            // card uses the normal accepted/tentative gates. After real absence,
            // the normalizer also assigns a new episode even for the same art;
            // its preceding hide can be coalesced by the newest-only stream.
            let changedCard = savedRecognitionRef.map { first.identity.productID != $0 } ?? false
            let newEpisode = savedRecognitionEpisode.map { scan.id != $0 } ?? false
            guard first.confidence >= 50, changedCard || newEpisode else { return }
            waitingForRemoval = false; self.savedRecognitionRef = nil; savedRecognitionEpisode = nil
            DiagnosticLog.shared.record("recognition.next_card", ["reason": changedCard ? "different_match" : "new_episode"])
        }
        result = scan; candidatePrintings = [:]
        var card = first; card.identity.condition = "Near Mint"
        selected = card
        confirmed = !card.requiresPrintingSelection.orFalse
        refreshPrice(forceRefresh: false)
        DiagnosticLog.shared.record("recognition.result", ["episode": scan.id.uuidString, "candidates": String(scan.candidates.count), "accepted": String(scan.accepted), "confidence": String(Int(first.confidence))])
    }
    func stop() {
        if consumer != nil { DiagnosticLog.shared.record("scanner.stop") }
        provider.stop(); consumer?.cancel(); consumer = nil
        // Keep the pending review and price selection across navigation/backgrounding.
    }
    func togglePause(game: String, list: CardList, context: ModelContext, session: ScanSession) {
        paused.toggle()
        if paused { stop() } else { start(game: game, list: list, context: context, session: session) }
    }
    func choose(_ candidate: CardCandidate) {
        guard !selectionInProgress else { return }
        let condition = selected?.identity.condition ?? "Near Mint"
        guard result?.candidates.contains(where: { $0.id == candidate.id }) == true || result == nil else { return }
        selected = candidate; selected?.identity.condition = condition
        confirmed = candidate.requiresPrintingSelection != true
        refreshPrice(forceRefresh: false)
    }
    func selectAndAdd(_ candidate: CardCandidate, list: CardList, context: ModelContext) {
        guard !selectionInProgress, !saving, session?.isActive == true,
              let candidates = result?.candidates,
              let index = candidates.firstIndex(where: { $0.identity.productID == candidate.identity.productID }) else { return }
        let condition = selected?.identity.condition ?? "Near Mint"
        // Printing and a returned SKU change the draft's Identifiable ID. Match
        // its stable product to the frozen result, then keep the user's edits.
        var card = candidates[index]
        if let current = selected, current.identity.productID == candidate.identity.productID { card = current }
        card.identity.condition = condition
        card.requiresPrintingSelection = false
        let alreadyQuoted = !priceLoading && selected?.identity.productID == card.identity.productID &&
            selected?.identity.printing == card.identity.printing && selected?.identity.condition == card.identity.condition
        selected = card; confirmed = true; selectionInProgress = true
        DiagnosticLog.shared.record("recognition.selected", ["candidate_index": String(index)])
        pendingConfirmation = { [weak self] in
            guard let self else { return }
            self.addSelected(list: list, context: context)
            self.selectionInProgress = false
        }
        if alreadyQuoted { finishPendingConfirmation() }
        else {
            refreshPrice(forceRefresh: false)
            let timeout = confirmationTimeout
            confirmationDeadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, !Task.isCancelled, self.pendingConfirmation != nil else { return }
                self.priceTask?.cancel(); self.priceRequestID = UUID(); self.priceLoading = false
                self.selected?.marketPrice = nil; self.selected?.identity.skuID = nil; self.selected?.marketPriceMetadata = nil
                self.priceMessage = "Price unavailable."
                DiagnosticLog.shared.record("pricing.confirmation_timeout")
                self.finishPendingConfirmation()
            }
        }
    }
    private func finishPendingConfirmation() {
        confirmationDeadline?.cancel(); confirmationDeadline = nil
        let confirmation = pendingConfirmation
        pendingConfirmation = nil
        confirmation?()
    }
    func confirmPrinting() { selected?.requiresPrintingSelection = false; confirmed = selected != nil }
    func changePrinting(_ printing: String) {
        guard let selected else { return }
        changePrinting(printing, for: selected)
    }
    func printings(for candidate: CardCandidate) -> [String] {
        let card = selected.flatMap { $0.identity.productID == candidate.identity.productID ? $0 : nil } ?? candidate
        let catalog = candidatePrintings[candidate.identity.productID] ?? []
        return Array(Set((catalog.isEmpty ? card.printings : catalog) + [card.identity.printing])).sorted()
    }
    /// A visible match menu edits that candidate without confirming or saving it.
    /// Printing labels belong to a product; never carry a finish to another match.
    func changePrinting(_ printing: String, for candidate: CardCandidate) {
        guard !selectionInProgress, !saving,
              result == nil || result?.candidates.contains(where: { $0.identity.productID == candidate.identity.productID }) == true else { return }
        var card = selected.flatMap { $0.identity.productID == candidate.identity.productID ? $0 : nil } ?? candidate
        card.printings = printings(for: candidate)
        guard card.printings.contains(printing) || printing == card.identity.printing else { return }
        card.identity.condition = selected?.identity.condition ?? "Near Mint"
        card.identity.printing = printing
        card.identity.skuID = nil; card.marketPrice = nil; card.requiresPrintingSelection = false
        selected = card; confirmed = true; refreshPrice(forceRefresh: false)
    }
    func changeCondition(_ condition: String) {
        guard !selectionInProgress, CatalogOptions.conditions.contains(condition) else { return }
        selected?.identity.condition = condition
        refreshPrice(forceRefresh: false)
    }
    /// A source change keeps the frozen physical card and selections, but the
    /// previous provider's quote and any queued confirmation must be retired.
    func pricingSourceChanged() {
        guard !saving else { return }
        pendingConfirmation = nil; confirmationDeadline?.cancel(); confirmationDeadline = nil
        selectionInProgress = false; candidatePrintings = [:]
        if selected != nil { refreshPrice(forceRefresh: true) }
        else {
            priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
            printingOptionsTask?.cancel(); printingOptionsTask = nil; priceConnectionRequired = false
        }
    }
    func refreshPrice(forceRefresh: Bool = true) {
        printingOptionsTask?.cancel(); printingOptionsTask = nil
        priceTask?.cancel(); priceRequestID = UUID()
        priceConnectionRequired = false
        guard var card = selected else { return }
        // Never retain a quote for a previous printing or condition.
        card.marketPrice = nil; card.identity.skuID = nil; card.marketPriceMetadata = nil; selected = card
        let requestID = priceRequestID
        let requestCard = card
        let frozenCandidates = result?.candidates ?? [requestCard]
        DiagnosticLog.shared.record("pricing.started")
        priceLoading = true; priceMessage = nil
        priceTask = Task { [weak self, pricing] in
            do {
                let details = try await pricing.details(for: requestCard, candidates: frozenCandidates, forceRefresh: forceRefresh)
                guard let self, !Task.isCancelled, self.priceRequestID == requestID, self.selected?.identity == requestCard.identity else { return }
                let quote = details.quote
                let frozenRefs = Set(self.result?.candidates.map { $0.identity.productID } ?? [])
                for (ref, printings) in details.printingsByProduct where frozenRefs.contains(ref) && !printings.isEmpty {
                    self.candidatePrintings[ref] = printings
                }
                if !details.printings.isEmpty { self.selected?.printings = details.printings }
                self.selected?.marketPrice = quote?.marketPrice
                self.selected?.identity.skuID = quote?.skuID
                self.selected?.marketPriceMetadata = quote?.marketPrice == nil ? nil : details.metadata
                self.priceLoading = false
                DiagnosticLog.shared.record("pricing.finished", ["priced": String(quote?.marketPrice != nil),
                    "source": details.metadata?.source.rawValue ?? "unspecified"])
                self.priceMessage = quote?.marketPrice == nil ? "Market value unavailable for this printing and condition." : nil
                self.finishPendingConfirmation()
                if details.metadata?.source == .openAPI {
                    self.prefetchPrintingOptions(for: frozenCandidates, requestID: requestID)
                }
            } catch {
                guard let self, !Task.isCancelled, self.priceRequestID == requestID else { return }
                self.priceLoading = false
                DiagnosticLog.shared.failure("pricing.failed", error)
                self.priceMessage = (error as? MarketPricingFailure)?.errorDescription
                    ?? (error as? OpenAPIPricingFailure)?.errorDescription
                    ?? "Price unavailable. You can still add the card."
                if let failure = error as? MarketPricingFailure, case .accessRejected = failure {
                    self.priceConnectionRequired = true
                }
                self.finishPendingConfirmation()
            }
        }
    }
    /// Other reprints can belong to different sets. Their printing menus load
    /// independently after the selected price so they never delay confirmation.
    private func prefetchPrintingOptions(for candidates: [CardCandidate], requestID: UUID) {
        guard selected != nil, let reviewID = result?.id else { return }
        let missing = candidates.prefix(5).filter {
            $0.identity.productID != selected?.identity.productID && candidatePrintings[$0.identity.productID] == nil
        }
        guard !missing.isEmpty else { return }
        printingOptionsTask = Task { [weak self, pricing] in
            for candidate in missing {
                guard !Task.isCancelled, let self, self.priceRequestID == requestID,
                      self.result?.id == reviewID, self.selected != nil else { return }
                do {
                    let details = try await pricing.details(for: candidate, candidates: [candidate], forceRefresh: false)
                    guard !Task.isCancelled, self.priceRequestID == requestID,
                          self.result?.id == reviewID, self.selected != nil else { return }
                    if !details.printings.isEmpty { self.candidatePrintings[candidate.identity.productID] = details.printings }
                } catch {
                    guard !Task.isCancelled, self.priceRequestID == requestID else { return }
                    DiagnosticLog.shared.record("pricing.printing_options_failed", ["provider": "openapi"])
                }
            }
        }
    }
    /// Visiting the website keeps the physical-card review and invalidates old quotes.
    @discardableResult func suspendForPricingConnection() -> Bool {
        guard !selectionInProgress, !saving else { return false }
        priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
        printingOptionsTask?.cancel(); printingOptionsTask = nil
        selected?.marketPrice = nil; selected?.identity.skuID = nil; selected?.marketPriceMetadata = nil
        stop()
        return true
    }
    func addSelected(list: CardList, context: ModelContext) {
        guard confirmed, !saving, !priceLoading, let selected, let session else { return }
        saving = true
        defer { saving = false }
        let recognitionRef = result?.candidates.first?.identity.productID ?? selected.identity.productID
        let episode = result?.id
        let previousIDs = Set(list.cards.map(\.id)), previousRef = session.lastConsumedRecognitionRef
        let review = result, printingChoices = candidatePrintings
        do {
            try SessionService.withScanSave(session: session, list: list, context: context) {
                try self.saveCard(selected, session, list, context, self.result?.candidates.first?.identity.productID)
            }
            rememberAddition(previousIDs: previousIDs, previousRef: previousRef, list: list,
                             session: session, review: review, printings: printingChoices)
            // Only a committed transaction releases the review snapshot.
            priceTask?.cancel(); priceRequestID = UUID()
            result = nil; candidatePrintings = [:]; self.selected = nil; confirmed = false; priceMessage = nil; priceConnectionRequired = false
            waitingForRemoval = true; savedRecognitionRef = recognitionRef; savedRecognitionEpisode = episode; error = nil
            liveProvider?.releaseReview(recognitionRef: recognitionRef)
            coolDownQuickActions()
            DiagnosticLog.shared.record("add.saved", ["priced": String(selected.marketPrice != nil)])
            if UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if UserDefaults.standard.bool(forKey: "sound") { AudioServicesPlaySystemSound(1104) }
        } catch {
            self.error = "The card was not saved. Your selection is kept; tap your match again to retry."
            DiagnosticLog.shared.failure("persistence.failed", error)
        }
    }
    /// Explicitly confirms one more physical copy using the last committed quote.
    /// It never merges quantities, requotes another condition, or restarts capture.
    func addAnotherCopy(list: CardList, context: ModelContext) {
        guard canAddAnotherCopy, let last = currentAddition, let session,
              last.receipt.listID == list.id else { return }
        saving = true
        defer { saving = false }
        let previousIDs = Set(list.cards.map(\.id)), previousRef = session.lastConsumedRecognitionRef
        do {
            try SessionService.withScanSave(session: session, list: list, context: context) {
                try self.saveCard(last.receipt.card, session, list, context, last.receipt.consumedRecognitionRef)
            }
            rememberAddition(previousIDs: previousIDs, previousRef: previousRef, list: list,
                             session: session, review: nil, printings: [:])
            error = nil; coolDownQuickActions()
            DiagnosticLog.shared.record("add.copy_saved", ["priced": String(last.receipt.card.marketPrice != nil)])
        } catch {
            self.error = "The copy was not saved. Tap Add Another Copy to retry."
            DiagnosticLog.shared.failure("persistence.copy_failed", error)
        }
    }
    /// Undo is available only for this scanner's latest unchanged physical row.
    /// A scanned match reopens for correction; undoing a copy stays camera-ready.
    func undoLastAdd(list: CardList, context: ModelContext) {
        guard canUndoLastAdd, let last = currentAddition, let session,
              last.receipt.listID == list.id else { return }
        saving = true
        defer { saving = false }
        do {
            try undoCard(last.receipt, session, list, context)
            additions.removeLast()
            error = nil; coolDownQuickActions()
            if let review = last.review {
                confirmationDeadline?.cancel(); confirmationDeadline = nil; pendingConfirmation = nil
                priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
                result = review; selected = last.receipt.card; confirmed = true
                candidatePrintings = last.printings
                waitingForRemoval = false; savedRecognitionRef = nil; savedRecognitionEpisode = nil
                priceMessage = nil; priceConnectionRequired = false
                refreshPrice(forceRefresh: false)
            }
            DiagnosticLog.shared.record("add.undone")
        } catch {
            self.error = "The card could not be undone. It is still saved; tap Undo Last Add to retry."
            DiagnosticLog.shared.failure("persistence.undo_failed", error)
        }
    }
    private func rememberAddition(previousIDs: Set<UUID>, previousRef: String?, list: CardList,
                                  session: ScanSession, review: ScanResult?, printings: [String: [String]]) {
        actionList = list
        guard let row = list.orderedCards.last, !previousIDs.contains(row.id), row.quantity == 1 else { return }
        // Keep a small undo history without retaining a JPEG for every scanned card.
        for index in additions.indices { additions[index].review?.capturedImageData = nil }
        additions.append(SavedAddition(receipt: ScannerAddReceipt(item: row, session: session, list: list,
            previousRecognitionRef: previousRef), review: review, printings: printings))
        if additions.count > 20 { additions.removeFirst(additions.count - 20) }
    }
    private func coolDownQuickActions() {
        quickActionTask?.cancel(); quickActionTask = nil
        guard quickActionCooldown > .zero else { quickActionCoolingDown = false; return }
        quickActionCoolingDown = true
        let delay = quickActionCooldown
        quickActionTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.quickActionCoolingDown = false; self.quickActionTask = nil
        }
    }
    func scanNextCard() {
        confirmationDeadline?.cancel(); confirmationDeadline = nil
        pendingConfirmation = nil; selectionInProgress = false
        // Intentional re-arm allows a second identical physical copy without identity merging.
        priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
        printingOptionsTask?.cancel(); printingOptionsTask = nil
        result = nil; candidatePrintings = [:]; selected = nil; confirmed = false; waitingForRemoval = false; savedRecognitionRef = nil; savedRecognitionEpisode = nil; priceMessage = nil; priceConnectionRequired = false; error = nil
        liveProvider?.resetRecognition()
        DiagnosticLog.shared.record("recognition.rearmed")
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
