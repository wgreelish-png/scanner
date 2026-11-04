import Foundation

enum ShowBudgetFailure: LocalizedError, Equatable, Sendable {
    case invalidAmount, invalidEntry, invalidEvent, invalidDates, invalidBook, duplicateIdentity, invalidVersion, arithmeticOverflow, capacityExceeded
    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter an amount from $0 to $999,999,999.99 with at most two decimal places."
        case .invalidEntry: return "This budget transaction contains invalid cash amounts or details. Review it and try again."
        case .invalidEvent: return "Enter a show name and a valid starting budget."
        case .invalidDates: return "Choose a valid show start date and an end date on or after it."
        case .invalidBook: return "The saved show budget could not be validated. Your saved data has been kept."
        case .duplicateIdentity: return "A budget record has a duplicate identifier. Your saved data has been kept."
        case .invalidVersion: return "This show budget uses an unsupported format. Your saved data has been kept."
        case .arithmeticOverflow: return "These budget totals are too large to calculate safely."
        case .capacityExceeded: return "This show ledger has reached its storage limit. Your existing cards, cash, shows, and receipts have been kept."
        }
    }
}

enum ShowBudgetMoney {
    static let maximumCents: Int64 = 99_999_999_999
    static func isValid(_ cents: Int64) -> Bool { (0...maximumCents).contains(cents) }

    /// Input is USD, without currency symbols or separators; no rounding occurs.
    static func parse(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{1,9}(?:\.[0-9]{0,2})?$"#, options: .regularExpression) != nil else { return nil }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let dollars = Int64(fields[0]) else { return nil }
        let fraction = fields.count == 2 ? String(fields[1]) : ""
        guard let cents = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) else { return nil }
        let result = dollars * 100 + cents
        return isValid(result) ? result : nil
    }

    static func decimal(_ cents: Int64) -> Decimal { Decimal(cents) / 100 }
}

enum ShowBudgetEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case purchase, sale, trade
    var id: String { rawValue }
    var title: String {
        switch self { case .purchase: return "Purchase"; case .sale: return "Sale"; case .trade: return "Trade" }
    }
}

enum ShowBudgetSplitBasis: String, Codable, CaseIterable, Identifiable, Sendable {
    case grossProceeds, netProceeds
    var id: String { rawValue }
    var title: String { self == .grossProceeds ? "Gross sale amount" : "After fees" }
}

struct ShowBudgetAllocation: Equatable, Sendable {
    let reinvestedCents: Int64
    let savedCents: Int64
    let availableDeltaCents: Int64
}

