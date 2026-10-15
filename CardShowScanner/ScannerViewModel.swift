import Foundation
import SwiftData
import Observation
import UIKit
import AudioToolbox

@MainActor @Observable final class ScannerViewModel {
    var result: ScanResult?
    var selected: CardCandidate?
    var confirmed = false
    var paused = false
    var error: String?
    var session: ScanSession?
    var manualAdds = 0
    private var gate = RecognitionGate()
    private var userReviewed = false
    private var consumer: Task<Void, Never>?
    private let provider: any ScannerProvider
    var label: String { provider.label }
    var liveProvider: TCGTrackingScannerProvider? { provider as? TCGTrackingScannerProvider }
    init(provider: (any ScannerProvider)? = nil) { self.provider = provider ?? MockScannerProvider() }
    func start(game: String, list: CardList, context: ModelContext, session: ScanSession) {
        guard consumer == nil, !paused else { return }
        guard session.isActive, session.listID == list.id, session.game == game else {
            self.error = BatchFailure.unavailable.localizedDescription; return
        }
        self.session = session
        DiagnosticLog.shared.record("scanner.start", ["provider": liveProvider == nil ? "mock" : "live", "automatic": String(UserDefaults.standard.bool(forKey: "automaticAdd"))])
        result = nil; selected = nil; confirmed = false
        provider.start(game: game)
        let stream = provider.results
        consumer = Task { [weak self] in
            guard let self else { return }
            for await scan in stream {
                guard !Task.isCancelled else { return }
                guard !paused else { continue }
                guard scan.visible else {
                    DiagnosticLog.shared.record("recognition.hidden")
                    session.lastConsumedRecognitionRef = nil
                    do { try context.save() } catch { DiagnosticLog.shared.failure("session.save_failed", error); self.error = error.localizedDescription }
                    result = nil; selected = nil; confirmed = false
                    continue
                }
                DiagnosticLog.shared.record(scan.same ? "recognition.refresh" : "recognition.result", [
                    "episode": scan.id.uuidString, "same": String(scan.same), "accepted": String(scan.accepted),
                    "confidence": String(Int(scan.candidates.first?.confidence ?? 0)), "candidates": String(scan.candidates.count),
                    "printing_required": String(scan.candidates.first?.requiresPrintingSelection == true)
                ], sampleEvery: scan.same ? 5 : 0)
                let previous = gate.episode
                gate.receive(scan)
                if session.lastConsumedRecognitionRef == scan.candidates.first?.identity.productID,
                   session.lastConsumedRecognitionRef != nil { gate.markAdded() }
                let marker = gate.hasAdded ? scan.candidates.first?.identity.productID : nil
                if marker != session.lastConsumedRecognitionRef {
                    session.lastConsumedRecognitionRef = marker
                    do { try context.save() } catch { DiagnosticLog.shared.failure("session.save_failed", error); self.error = error.localizedDescription }
                }
                result = scan
                if previous != gate.episode {
                    selected = scan.candidates.first; confirmed = scan.accepted && (selected?.confidence ?? 0) >= 90 && selected?.requiresPrintingSelection != true
                    manualAdds = 0; userReviewed = false
                }
                if !userReviewed {
                    selected = scan.candidates.first
                    confirmed = scan.accepted && (selected?.confidence ?? 0) >= 90 && selected?.requiresPrintingSelection != true
                }
                if let index = scan.candidates.firstIndex(where: { $0.identity.productID == self.selected?.identity.productID }) {
                    selected?.confidence = scan.candidates[index].confidence
                }
                let defaults = UserDefaults.standard
                if !userReviewed, defaults.bool(forKey: "automaticAdd"), gate.consumeAutomatic(scan), let selected, selected.identity.productID == scan.candidates.first?.identity.productID {
                    DiagnosticLog.shared.record("add.decision", ["reason": "automatic_eligible", "episode": scan.id.uuidString])
                    add(selected, list: list, context: context)
                } else {
                    let reason: String
                    if userReviewed { reason = "user_reviewed" }
                    else if !defaults.bool(forKey: "automaticAdd") { reason = "manual_mode" }
                    else if scan.same { reason = "repeat_frame" }
                    else if !scan.accepted { reason = "not_accepted" }
                    else if (scan.candidates.first?.confidence ?? 0) < 90 { reason = "low_confidence" }
                    else if scan.candidates.first?.requiresPrintingSelection == true { reason = "printing_confirmation" }
                    else { reason = "already_consumed" }
                    DiagnosticLog.shared.record("add.decision", ["reason": reason, "episode": scan.id.uuidString], sampleEvery: scan.same ? 5 : 0)
                }
            }
        }
    }
    func stop() { if consumer != nil { DiagnosticLog.shared.record("scanner.stop") }; provider.stop(); consumer?.cancel(); consumer = nil }
    func togglePause(game: String, list: CardList, context: ModelContext, session: ScanSession) {
        paused.toggle()
        DiagnosticLog.shared.record("scanner.pause", ["phase": paused ? "paused" : "resumed"])
        if paused { stop() } else { start(game: game, list: list, context: context, session: session) }
    }
    func choose(_ candidate: CardCandidate) {
        let index = result?.candidates.firstIndex { $0.id == candidate.id } ?? -1
        DiagnosticLog.shared.record("candidate.selected", ["candidate_index": String(index), "priced": String(candidate.marketPrice != nil), "printing_required": String(candidate.requiresPrintingSelection == true)])
        userReviewed = true; selected = candidate; confirmed = candidate.requiresPrintingSelection != true
    }
    func confirmPrinting() {
        DiagnosticLog.shared.record("printing.confirmed")
        userReviewed = true
        selected?.requiresPrintingSelection = false; confirmed = selected != nil
    }
    func changePrinting(_ printing: String) {
        guard var card = selected else { return }
        userReviewed = true
        card.identity.printing = printing
        let quote = card.printingQuotes?.first { $0.label == printing }
        card.identity.skuID = quote?.skuID
        card.marketPrice = quote?.marketPrice // Never transfer a quote from another finish.
        card.requiresPrintingSelection = false
        DiagnosticLog.shared.record("printing.changed", ["priced": String(card.marketPrice != nil)])
        selected = card; confirmed = true
    }
    func addSelected(list: CardList, context: ModelContext) {
        guard confirmed, let selected else { DiagnosticLog.shared.record("add.blocked", ["reason": "confirmation_required"]); return }
        DiagnosticLog.shared.record("add.decision", ["reason": "manual_tap"])
        add(selected, list: list, context: context)
    }
    private func add(_ candidate: CardCandidate, list: CardList, context: ModelContext) {
        var card = candidate
        card.identity.condition = UserDefaults.standard.string(forKey: "defaultCondition") ?? "Near Mint"
        do {
            guard let session else { throw BatchFailure.unavailable }
            try SessionService.add(card, session: session, list: list, context: context, recognitionRef: result?.candidates.first?.identity.productID)
            gate.markAdded(); manualAdds += 1
            DiagnosticLog.shared.record("add.saved", ["priced": String(card.marketPrice != nil), "quantity": String(session.addedQuantity)])
            if UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if UserDefaults.standard.bool(forKey: "sound") { AudioServicesPlaySystemSound(1104) }
        } catch { DiagnosticLog.shared.failure("persistence.failed", error); context.rollback(); self.error = error.localizedDescription }
    }
}
