import Foundation
import SwiftData

enum BatchFailure: LocalizedError {
    case activeSessionExists, unavailable, wrongGame, invalidRates, invalidQuantity, invalidOfferAmount
    var errorDescription: String? {
        switch self {
        case .activeSessionExists: return "Finish the active session before starting another batch."
        case .unavailable: return "This session is completed or its list is no longer available."
        case .wrongGame: return "A batch can contain only its selected game. Start another session to change games."
        case .invalidRates: return "Each offer percentage must be between 0 and 100."
        case .invalidQuantity: return "Quantity must be at least one."
        case .invalidOfferAmount: return "Enter a custom cash offer from $0 to $999,999,999.99 with at most two decimal places."
        }
    }
}

@MainActor enum SessionService {
    static func list(for session: ScanSession, context: ModelContext) throws -> CardList? {
        guard let id = session.listID else { return nil }
        return try context.fetch(FetchDescriptor<CardList>(predicate: #Predicate { $0.id == id })).first
    }
    static func active(context: ModelContext) throws -> ScanSession? {
        let sessions = try context.fetch(FetchDescriptor<ScanSession>(sortBy: [SortDescriptor(\ScanSession.startedAt, order: .reverse)]))
        return sessions.first { $0.isActive }
    }
    static func prepareDefaults(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "batchPricingDefaultsMigrated") else { return }
        if defaults.object(forKey: "cashPercentage") == nil,
           defaults.object(forKey: "pricingPercentage") != nil {
            let legacy = defaults.double(forKey: "pricingPercentage")
            defaults.set(legacy.isFinite ? min(100, max(0, legacy)) : 70, forKey: "cashPercentage")
        }
        defaults.set(true, forKey: "batchPricingDefaultsMigrated")
    }
    static func defaults(_ defaults: UserDefaults = .standard) -> OfferRates {
        func rate(_ key: String, fallback: Double) -> Decimal {
            let value = defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
            return Decimal(value.isFinite ? min(100, max(0, value)) : (fallback.isFinite ? min(100, max(0, fallback)) : 70))
        }
        return OfferRates(cash: rate("cashPercentage", fallback: defaults.object(forKey: "pricingPercentage") == nil ? 70 : defaults.double(forKey: "pricingPercentage")),
            trade: rate("tradePercentage", fallback: 80), maximum: rate("maximumBuyPercentage", fallback: 75))
    }
    static func start(game: String, context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) throws -> ScanSession {
        guard try active(context: context) == nil else { throw BatchFailure.activeSessionExists }
        guard CatalogOptions.games.contains(game) else { throw BatchFailure.wrongGame }
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d, yyyy - h:mm a"
        let list = CardList(name: formatter.string(from: now) + " - " + game); list.createdAt = now
        let session = ScanSession(listName: list.name)
        session.startedAt = now; session.listID = list.id; session.game = game; session.statusRaw = "active"
        session.setRates(Self.defaults(defaults))
        context.insert(list); context.insert(session)
        do { try context.save() }
        catch {
            // A failed start must not discard other edits staged in this context.
            context.delete(session); context.delete(list); context.processPendingChanges()
            throw error
        }
        defaults.set(game, forKey: "defaultGame")
        DiagnosticLog.shared.record("batch.started")
        return session
    }
    static func finish(_ session: ScanSession, context: ModelContext) throws {
        guard session.isActive else { throw BatchFailure.unavailable }
        session.statusRaw = "completed"; session.completedAt = .now
        try CardListService.save(context)
        DiagnosticLog.shared.record("batch.completed")
    }
    /// Both operations commit together: a failed replacement keeps the old active batch.
    static func replace(_ current: ScanSession, game: String, context: ModelContext, defaults: UserDefaults = .standard) throws -> ScanSession {
        guard current.isActive else { throw BatchFailure.unavailable }
        guard CatalogOptions.games.contains(game) else { throw BatchFailure.wrongGame }
        let previousStatus = current.statusRaw, previousCompletion = current.completedAt
        current.statusRaw = "completed"; current.completedAt = .now
        do { return try start(game: game, context: context, defaults: defaults) }
        catch {
            current.statusRaw = previousStatus; current.completedAt = previousCompletion
            context.processPendingChanges()
            throw error
        }
    }
    static func continueList(_ list: CardList, game: String, context: ModelContext, finishingOtherSession: Bool = false) throws -> ScanSession {
        guard CatalogOptions.games.contains(game), list.cards.allSatisfy({ $0.snapshot.identity.game == game }) else { throw BatchFailure.wrongGame }
        let sessions = try context.fetch(FetchDescriptor<ScanSession>())
        if let existing = sessions.first(where: { $0.listID == list.id }) {
            try resume(existing, context: context, finishingOtherSession: finishingOtherSession); return existing
        }
        if let current = try active(context: context) {
            guard finishingOtherSession else { throw BatchFailure.activeSessionExists }
            current.statusRaw = "completed"; current.completedAt = .now
        }
        let session = ScanSession(listName: list.name)
        session.listID = list.id; session.game = game; session.statusRaw = "active"
        session.setRates(defaults()); context.insert(session)
        try CardListService.save(context)
        return session
    }
    static func resume(_ session: ScanSession, context: ModelContext, finishingOtherSession: Bool = false) throws {
        guard let list = try list(for: session, context: context), let game = session.game,
              CatalogOptions.games.contains(game), list.cards.allSatisfy({ $0.snapshot.identity.game == game }) else {
            throw BatchFailure.unavailable
        }
        if let current = try active(context: context), current.id != session.id {
            guard finishingOtherSession else { throw BatchFailure.activeSessionExists }
            current.statusRaw = "completed"; current.completedAt = .now
        }
        session.statusRaw = "active"; session.completedAt = nil
        session.lastConsumedRecognitionRef = nil
        try CardListService.save(context)
    }
    static func add(_ card: CardCandidate, session: ScanSession, list: CardList, context: ModelContext, recognitionRef: String? = nil) throws {
        guard session.isActive, session.listID == list.id else { throw BatchFailure.unavailable }
        guard session.game == card.identity.game else { throw BatchFailure.wrongGame }
        try withScanSave(session: session, list: list, context: context) {
            try CardListService.add(card, to: list, context: context)
            session.record(card)
            session.lastConsumedRecognitionRef = recognitionRef ?? card.identity.productID
            try context.save()
        }
    }
    /// SwiftData rollback can leave a live relationship's cached array mutated.
    /// Undo this scan's staged rows and counters explicitly, preserving unrelated edits.
    static func withScanSave(session: ScanSession, list: CardList, context: ModelContext,
                             operation: () throws -> Void) rethrows {
        let cards = list.cards
        let insertedBefore = Set(context.insertedModelsArray.map { ObjectIdentifier($0) })
        let quantity = session.addedQuantity, value = session.knownValueText
        let unpriced = session.unpricedQuantity, recognitionRef = session.lastConsumedRecognitionRef
        do { try operation() }
        catch {
            let listObjects = Set(list.cards.map { ObjectIdentifier($0) })
            let stagedCards = context.insertedModelsArray.compactMap { $0 as? InventoryCard }.filter {
                !insertedBefore.contains(ObjectIdentifier($0)) && listObjects.contains(ObjectIdentifier($0))
            }
            list.cards = cards
            for item in stagedCards { context.delete(item) }
            session.addedQuantity = quantity; session.knownValueText = value
            session.unpricedQuantity = unpriced; session.lastConsumedRecognitionRef = recognitionRef
            context.processPendingChanges()
            throw error
        }
    }
    static func saveOffer(_ session: ScanSession, list: CardList, context: ModelContext, customCashOffer: Decimal? = nil,
                          transactionInput: TradeTransactionInput? = nil) throws {
        guard session.listID == list.id, session.rates.isValid else { throw BatchFailure.invalidRates }
        guard customCashOffer.map(CustomOfferAmount.isValid) ?? true else { throw BatchFailure.invalidOfferAmount }
        let lines = list.orderedCards.map { item in
            let card = item.snapshot, input = item.offerLine
            return SavedOfferLine(inventoryID: item.id, name: card.name, productID: card.identity.productID,
                printing: card.identity.printing, condition: card.identity.condition, language: card.identity.language,
                price: input.price, quantity: input.quantity, cashOverride: input.cashOverride,
                tradeOverride: input.tradeOverride, maximumOverride: input.maximumOverride)
        }
        let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates)
        let transaction = try transactionInput.map {
            try TradeTransactionCalculator.calculate(totals: totals, input: $0, customCashOffer: customCashOffer)
        }
        var saved = try session.savedOffers()
        saved.append(OfferSnapshot(rates: session.rates, totals: totals, lines: lines, customCashOffer: customCashOffer,
                                   tradeTransaction: transaction))
        session.savedOffersData = try JSONEncoder().encode(saved)
        try CardListService.save(context)
        DiagnosticLog.shared.record("offer.snapshot_saved")
    }
    static func deleteList(_ list: CardList, context: ModelContext) throws {
        do {
            let id = list.id
            let quantity = list.quantity
            let sessions = try context.fetch(FetchDescriptor<ScanSession>())
            for session in sessions where session.listID == id {
                session.listName = list.name
                session.listID = nil
                if session.isActive || session.statusRaw == "active" { session.statusRaw = "completed"; session.completedAt = .now }
            }
            context.delete(list)
            try CardListService.save(context)
            DiagnosticLog.shared.record("list.deleted", ["quantity": String(quantity)])
        } catch {
            DiagnosticLog.shared.failure("list.delete_failed", error)
            throw error
        }
    }
    /// Resolve the target at confirmation time instead of holding a live model
    /// through query updates or the confirmation's presentation lifecycle.
    static func deleteList(id: UUID, context: ModelContext) throws {
        var descriptor = FetchDescriptor<CardList>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let list: CardList?
        do { list = try context.fetch(descriptor).first }
        catch {
            DiagnosticLog.shared.failure("list.delete_failed", error)
            throw error
        }
        guard let list else {
            DiagnosticLog.shared.record("list.delete_absent")
            return
        }
        try deleteList(list, context: context)
    }
}
