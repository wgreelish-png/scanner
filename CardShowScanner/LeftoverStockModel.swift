import Foundation
import Observation
import SwiftData

@MainActor struct LeftoverStockScanRoute: Identifiable {
    let id = UUID()
    let session: ScanSession
    let list: CardList
    let draft: ScanBatchDraft?
}

enum LeftoverStockWorkflowFailure: LocalizedError {
    case unsavedChanges, missingLists, staleSelection, unsupportedGame, changedDuringLookup, invalidCountList
    var errorDescription: String? {
        switch self {
        case .unsavedChanges: return "Finish saving or cancel your current edits before changing or exporting this count."
        case .missingLists: return "A saved count list is missing. Restore it or explicitly remove its reference before finishing this count."
        case .staleSelection: return "The counted cards changed. Reopen this card and try again."
        case .unsupportedGame: return "Camera scanning is unavailable for this game. Set quantities on the source cards below."
        case .changedDuringLookup: return "A counted card changed while its SKU was being checked. Your edit was kept; review the count and try again."
        case .invalidCountList: return "A count reference does not point to an independent, readable count list. Reopen your saved count before continuing."
        }
    }
}

/// A count owns only ordinary, independent count lists and its sidecar session.
/// Website stock, Show inventory, transactions and acquisition costs are never
/// imported or reconciled by this workflow.
@MainActor @Observable final class LeftoverStockModel {
    let store: LeftoverStockStore
    private let provider: any CardShowInventoryProviding
    private let pricing: any MarketPricing
    private let fetchLists: @MainActor (ModelContext) throws -> [CardList]
    private let saveCount: @MainActor (ModelContext) throws -> Void
    private var requestID = UUID()
    private(set) var lists: [CardList] = []
    private(set) var missingListIDs: [UUID] = []
    private(set) var comparison: LeftoverStockComparison?
    private(set) var isFetching = false
    private(set) var isResolving = false
    private(set) var needsSignIn = false
    private(set) var resolvedCount = 0
    private(set) var countAvailable = false
    var message: String?
    var selectedGame = "Pokémon"

    init(store: LeftoverStockStore? = nil, provider: (any CardShowInventoryProviding)? = nil,
         pricing: any MarketPricing = StandardMarketPricing(),
         fetchLists: @escaping @MainActor (ModelContext) throws -> [CardList] = { try $0.fetch(FetchDescriptor<CardList>()) },
         saveCount: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.store = store ?? .shared
        self.provider = provider ?? CardShowInventoryWebsiteClient()
        self.pricing = pricing
        self.fetchLists = fetchLists; self.saveCount = saveCount
    }