/// Explicit cash receipts. Recording a list outcome can post its calculated
/// cash; browsing prices or changing an offer never posts money.
struct ShowBudgetEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: ShowBudgetEntryKind
    var paidCents: Int64
    var grossReceivedCents: Int64
    var feeCents: Int64
    /// Snapshotted on the entry, so later show settings cannot rewrite prior splits.
    var reinvestmentPercent: Int
    var splitBasis: ShowBudgetSplitBasis
    var recordedAt: Date
    var listID: UUID?
    var listName: String?
    var note: String
    var voidedAt: Date?
    /// Present only for receipts created by a durable list-outcome command.
    var outcomeOperationID: UUID? = nil
    /// Cash projection of an atomic stock transaction; reverse through its receipt.
    var transactionID: UUID? = nil

    init(id: UUID = UUID(), kind: ShowBudgetEntryKind, paidCents: Int64 = 0,
         grossReceivedCents: Int64 = 0, feeCents: Int64 = 0, reinvestmentPercent: Int = 65,
         splitBasis: ShowBudgetSplitBasis = .grossProceeds, recordedAt: Date = Date(),
         listID: UUID? = nil, listName: String? = nil, note: String = "", voidedAt: Date? = nil,
         outcomeOperationID: UUID? = nil, transactionID: UUID? = nil) {
        self.id = id; self.kind = kind; self.paidCents = paidCents
        self.grossReceivedCents = grossReceivedCents; self.feeCents = feeCents
        self.reinvestmentPercent = reinvestmentPercent; self.splitBasis = splitBasis
        self.recordedAt = recordedAt; self.listID = listID; self.listName = listName
        self.note = note; self.voidedAt = voidedAt; self.outcomeOperationID = outcomeOperationID
        self.transactionID = transactionID
    }

    func validate() throws {
        guard [paidCents, grossReceivedCents, feeCents].allSatisfy(ShowBudgetMoney.isValid),
              feeCents <= grossReceivedCents, !(paidCents > 0 && grossReceivedCents > 0),
              (0...100).contains(reinvestmentPercent), recordedAt.timeIntervalSince1970.isFinite,
              note.count <= 1_000, listName.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 250 }) ?? true,
              voidedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= recordedAt }) ?? true else {
            throw ShowBudgetFailure.invalidEntry
        }
        if let outcomeOperationID {
            guard outcomeOperationID == id, listID != nil else { throw ShowBudgetFailure.invalidEntry }
        }
        if let transactionID {
            guard transactionID == id, outcomeOperationID == nil, kind == .sale || feeCents == 0 else { throw ShowBudgetFailure.invalidEntry }
        }
        switch kind {
        case .purchase:
            guard grossReceivedCents == 0, feeCents == 0 else { throw ShowBudgetFailure.invalidEntry }
        case .sale:
            guard paidCents == 0 else { throw ShowBudgetFailure.invalidEntry }
        case .trade: break
        }
    }

    func allocation() throws -> ShowBudgetAllocation {
        try validate()
        guard voidedAt == nil else { return ShowBudgetAllocation(reinvestedCents: 0, savedCents: 0, availableDeltaCents: 0) }
        let basis = splitBasis == .grossProceeds ? grossReceivedCents : grossReceivedCents - feeCents
        let multiplied = basis.multipliedReportingOverflow(by: Int64(reinvestmentPercent))
        guard !multiplied.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
        let rounded = multiplied.partialValue.addingReportingOverflow(50)
        guard !rounded.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
        let reinvested = rounded.partialValue / 100
        let saved = basis - reinvested
        // Gross splitting preserves the requested buying allocation; fees are
        // a separate cash cost. Net splitting already deducted those fees.
        let feesAfterSplit = splitBasis == .grossProceeds ? feeCents : 0
        return ShowBudgetAllocation(reinvestedCents: reinvested, savedCents: saved,
                                    availableDeltaCents: reinvested - paidCents - feesAfterSplit)
    }
}

struct ShowBudgetTotals: Equatable, Sendable {
    let startingCents: Int64
    let paidCents: Int64
    let grossReceivedCents: Int64
    let feesCents: Int64
    let reinvestedCents: Int64
    let savedCents: Int64
    /// Can be negative: overspending must remain visible rather than be clamped.
    let availableCents: Int64
    /// All remaining cash, including the personal savings allocation.
    let cashOnHandCents: Int64
}

enum ShowBudgetScheduleStatus: String, Equatable, Sendable {
    case manual, scheduled, active, ended

    var title: String {
        switch self {
        case .manual: return "No schedule"
        case .scheduled: return "Scheduled"
        case .active: return "Active today"
        case .ended: return "Ended"
        }
    }
    var allowsRecording: Bool { self == .manual || self == .active }
}

