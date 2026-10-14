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
    func start(game: String, list: CardList, context: ModelContext) {
        guard consumer == nil, !paused else { return }
        if session == nil {
            let s = ScanSession(listName: list.name); session = s; context.insert(s)
            do { try context.save() } catch { context.rollback(); session = nil; self.error = error.localizedDescription; return }
        }
        result = nil; selected = nil; confirmed = false
        provider.start(game: game)
        let stream = provider.results
        consumer = Task { [weak self] in
            guard let self else { return }
            for await scan in stream {
                guard !Task.isCancelled else { return }
                guard !paused else { continue }
                guard scan.visible else {
                    result = nil; selected = nil; confirmed = false
                    continue
                }
                let previous = gate.episode
                gate.receive(scan)
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
                    add(selected, list: list, context: context)
                }
            }
        }
    }
    func stop() { provider.stop(); consumer?.cancel(); consumer = nil }
    func togglePause(game: String, list: CardList, context: ModelContext) {
        paused.toggle()
        if paused { stop() } else { start(game: game, list: list, context: context) }
    }
    func choose(_ candidate: CardCandidate) { userReviewed = true; selected = candidate; confirmed = candidate.requiresPrintingSelection != true }
    func confirmPrinting() {
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
        selected = card; confirmed = true
    }
    func addSelected(list: CardList, context: ModelContext) {
        guard confirmed, let selected else { return }
        add(selected, list: list, context: context)
    }
    private func add(_ candidate: CardCandidate, list: CardList, context: ModelContext) {
        var card = candidate
        card.identity.condition = UserDefaults.standard.string(forKey: "defaultCondition") ?? "Near Mint"
        do {
            try CardListService.add(card, to: list, context: context)
            session?.record(card); try context.save(); gate.markAdded(); manualAdds += 1
            if UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if UserDefaults.standard.bool(forKey: "sound") { AudioServicesPlaySystemSound(1104) }
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
    func resetSession(context: ModelContext, listName: String) {
        let fresh = ScanSession(listName: listName); context.insert(fresh); session = fresh
        do { try context.save() } catch { self.error = error.localizedDescription }
    }
}