    var session: LeftoverStockSession? { store.active }
    var isBusy: Bool { isFetching || isResolving }
    var countedRows: [LeftoverStockCountRow] {
        lists.flatMap { $0.orderedCards.map { .init(id: $0.id, card: $0.snapshot, quantity: $0.quantity) } }
    }
    var isComplete: Bool { countAvailable && missingListIDs.isEmpty && session?.isCountComplete(for: countedRows) == true }
    var canExportReplacement: Bool { store.isLoaded && isComplete && comparison?.canExport == true && !isBusy }
    var games: [String] {
        let sourceGames = session?.baseline.rows.map { Self.canonicalGame($0.card.identity.game) } ?? []
        let countedGames = lists.flatMap { $0.cards.map { Self.canonicalGame($0.snapshot.identity.game) } }
        return Set(sourceGames + countedGames + Array(TCGGameRegistry.gameKeys.keys)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    var canScanSelectedGame: Bool { TCGGameRegistry.scannerKey(for: selectedGame) != nil }

    func refresh(context: ModelContext) {
        do { try reloadCount(context: context) }
        catch {
            countAvailable = false; lists = []; comparison = nil
            missingListIDs = session?.countListIDs ?? []
            message = error.localizedDescription
        }
    }

    private func reloadCount(context: ModelContext) throws {
        do {
            guard store.isLoaded else { throw LeftoverStockFailure.notLoaded }
            guard let session else { lists = []; missingListIDs = []; comparison = nil; countAvailable = false; return }
            let allLists = try fetchLists(context)
            let byID = Dictionary(uniqueKeysWithValues: allLists.map { ($0.id, $0) })
            let available = session.countListIDs.compactMap { byID[$0] }
            guard available.allSatisfy({ list in
                !list.isCardShowInventory && list.inventorySourceData == nil && list.transactionOutcomeData == nil
                    && list.cards.allSatisfy { row in
                        row.sourceInventoryID == nil && row.list?.id == list.id
                            && (try? JSONDecoder().decode(CardCandidate.self, from: row.data)) != nil
                    }
            }) else { throw LeftoverStockWorkflowFailure.invalidCountList }
            lists = available
            missingListIDs = session.countListIDs.filter { byID[$0] == nil }
            comparison = LeftoverStockReconciliation.compare(baseline: session.baseline, counts: countedRows)
            countAvailable = true
            if !games.contains(selectedGame), let first = games.first { selectedGame = first }
        } catch {
            countAvailable = false; lists = []; comparison = nil
            missingListIDs = session?.countListIDs ?? []
            throw error
        }
    }

    /// Fetching a new baseline is always explicit and never occurs on resume.
    /// Replacing an existing session happens only after a complete new fetch.
    func startNewCount(context: ModelContext, replacing sessionID: UUID? = nil) async {
        guard !isBusy else { return }
        do { try requireClean(context) } catch { message = error.localizedDescription; return }
        guard (sessionID == nil && session == nil) || sessionID == session?.id else {
            message = LeftoverStockFailure.sessionUnavailable.localizedDescription; return
        }
        let token = UUID(); requestID = token
        isFetching = true; needsSignIn = false; message = nil
        activity(.fetchBaseline)
        defer { if requestID == token { isFetching = false } }
        do {
            // No location ID is reused: a replacement location may have a new
            // ID, and the client must enforce a unique Card Show destination.
            let snapshot = try await provider.fetch(expectedLocationID: nil)
            try Task.checkCancellation()
            guard requestID == token else { return }
            try requireClean(context)
            let baseline = LeftoverStockBaseline(snapshot: snapshot)
            if let sessionID { try store.restart(baseline: baseline, sessionID: sessionID) }
            else { try store.start(baseline: baseline) }
            if let game = baseline.rows.first.map({ Self.canonicalGame($0.card.identity.game) }) { selectedGame = game }
            refresh(context: context)
            activity(.newCount, succeeded: true)
        } catch {
            guard requestID == token, !(error is CancellationError) else { return }
            needsSignIn = (error as? CardShowInventoryFailure) == .signInRequired
            message = error.localizedDescription
            activity(.fetchBaseline, succeeded: false)
        }
    }

    func prepareScan(context: ModelContext) throws -> LeftoverStockScanRoute {
        try requireClean(context)
        guard !isBusy, let session else { throw LeftoverStockFailure.sessionUnavailable }
        guard canScanSelectedGame else { throw LeftoverStockWorkflowFailure.unsupportedGame }
        try reloadCount(context: context)
        guard missingListIDs.isEmpty else { throw LeftoverStockWorkflowFailure.missingLists }
        try invalidateCompletion(sessionID: session.id)
        let sessions = try context.fetch(FetchDescriptor<ScanSession>())
        if let list = lists.first(where: { list in
            let game = sessions.first(where: { $0.listID == list.id })?.game ?? list.cards.first?.snapshot.identity.game
            return game.map(Self.canonicalGame) == Self.canonicalGame(selectedGame)
        }) {
            let game = sessions.first(where: { $0.listID == list.id })?.game ?? list.cards.first?.snapshot.identity.game ?? selectedGame
            let scannerSession = try SessionService.continueList(list, game: game, context: context, finishingOtherSession: true)
            activity(.resumeCount)
            return .init(session: scannerSession, list: list, draft: nil)
        }
        let draft = try SessionService.prepareDraft(game: selectedGame, rememberGame: false)
        draft.list.name = "Leftover Count · " + selectedGame
        draft.session.listName = draft.list.name
        // Persist the stable reference before the first physical card commits.
        try store.addCountList(id: draft.list.id, sessionID: session.id)
        activity(.resumeCount)
        return .init(session: draft.session, list: draft.list, draft: draft)
    }

    func scanClosed(_ route: LeftoverStockScanRoute, context: ModelContext) {
        if let draft = route.draft, !draft.isCommitted, let session {
            do { try store.removeCountList(id: route.list.id, sessionID: session.id) }
            catch { message = error.localizedDescription }
        }
        refresh(context: context)
    }

    func finishCount(context: ModelContext) throws {
        try requireClean(context); try reloadCount(context: context)
        guard !isBusy, let session else { throw LeftoverStockFailure.sessionUnavailable }
        guard missingListIDs.isEmpty else { throw LeftoverStockWorkflowFailure.missingLists }
        try store.setCountComplete(true, sessionID: session.id, counts: countedRows)
        activity(.finishCount, succeeded: true)
    }

    func replacementCSV(context: ModelContext) throws -> String {
        try requireClean(context); try reloadCount(context: context)
        guard !isBusy, let comparison else { throw LeftoverStockFailure.sessionUnavailable }
        guard missingListIDs.isEmpty else { throw LeftoverStockWorkflowFailure.missingLists }
        let csv = try LeftoverStockReconciliation.replacementCSV(comparison: comparison, countComplete: isComplete)
        activity(.exportReplacement, succeeded: true)
        return csv
    }

    func comparisonCSV(context: ModelContext) throws -> String {
        try requireClean(context); try reloadCount(context: context)
        guard !isBusy, let comparison else { throw LeftoverStockFailure.sessionUnavailable }
        // A comparison with missing references would understate the known count.
        guard missingListIDs.isEmpty else { throw LeftoverStockWorkflowFailure.missingLists }
        activity(.exportComparison, succeeded: true)
        return LeftoverStockReconciliation.comparisonCSV(comparison: comparison)
    }

    func removeMissingReferences(context: ModelContext) throws {
        try requireClean(context); try reloadCount(context: context)
        guard let session else { throw LeftoverStockFailure.sessionUnavailable }
        for id in missingListIDs { try store.removeCountList(id: id, sessionID: session.id) }
        refresh(context: context)
    }

    func item(id: UUID) -> InventoryCard? { lists.lazy.flatMap(\.cards).first { $0.id == id } }

    /// Absolute quantity correction for an exactly reconciled SKU. This is also
    /// the count path for games that have no camera recognition pack.
    func setCount(_ quantity: Int, for selected: LeftoverStockComparisonRow, context: ModelContext) throws {
        try requireClean(context); try reloadCount(context: context)
        guard !isBusy, let session else { throw LeftoverStockFailure.sessionUnavailable }
        guard missingListIDs.isEmpty else { throw LeftoverStockWorkflowFailure.missingLists }
        guard let current = comparison?.rows.first(where: { $0.id == selected.id }), current == selected else {
            throw LeftoverStockWorkflowFailure.staleSelection
        }
        guard (0...LeftoverStockReconciliation.maximumQuantity).contains(quantity) else { throw LeftoverStockFailure.invalidCounts }
        let matched = current.countRowIDs.compactMap { item(id: $0) }
        guard matched.count == current.countRowIDs.count else { throw LeftoverStockWorkflowFailure.staleSelection }
        if quantity == current.countedQuantity { return }
        let newItem = quantity > 0 && matched.isEmpty ? try InventoryCard(card: current.card, quantity: quantity) : nil
        let previousLists = lists.map { ($0, $0.cards) }
        let previousQuantities = matched.map { ($0, $0.quantity) }
        let scannerSessions = try context.fetch(FetchDescriptor<ScanSession>())
        var target = matched.first?.list ?? lists.first { list in
            if list.cards.isEmpty {
                let savedGame = scannerSessions.first { $0.listID == list.id }?.game
                return savedGame.map(Self.canonicalGame) == Self.canonicalGame(current.card.identity.game)
                    || (savedGame == nil && list.name == "Leftover Count · " + Self.canonicalGame(current.card.identity.game))
            }
            return list.cards.allSatisfy { Self.canonicalGame($0.snapshot.identity.game) == Self.canonicalGame(current.card.identity.game) }
        }
        let newList = newItem != nil && target == nil ? CardList(name: "Leftover Count · " + Self.canonicalGame(current.card.identity.game)) : nil
        if let newList { target = newList; try store.addCountList(id: newList.id, sessionID: session.id) }
        else { try invalidateCompletion(sessionID: session.id) }
        do {
            if let newList { context.insert(newList) }
            if let newItem, let target {
                context.insert(newItem); target.cards.append(newItem)
            } else {
                for (index, item) in matched.enumerated() {
                    if quantity > 0 && index == 0 { item.quantity = quantity }
                    else { context.delete(item) }
                }
            }
            try saveCount(context)
        } catch {
            // There were no preexisting changes or suspension points in this
            // transaction, so rollback affects only this quantity correction.
            context.rollback()
            for (list, cards) in previousLists {
                if list.cards.map(\.id) != cards.map(\.id) { list.cards = cards }
                for card in cards where card.list?.id != list.id { card.list = list }
            }
            for (item, quantity) in previousQuantities where item.quantity != quantity { item.quantity = quantity }
            context.processPendingChanges()
            if context.hasChanges { context.rollback() }
            if let newList { try? store.removeCountList(id: newList.id, sessionID: session.id) }
            refresh(context: context)
            throw error
        }
        refresh(context: context); activity(.setCount, succeeded: true)
    }

    /// Only exact SKU metadata is requested, one physical row at a time. A SKU
    /// may be useful even when its response has no market price.
    func resolveMissingSKUs(context: ModelContext) async {
        guard !isBusy, let session else { return }
        do { try requireClean(context) } catch { message = error.localizedDescription; return }
        do { try reloadCount(context: context) } catch { message = error.localizedDescription; return }
        guard missingListIDs.isEmpty else { message = LeftoverStockWorkflowFailure.missingLists.localizedDescription; return }
        let ids = Set(comparison?.issues.filter { $0.kind == .unresolvedCard || $0.kind == .invalidSKU }.flatMap(\.rowIDs) ?? [])
        let token = UUID(); requestID = token; isResolving = true; resolvedCount = 0; message = nil
        activity(.resolveSKU)
        defer { if requestID == token { isResolving = false; refresh(context: context) } }
        do {
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                try Task.checkCancellation()
                guard requestID == token, store.active?.id == session.id else { return }
                try requireClean(context)
                guard let original = item(id: id), let listID = original.list?.id else { continue }
                let data = original.data, quantity = original.quantity, card = original.snapshot
                let details = try await pricing.details(for: card, candidates: [card], forceRefresh: false)
                try Task.checkCancellation()
                guard requestID == token, store.active?.id == session.id else { return }
                try requireClean(context); try reloadCount(context: context)
                guard let current = item(id: id), current.data == data, current.quantity == quantity,
                      current.list?.id == listID else { throw LeftoverStockWorkflowFailure.changedDuringLookup }
                guard let sku = details.quote?.skuID, Self.validSKU(sku) else { continue }
                var resolved = card; resolved.identity.skuID = sku
                let encoded = try JSONEncoder().encode(resolved)
                try invalidateCompletion(sessionID: session.id)
                current.data = encoded
                do { try saveCount(context) }
                catch {
                    context.rollback()
                    if current.data != data { current.data = data }
                    context.processPendingChanges()
                    if context.hasChanges { context.rollback() }
                    throw error
                }
                resolvedCount += 1
            }
            refresh(context: context)
            message = resolvedCount == 0 ? "No additional exact SKUs were found. Review the unresolved cards below." : "Resolved \(resolvedCount) counted card rows."
            activity(.resolveSKU, succeeded: true)
        } catch {
            guard requestID == token, !(error is CancellationError) else { return }
            message = error.localizedDescription; activity(.resolveSKU, succeeded: false)
        }
    }

    func cancel() {
        requestID = UUID(); provider.cancel(); isFetching = false; isResolving = false
    }

    private func invalidateCompletion(sessionID: UUID) throws {
        if session?.countComplete == true { try store.setCountComplete(false, sessionID: sessionID, counts: []) }
    }
    private func requireClean(_ context: ModelContext) throws {
        guard store.isLoaded else { throw LeftoverStockFailure.notLoaded }
        guard !context.hasChanges else { throw LeftoverStockWorkflowFailure.unsavedChanges }
    }
    static func canonicalGame(_ game: String) -> String {
        TCGGameRegistry.categoryID(for: game).flatMap(TCGGameRegistry.name(for:)) ?? game
    }
    private static func validSKU(_ sku: String) -> Bool {
        !sku.isEmpty && sku.utf8.count <= 20 && sku.utf8.allSatisfy { (48...57).contains($0) } && sku.utf8.contains { $0 != 48 }
    }
    private func activity(_ action: DiagnosticActivityAction, succeeded: Bool? = nil) {
        DiagnosticLog.shared.activity(succeeded == nil ? .action : .outcome, screen: .leftoverStock, action: action,
            state: .init(pendingCount: comparison?.issues.count, isPreparing: isBusy, canProceed: canExportReplacement,
                         cardCount: comparison?.countedQuantity, succeeded: succeeded))
    }
}