struct ShowBudgetEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var startingCents: Int64
    var reinvestmentPercent: Int
    var createdAt: Date
    var entries: [ShowBudgetEntry]
    var startDate: Date?
    var endDate: Date?
    var deletedAt: Date?

    init(id: UUID = UUID(), name: String, startingCents: Int64, reinvestmentPercent: Int = 65,
         createdAt: Date = Date(), entries: [ShowBudgetEntry] = [], startDate: Date? = nil, endDate: Date? = nil,
         deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.startingCents = startingCents
        self.reinvestmentPercent = reinvestmentPercent; self.createdAt = createdAt; self.entries = entries
        self.startDate = startDate; self.endDate = endDate
        self.deletedAt = deletedAt
    }

    func validate() throws {
        guard entries.count <= ShowBudgetBook.maximumEntriesPerShow else { throw ShowBudgetFailure.capacityExceeded }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              ShowBudgetMoney.isValid(startingCents), (0...100).contains(reinvestmentPercent),
              createdAt.timeIntervalSince1970.isFinite,
              deletedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= createdAt }) ?? true else {
            throw ShowBudgetFailure.invalidEvent
        }
        if let startDate, let endDate {
            guard startDate.timeIntervalSince1970.isFinite, endDate.timeIntervalSince1970.isFinite,
                  endDate >= startDate else { throw ShowBudgetFailure.invalidDates }
        } else if startDate != nil || endDate != nil { throw ShowBudgetFailure.invalidDates }
        guard Set(entries.map(\.id)).count == entries.count else { throw ShowBudgetFailure.duplicateIdentity }
        for entry in entries { try entry.validate() }
    }

    /// Dates describe whole local calendar days, including both endpoints.
    /// Calendar boundaries handle daylight-saving days without 24-hour offsets.
    func applies(on date: Date, calendar: Calendar = .current) -> Bool {
        deletedAt == nil && scheduleStatus(on: date, calendar: calendar).allowsRecording
    }

    func scheduleStatus(on date: Date, calendar: Calendar = .current) -> ShowBudgetScheduleStatus {
        guard date.timeIntervalSince1970.isFinite else { return .ended }
        guard let startDate else { return endDate == nil ? .manual : .ended }
        guard let endDate, startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite, endDate >= startDate else { return .ended }
        let day = calendar.startOfDay(for: date)
        if day < calendar.startOfDay(for: startDate) { return .scheduled }
        if day > calendar.startOfDay(for: endDate) { return .ended }
        return .active
    }

    func totals() throws -> ShowBudgetTotals {
        try validate()
        var paid: Int64 = 0, received: Int64 = 0, fees: Int64 = 0
        var reinvested: Int64 = 0, saved: Int64 = 0, available = startingCents
        for entry in entries where entry.voidedAt == nil {
            let allocation = try entry.allocation()
            paid = try Self.add(paid, entry.paidCents)
            received = try Self.add(received, entry.grossReceivedCents)
            fees = try Self.add(fees, entry.feeCents)
            reinvested = try Self.add(reinvested, allocation.reinvestedCents)
            saved = try Self.add(saved, allocation.savedCents)
            available = try Self.add(available, allocation.availableDeltaCents)
        }
        let cashOnHand = try Self.add(try Self.add(try Self.add(startingCents, received), -paid), -fees)
        guard try Self.add(available, saved) == cashOnHand else { throw ShowBudgetFailure.arithmeticOverflow }
        return ShowBudgetTotals(startingCents: startingCents, paidCents: paid, grossReceivedCents: received,
                                feesCents: fees, reinvestedCents: reinvested, savedCents: saved,
                                availableCents: available, cashOnHandCents: cashOnHand)
    }

    private static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
        return result.partialValue
    }
}

struct ShowBudgetBook: Codable, Equatable, Sendable {
    /// Only visible shows count against the working show limit. Tombstones
    /// have a separate bound so ordinary show deletion frees a working slot.
    static let maximumShows = 100
    static let maximumStoredShows = 1_000
    static let maximumEntriesPerShow = 10_000
    static let maximumEntriesTotal = 20_000
    static let maximumOutcomeUpdates = 20_000
    /// Imported snapshots and any one transaction remain bounded separately
    /// from permanent lots, which include acquired and sold-out audit history.
    static let maximumInventorySeeds = 10_000
    static let maximumTransactionCards = 10_000
    static let maximumInventoryItems = 50_000
    static let maximumTransactions = 20_000
    static let maximumCostAdjustments = 50_000
    static let maximumInventoryReconciliations = 20_000
    static let maximumQuantity = 1_000_000
    var version: Int
    var shows: [ShowBudgetEvent]
    var activeShowID: UUID?
    var listOutcomeUpdates: [BudgetListOutcomeUpdate]? = nil
    var inventory: [ShowInventoryItem]
    var transactions: [ShowTransactionReceipt]
    var inventorySourceLocationID: Int?
    var costAdjustments: [ShowInventoryCostAdjustment]
    var costLedgerBaseline: [ShowCostStockState]
    var costMutations: [ShowCostLedgerMutation]
    var legacyTransactionIDs: [UUID]
    var legacyReversedTransactionIDs: [UUID]
    var inventoryReconciliations: [ShowInventoryReconciliation]

