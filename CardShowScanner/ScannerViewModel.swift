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
    private var confirmationDeadline: Task<Void, Never>?
    private let confirmationTimeout: Duration
    private var priceRequestID = UUID()
    private let provider: any ScannerProvider
    private let pricing: any MarketPricing
    // Injection makes a failed transaction/retry testable without corrupting a store.
    private let saveCard: @MainActor (CardCandidate, ScanSession, CardList, ModelContext, String?) throws -> Void
    var label: String { provider.label }
    var liveProvider: TCGTrackingScannerProvider? { provider as? TCGTrackingScannerProvider }
    init(provider: (any ScannerProvider)? = nil, pricing: any MarketPricing = OnlineMarketPricing(),
         confirmationTimeout: Duration = .seconds(4),
         saveCard: @escaping @MainActor (CardCandidate, ScanSession, CardList, ModelContext, String?) throws -> Void = {
             try SessionService.add($0, session: $1, list: $2, context: $3, recognitionRef: $4)
         }) {
        self.provider = provider ?? TCGTrackingScannerProvider()
        self.pricing = pricing; self.saveCard = saveCard; self.confirmationTimeout = confirmationTimeout
    }
    func start(game: String, list: CardList, context: ModelContext, session: ScanSession) {
        guard consumer == nil, !paused else { return }
        guard session.isActive, session.listID == list.id, session.game == game else {
            error = BatchFailure.unavailable.localizedDescription; return
        }
        self.session = session
        DiagnosticLog.shared.record("scanner.start", ["provider": liveProvider == nil ? "mock" : "live"])
        if selected == nil { waitingForRemoval = false }
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
        if !scan.visible { waitingForRemoval = false; return }
        guard !waitingForRemoval, !scan.same, let first = scan.candidates.first else { return }
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
              result?.candidates.contains(where: { $0.id == candidate.id }) == true else { return }
        let condition = selected?.identity.condition ?? "Near Mint"
        // Keep optional finish edits when confirming that same candidate.
        var card = candidate
        if let current = selected, current.identity.productID == candidate.identity.productID { card = current }
        card.identity.condition = condition
        card.requiresPrintingSelection = false
        let alreadyQuoted = !priceLoading && selected?.identity.productID == card.identity.productID &&
            selected?.identity.printing == card.identity.printing && selected?.identity.condition == card.identity.condition
        selected = card; confirmed = true; selectionInProgress = true
        DiagnosticLog.shared.record("recognition.selected", ["candidate_index": String(result?.candidates.firstIndex(where: { $0.id == candidate.id }) ?? 0)])
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
                self.selected?.marketPrice = nil; self.selected?.identity.skuID = nil
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
    func refreshPrice(forceRefresh: Bool = true) {
        priceTask?.cancel(); priceRequestID = UUID()
        priceConnectionRequired = false
        guard var card = selected else { return }
        // Never retain a quote for a previous printing or condition.
        card.marketPrice = nil; card.identity.skuID = nil; selected = card
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
                self.priceLoading = false
                DiagnosticLog.shared.record("pricing.finished", ["priced": String(quote?.marketPrice != nil)])
                self.priceMessage = quote?.marketPrice == nil ? "Market value unavailable for this printing and condition." : nil
                self.finishPendingConfirmation()
            } catch {
                guard let self, !Task.isCancelled, self.priceRequestID == requestID else { return }
                self.priceLoading = false
                DiagnosticLog.shared.failure("pricing.failed", error)
                self.priceMessage = (error as? MarketPricingFailure)?.errorDescription ?? "Price unavailable. You can still add the card."
                if let failure = error as? MarketPricingFailure, case .accessRejected = failure {
                    self.priceConnectionRequired = true
                }
                self.finishPendingConfirmation()
            }
        }
    }
    /// Visiting the website keeps the physical-card review and invalidates old quotes.
    @discardableResult func suspendForPricingConnection() -> Bool {
        guard !selectionInProgress, !saving else { return false }
        priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
        selected?.marketPrice = nil; selected?.identity.skuID = nil
        stop()
        return true
    }
    func addSelected(list: CardList, context: ModelContext) {
        guard confirmed, !saving, !priceLoading, let selected, let session else { return }
        saving = true
        defer { saving = false }
        do {
            try SessionService.withScanSave(session: session, list: list, context: context) {
                try self.saveCard(selected, session, list, context, self.result?.candidates.first?.identity.productID)
            }
            // Only a committed transaction releases the review snapshot.
            priceTask?.cancel(); priceRequestID = UUID()
            result = nil; candidatePrintings = [:]; self.selected = nil; confirmed = false; priceMessage = nil; priceConnectionRequired = false
            waitingForRemoval = true; error = nil
            liveProvider?.releaseReview()
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
    func scanNextCard() {
        confirmationDeadline?.cancel(); confirmationDeadline = nil
        pendingConfirmation = nil; selectionInProgress = false
        // Intentional re-arm allows a second identical physical copy without identity merging.
        priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
        result = nil; candidatePrintings = [:]; selected = nil; confirmed = false; waitingForRemoval = false; priceMessage = nil; priceConnectionRequired = false; error = nil
        liveProvider?.resetRecognition()
        DiagnosticLog.shared.record("recognition.rearmed")
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
