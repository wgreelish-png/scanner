import Foundation
import SwiftData
import Observation
import UIKit
import AudioToolbox

/// The first complete recognition is a review snapshot. Frames cannot mutate it.
@MainActor @Observable final class ScannerViewModel {
    var result: ScanResult?
    var selected: CardCandidate?
    var confirmed = false
    var paused = false
    var error: String?
    var session: ScanSession?
    var waitingForRemoval = false
    var saving = false
    var priceLoading = false
    var priceMessage: String?
    private var consumer: Task<Void, Never>?
    private var priceTask: Task<Void, Never>?
    private var priceRequestID = UUID()
    private let provider: any ScannerProvider
    private let pricing: any MarketPricing
    // Injection makes a failed transaction/retry testable without corrupting a store.
    private let saveCard: @MainActor (CardCandidate, ScanSession, CardList, ModelContext, String?) throws -> Void
    var label: String { provider.label }
    var liveProvider: TCGTrackingScannerProvider? { provider as? TCGTrackingScannerProvider }
    init(provider: (any ScannerProvider)? = nil, pricing: any MarketPricing = OnlineMarketPricing(),
         saveCard: @escaping @MainActor (CardCandidate, ScanSession, CardList, ModelContext, String?) throws -> Void = {
             try SessionService.add($0, session: $1, list: $2, context: $3, recognitionRef: $4)
         }) {
        self.provider = provider ?? TCGTrackingScannerProvider()
        self.pricing = pricing; self.saveCard = saveCard
    }
    func start(game: String, list: CardList, context: ModelContext, session: ScanSession) {
        guard consumer == nil, !paused else { return }
        guard session.isActive, session.listID == list.id, session.game == game else {
            error = BatchFailure.unavailable.localizedDescription; return
        }
        self.session = session
        DiagnosticLog.shared.record("scanner.start", ["provider": liveProvider == nil ? "mock" : "live"])
        if selected == nil { waitingForRemoval = false }
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
        result = scan
        var card = first; card.identity.condition = "Near Mint"
        selected = card
        confirmed = !card.requiresPrintingSelection.orFalse
        refreshPrice()
        DiagnosticLog.shared.record("recognition.result", ["episode": scan.id.uuidString, "candidates": String(scan.candidates.count)])
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
        let condition = selected?.identity.condition ?? "Near Mint"
        guard result?.candidates.contains(where: { $0.id == candidate.id }) == true || result == nil else { return }
        selected = candidate; selected?.identity.condition = condition
        confirmed = candidate.requiresPrintingSelection != true
        refreshPrice()
    }
    func confirmPrinting() { selected?.requiresPrintingSelection = false; confirmed = selected != nil }
    func changePrinting(_ printing: String) {
        guard var card = selected, card.printings.contains(printing) || printing == card.identity.printing else { return }
        card.identity.printing = printing
        card.identity.skuID = nil; card.marketPrice = nil; card.requiresPrintingSelection = false
        selected = card; confirmed = true; refreshPrice()
    }
    func changeCondition(_ condition: String) {
        guard CatalogOptions.conditions.contains(condition) else { return }
        selected?.identity.condition = condition
        refreshPrice()
    }
    func refreshPrice() {
        priceTask?.cancel(); priceRequestID = UUID()
        guard var card = selected else { return }
        // Never retain a quote for a previous printing or condition.
        card.marketPrice = nil; card.identity.skuID = nil; selected = card
        let requestID = priceRequestID
        let requestCard = card
        DiagnosticLog.shared.record("pricing.started")
        priceLoading = true; priceMessage = nil
        priceTask = Task { [weak self, pricing] in
            do {
                let quote = try await pricing.quote(for: requestCard)
                guard let self, !Task.isCancelled, self.priceRequestID == requestID, self.selected?.identity == requestCard.identity else { return }
                self.selected?.marketPrice = quote?.marketPrice
                self.selected?.identity.skuID = quote?.skuID
                self.priceLoading = false
                DiagnosticLog.shared.record("pricing.finished", ["priced": String(quote?.marketPrice != nil)])
                self.priceMessage = quote?.marketPrice == nil ? "Market value unavailable for this printing and condition." : nil
            } catch {
                guard let self, !Task.isCancelled, self.priceRequestID == requestID else { return }
                self.priceLoading = false
                DiagnosticLog.shared.failure("pricing.failed", error)
                self.priceMessage = "Online price lookup failed. Retry, or confirm with market value unavailable."
            }
        }
    }
    func addSelected(list: CardList, context: ModelContext) {
        guard confirmed, !saving, !priceLoading, let selected, let session else { return }
        saving = true
        defer { saving = false }
        do {
            try saveCard(selected, session, list, context, result?.candidates.first?.identity.productID)
            // Only a committed transaction releases the review snapshot.
            priceTask?.cancel(); priceRequestID = UUID()
            result = nil; self.selected = nil; confirmed = false; priceMessage = nil
            waitingForRemoval = true; error = nil
            liveProvider?.releaseReview()
            DiagnosticLog.shared.record("add.saved", ["priced": String(selected.marketPrice != nil)])
            if UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if UserDefaults.standard.bool(forKey: "sound") { AudioServicesPlaySystemSound(1104) }
        } catch {
            context.rollback(); self.error = "The card was not saved. Your selection is kept; tap Confirm & Add to retry."
            DiagnosticLog.shared.failure("persistence.failed", error)
        }
    }
    func scanNextCard() {
        // Intentional re-arm allows a second identical physical copy without identity merging.
        priceTask?.cancel(); priceRequestID = UUID(); priceLoading = false
        result = nil; selected = nil; confirmed = false; waitingForRemoval = false; priceMessage = nil
        liveProvider?.resetRecognition()
        DiagnosticLog.shared.record("recognition.rearmed")
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