    init(version: Int = 5, shows: [ShowBudgetEvent] = [], activeShowID: UUID? = nil,
         listOutcomeUpdates: [BudgetListOutcomeUpdate]? = nil, inventory: [ShowInventoryItem] = [],
         transactions: [ShowTransactionReceipt] = [], inventorySourceLocationID: Int? = nil,
         costAdjustments: [ShowInventoryCostAdjustment] = [], costLedgerBaseline: [ShowCostStockState] = [],
         costMutations: [ShowCostLedgerMutation] = [], legacyTransactionIDs: [UUID] = [],
         legacyReversedTransactionIDs: [UUID] = [], inventoryReconciliations: [ShowInventoryReconciliation] = []) {
        self.version = version; self.shows = shows; self.activeShowID = activeShowID
        self.listOutcomeUpdates = listOutcomeUpdates
        self.inventory = inventory; self.transactions = transactions; self.inventorySourceLocationID = inventorySourceLocationID
        self.costAdjustments = costAdjustments
        self.costLedgerBaseline = costLedgerBaseline; self.costMutations = costMutations
        self.legacyTransactionIDs = legacyTransactionIDs; self.legacyReversedTransactionIDs = legacyReversedTransactionIDs
        self.inventoryReconciliations = inventoryReconciliations
    }

    func validate() throws {
        guard version == 5 else { throw ShowBudgetFailure.invalidVersion }
        guard shows.count <= Self.maximumStoredShows,
              shows.filter({ $0.deletedAt == nil }).count <= Self.maximumShows,
              shows.reduce(0, { $0 + $1.entries.count }) <= Self.maximumEntriesTotal else { throw ShowBudgetFailure.capacityExceeded }
        guard activeShowID.map({ id in shows.contains { $0.id == id && $0.deletedAt == nil } }) ?? true else { throw ShowBudgetFailure.invalidBook }
        guard Set(shows.map(\.id)).count == shows.count else { throw ShowBudgetFailure.duplicateIdentity }
        let updates = listOutcomeUpdates ?? []
        guard updates.count <= Self.maximumOutcomeUpdates else { throw ShowBudgetFailure.capacityExceeded }
        guard Set(updates.map(\.id)).count == updates.count,
              Set(updates.map(\.listID)).count == updates.count else { throw ShowBudgetFailure.duplicateIdentity }
        for update in updates { try update.validate() }
        let byList = Dictionary(uniqueKeysWithValues: updates.map { ($0.listID, $0) })
        var entryIDs: Set<UUID> = [], activeOutcomeLists: Set<UUID> = []
        for show in shows {
            try show.validate()
            _ = try show.totals()
            for entry in show.entries {
                guard entryIDs.insert(entry.id).inserted else { throw ShowBudgetFailure.duplicateIdentity }
                if let operation = entry.outcomeOperationID, entry.voidedAt == nil {
                    guard let list = entry.listID, activeOutcomeLists.insert(list).inserted,
                          let update = byList[list], update.id == operation,
                          update.showID == show.id, update.entryID == entry.id else { throw ShowBudgetFailure.invalidBook }
                }
            }
        }
        for update in updates {
            if let showID = update.showID, let entryID = update.entryID {
                guard let entry = shows.first(where: { $0.id == showID })?.entries.first(where: { $0.id == entryID }),
                      entry.outcomeOperationID == update.id, entry.listID == update.listID,
                      entry.paidCents == update.calculatedPaidCents,
                      entry.grossReceivedCents == update.calculatedReceivedCents else { throw ShowBudgetFailure.invalidBook }
            }
        }
        try validateTransactions()
    }

