import Foundation
import SwiftData

enum BatchFailure: LocalizedError {
    case activeSessionExists, unavailable, wrongGame, invalidRates, invalidQuantity
    var errorDescription: String? {
        switch self {
        case .activeSessionExists: return "Finish the active session before starting another batch."
        case .unavailable: return "This session is completed or its list is no longer available."
        case .wrongGame: return "A batch can contain only its selected game. Start another session to change games."
        case .invalidRates: return "Each offer percentage must be between 0 and 100."
        case .invalidQuantity: return "Quantity must be at least one."
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
        do { try context.save() } catch { context.rollback(); throw error }
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
        current.statusRaw = "completed"; current.completedAt = .now
        do { return try start(game: game, context: context, defaults: defaults) }
        catch { context.rollback(); throw error }
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
        do {
            try CardListService.add(card, to: list, context: context)
            session.record(card)
            session.lastConsumedRecognitionRef = recognitionRef ?? card.identity.productID
            try context.save()
        } catch { context.rollback(); throw error }
    }
    static func saveOffer(_ session: ScanSession, list: CardList, context: ModelContext) throws {
        guard session.listID == list.id, session.rates.isValid else { throw BatchFailure.invalidRates }
        let lines = list.orderedCards.map { item in
            let card = item.snapshot, input = item.offerLine
            return SavedOfferLine(inventoryID: item.id, name: card.name, productID: card.identity.productID,
                printing: card.identity.printing, condition: card.identity.condition, language: card.identity.language,
                price: input.price, quantity: input.quantity, cashOverride: input.cashOverride,
                tradeOverride: input.tradeOverride, maximumOverride: input.maximumOverride)
        }
        var saved = try session.savedOffers()
        saved.append(OfferSnapshot(rates: session.rates, totals: OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates), lines: lines))
        session.savedOffersData = try JSONEncoder().encode(saved)
        try CardListService.save(context)
        DiagnosticLog.shared.record("offer.snapshot_saved")
    }
    static func deleteList(_ list: CardList, context: ModelContext) throws {
        let id = list.id
        let sessions = try context.fetch(FetchDescriptor<ScanSession>())
        for session in sessions where session.listID == id {
            session.listName = list.name
            session.listID = nil
            if session.isActive || session.statusRaw == "active" { session.statusRaw = "completed"; session.completedAt = .now }
        }
        context.delete(list); try CardListService.save(context)
    }
}