    private enum CodingKeys: String, CodingKey {
        case version, shows, activeShowID, listOutcomeUpdates, inventory, transactions, inventorySourceLocationID, costAdjustments,
             costLedgerBaseline, costMutations, legacyTransactionIDs, legacyReversedTransactionIDs, inventoryReconciliations
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...5).contains(storedVersion) else { throw ShowBudgetFailure.invalidVersion }
        shows = try values.decode([ShowBudgetEvent].self, forKey: .shows)
        activeShowID = try values.decodeIfPresent(UUID.self, forKey: .activeShowID)
        listOutcomeUpdates = try values.decodeIfPresent([BudgetListOutcomeUpdate].self, forKey: .listOutcomeUpdates)
        inventory = try values.decodeIfPresent([ShowInventoryItem].self, forKey: .inventory) ?? []
        transactions = try values.decodeIfPresent([ShowTransactionReceipt].self, forKey: .transactions) ?? []
        inventorySourceLocationID = try values.decodeIfPresent(Int.self, forKey: .inventorySourceLocationID)
        costAdjustments = try values.decodeIfPresent([ShowInventoryCostAdjustment].self, forKey: .costAdjustments) ?? []
        if storedVersion >= 4 {
            // Required metadata distinguishes a migrated unknown checkpoint from
            // a damaged v4 ledger with its accounting or journal removed.
            costLedgerBaseline = try values.decode([ShowCostStockState].self, forKey: .costLedgerBaseline)
            costMutations = try values.decode([ShowCostLedgerMutation].self, forKey: .costMutations)
            legacyTransactionIDs = try values.decode([UUID].self, forKey: .legacyTransactionIDs)
            legacyReversedTransactionIDs = try values.decode([UUID].self, forKey: .legacyReversedTransactionIDs)
        } else {
            let unsupportedJournal = try values.decodeIfPresent([ShowCostLedgerMutation].self, forKey: .costMutations) ?? []
            guard !unsupportedJournal.contains(where: { $0.kind == .reconciliation }) else {
                throw ShowBudgetFailure.invalidVersion
            }
            costLedgerBaseline = inventory.map(ShowCostStockState.init)
            costMutations = []
            legacyTransactionIDs = transactions.map(\.id)
            legacyReversedTransactionIDs = transactions.filter { $0.reversedAt != nil }.map(\.id)
        }
        if storedVersion == 5 {
            // Required even when empty: removing v5 audit metadata is damage,
            // not a request to migrate a fresh baseline.
            inventoryReconciliations = try values.decode([ShowInventoryReconciliation].self, forKey: .inventoryReconciliations)
        } else {
            let unexpected = try values.decodeIfPresent([ShowInventoryReconciliation].self, forKey: .inventoryReconciliations) ?? []
            guard unexpected.isEmpty, inventory.allSatisfy({ $0.acquiredByReconciliationID == nil }),
                  !costMutations.contains(where: { $0.kind == .reconciliation }) else {
                throw ShowBudgetFailure.invalidVersion
            }
            inventoryReconciliations = []
        }
        if storedVersion == 1 {
            guard (listOutcomeUpdates ?? []).isEmpty,
                  shows.allSatisfy({ $0.entries.allSatisfy { $0.outcomeOperationID == nil } }) else { throw ShowBudgetFailure.invalidVersion }
            listOutcomeUpdates = nil
        }
        if storedVersion < 3 {
            guard inventory.isEmpty, transactions.isEmpty, inventorySourceLocationID == nil,
                  shows.allSatisfy({ $0.deletedAt == nil && $0.entries.allSatisfy { $0.transactionID == nil } }) else {
                throw ShowBudgetFailure.invalidVersion
            }
        }
        if storedVersion < 4 {
            guard costAdjustments.isEmpty, inventory.allSatisfy({ $0.remainingCostCents == nil }),
                  transactions.allSatisfy({ $0.accounting == nil && $0.draft.feeCents == 0 }) else {
                throw ShowBudgetFailure.invalidVersion
            }
        }
        version = 5
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(shows, forKey: .shows)
        try values.encodeIfPresent(activeShowID, forKey: .activeShowID)
        try values.encodeIfPresent(listOutcomeUpdates, forKey: .listOutcomeUpdates)
        try values.encode(inventory, forKey: .inventory)
        try values.encode(transactions, forKey: .transactions)
        try values.encodeIfPresent(inventorySourceLocationID, forKey: .inventorySourceLocationID)
        try values.encode(costAdjustments, forKey: .costAdjustments)
        try values.encode(costLedgerBaseline, forKey: .costLedgerBaseline)
        try values.encode(costMutations, forKey: .costMutations)
        try values.encode(legacyTransactionIDs, forKey: .legacyTransactionIDs)
        try values.encode(legacyReversedTransactionIDs, forKey: .legacyReversedTransactionIDs)
        try values.encode(inventoryReconciliations, forKey: .inventoryReconciliations)
    }

    private func validateTransactions() throws {
        guard inventorySourceLocationID.map({ $0 > 0 }) ?? true else { throw ShowTransactionFailure.invalidInventory }
        guard inventory.count <= Self.maximumInventoryItems, transactions.count <= Self.maximumTransactions else {
            throw ShowBudgetFailure.capacityExceeded
        }
        guard costAdjustments.count <= Self.maximumCostAdjustments else { throw ShowBudgetFailure.capacityExceeded }
        guard inventoryReconciliations.count <= Self.maximumInventoryReconciliations else { throw ShowBudgetFailure.capacityExceeded }
        guard Set(inventoryReconciliations.map(\.id)).count == inventoryReconciliations.count,
              Set(inventoryReconciliations.map(\.snapshotID)).count == inventoryReconciliations.count else {
            throw ShowBudgetFailure.duplicateIdentity
        }
        for event in inventoryReconciliations {
            try event.validate()
            guard event.sourceLocationID == inventorySourceLocationID else { throw ShowTransactionFailure.inventoryLocationConflict }
        }
        guard Set(costAdjustments.map(\.id)).count == costAdjustments.count else { throw ShowBudgetFailure.duplicateIdentity }
        guard Set(inventory.map(\.id)).count == inventory.count,
              Set(transactions.map(\.id)).count == transactions.count else { throw ShowBudgetFailure.invalidBook }
        let stock = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        for adjustment in costAdjustments {
            try adjustment.validate()
            guard let item = stock[adjustment.inventoryID], adjustment.recordedAt >= item.acquiredAt else {
                throw ShowTransactionFailure.invalidCost
            }
        }
        let receipts = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let reconciliations = Dictionary(uniqueKeysWithValues: inventoryReconciliations.map { ($0.id, $0) })
        let reconciliationItems = Dictionary(uniqueKeysWithValues: inventoryReconciliations.map { ($0.id, Set($0.createdInventoryIDs)) })
        let positions = Dictionary(uniqueKeysWithValues: transactions.enumerated().map { ($0.element.id, $0.offset) })
        let entries = shows.flatMap { show in show.entries.map { (show.id, $0) } }
        let cash = Dictionary(uniqueKeysWithValues: entries.filter { $0.1.transactionID != nil }.map { ($0.1.id, $0) })
        guard cash.count == transactions.count else { throw ShowBudgetFailure.invalidBook }
        var sources = Set<Int>(), activeLists = Set<UUID>(), consumed: [UUID: Int] = [:]
        for item in inventory {
            guard (0...Self.maximumQuantity).contains(item.quantity), ShowTransactionMath.validCard(item.card),
                  item.remainingCostCents.map(ShowBudgetMoney.isValid) ?? true,
                  item.quantity != 0 || item.remainingCostCents == nil || item.remainingCostCents == 0,
                  item.acquiredAt.timeIntervalSince1970.isFinite else { throw ShowTransactionFailure.invalidInventory }
            if let transaction = item.acquiredByTransactionID {
                guard item.sourceInventoryID == nil, item.sourceLocationID == nil, item.acquiredByReconciliationID == nil,
                      let receipt = receipts[transaction], item.acquiredAt == receipt.recordedAt,
                      receipt.incoming.contains(where: { $0.inventoryID == item.id && $0.card == item.card }) else {
                    throw ShowTransactionFailure.invalidInventory
                }
            } else if let operation = item.acquiredByReconciliationID {
                guard let event = reconciliations[operation], reconciliationItems[operation]?.contains(item.id) == true,
                      item.sourceInventoryID.map({ $0 > 0 }) == true,
                      item.sourceLocationID == inventorySourceLocationID, item.acquiredAt == event.recordedAt else {
                    throw ShowTransactionFailure.invalidInventory
                }
            } else {
                guard let source = item.sourceInventoryID, source > 0, let location = inventorySourceLocationID,
                      item.sourceLocationID == location, sources.insert(source).inserted else { throw ShowTransactionFailure.invalidInventory }
            }
            if let adoptedFrom = item.adoptedFromInventoryID {
                guard adoptedFrom != item.id, item.acquiredByReconciliationID != nil,
                      item.acquiredByTransactionID == nil, let origin = stock[adoptedFrom],
                      origin.acquiredByTransactionID != nil, origin.card.identity == item.card.identity else {
                    throw ShowTransactionFailure.invalidInventory
                }
            }
        }
        guard sources.count <= Self.maximumInventorySeeds else { throw ShowBudgetFailure.capacityExceeded }
        for receipt in transactions {
            guard let (showID, entry) = cash[receipt.id], showID == receipt.showID,
                  entry.transactionID == receipt.id, entry.kind == receipt.kind.budgetKind,
                  entry.paidCents == receipt.paidCents, entry.grossReceivedCents == receipt.receivedCents,
                  entry.feeCents == receipt.feeCents,
                  entry.recordedAt == receipt.recordedAt, entry.voidedAt == receipt.reversedAt,
                  entry.listID == receipt.incomingListID, entry.listName == receipt.incomingListName,
                  entry.note == receipt.draft.note, entry.splitBasis == .grossProceeds,
                  receipt.kind == .sale || entry.reinvestmentPercent == 100 else { throw ShowBudgetFailure.invalidBook }
            try receipt.validate(saleReinvestmentPercent: entry.reinvestmentPercent)
            if receipt.reversedAt == nil, let listID = receipt.incomingListID {
                guard activeLists.insert(listID).inserted else { throw ShowBudgetFailure.duplicateIdentity }
            }
            for line in receipt.incoming {
                guard let item = stock[line.inventoryID], item.acquiredByTransactionID == receipt.id,
                      item.card == line.card else { throw ShowBudgetFailure.invalidBook }
            }
            for line in receipt.outgoing {
                guard let item = stock[line.inventoryID], item.card == line.card else { throw ShowBudgetFailure.invalidBook }
                if let acquisition = item.acquiredByTransactionID {
                    guard let prior = receipts[acquisition], let priorPosition = positions[acquisition],
                          let position = positions[receipt.id], priorPosition < position,
                          receipt.recordedAt >= prior.recordedAt,
                          receipt.reversedAt != nil || prior.reversedAt == nil else { throw ShowBudgetFailure.invalidBook }
                }
                if receipt.reversedAt == nil {
                    let count = (consumed[line.inventoryID] ?? 0).addingReportingOverflow(line.quantity)
                    guard !count.overflow, count.partialValue <= Self.maximumQuantity else { throw ShowBudgetFailure.invalidBook }
                    consumed[line.inventoryID] = count.partialValue
                }
            }
        }
        var reconciledQuantities: [UUID: Int] = [:]
        for mutation in costMutations where mutation.kind == .reconciliation {
            for change in mutation.changes {
                // Decoded journal quantities are untrusted until replay. Check
                // them before calculating deltas so damage cannot trap Int.
                try change.after.validate()
                try change.before?.validate()
                let delta = change.after.quantity.subtractingReportingOverflow(change.before?.quantity ?? 0)
                guard !delta.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
                let total = (reconciledQuantities[change.after.id] ?? 0).addingReportingOverflow(delta.partialValue)
                guard !total.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
                reconciledQuantities[change.after.id] = total.partialValue
            }
        }
        for item in inventory {
            let used = consumed[item.id] ?? 0
            if let transaction = item.acquiredByTransactionID, let receipt = receipts[transaction],
               let line = receipt.incoming.first(where: { $0.inventoryID == item.id }) {
                let original = receipt.reversedAt == nil ? line.quantity : 0
                let authoritative = original.addingReportingOverflow(reconciledQuantities[item.id] ?? 0)
                guard !authoritative.overflow, authoritative.partialValue >= used,
                      item.quantity == authoritative.partialValue - used else { throw ShowTransactionFailure.invalidInventory }
            } else {
                guard item.quantity <= Self.maximumQuantity - used else { throw ShowTransactionFailure.invalidInventory }
            }
        }
        // Legacy and stock commands must never both consume the same incoming list.
        for listID in activeLists {
            guard !entries.contains(where: { $0.1.transactionID == nil && $0.1.listID == listID && $0.1.voidedAt == nil &&
                ($0.1.paidCents > 0 || $0.1.grossReceivedCents > 0 || $0.1.kind == .purchase || $0.1.kind == .trade) }),
                  !(listOutcomeUpdates ?? []).contains(where: { $0.listID == listID &&
                    ($0.outcomeKind == .purchase || $0.outcomeKind == .trade || $0.outcomeKind == .tradeAndPurchase) }) else {
                throw ShowBudgetFailure.invalidBook
            }
        }
        try validateCostLedger()
    }
}
