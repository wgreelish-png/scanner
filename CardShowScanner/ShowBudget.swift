import Foundation

enum ShowBudgetFailure: LocalizedError, Equatable, Sendable {
    case invalidAmount, invalidEntry, invalidEvent, invalidDates, invalidBook, duplicateIdentity, invalidVersion, arithmeticOverflow
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

/// Actual cash movement only. Card market values and offers never enter this ledger.
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

    init(id: UUID = UUID(), kind: ShowBudgetEntryKind, paidCents: Int64 = 0,
         grossReceivedCents: Int64 = 0, feeCents: Int64 = 0, reinvestmentPercent: Int = 65,
         splitBasis: ShowBudgetSplitBasis = .grossProceeds, recordedAt: Date = Date(),
         listID: UUID? = nil, listName: String? = nil, note: String = "", voidedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.paidCents = paidCents
        self.grossReceivedCents = grossReceivedCents; self.feeCents = feeCents
        self.reinvestmentPercent = reinvestmentPercent; self.splitBasis = splitBasis
        self.recordedAt = recordedAt; self.listID = listID; self.listName = listName
        self.note = note; self.voidedAt = voidedAt
    }

    func validate() throws {
        guard [paidCents, grossReceivedCents, feeCents].allSatisfy(ShowBudgetMoney.isValid),
              feeCents <= grossReceivedCents, !(paidCents > 0 && grossReceivedCents > 0),
              (0...100).contains(reinvestmentPercent), recordedAt.timeIntervalSince1970.isFinite,
              note.count <= 1_000, listName.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 250 }) ?? true,
              voidedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= recordedAt }) ?? true else {
            throw ShowBudgetFailure.invalidEntry
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

struct ShowBudgetEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var startingCents: Int64
    var reinvestmentPercent: Int
    var createdAt: Date
    var entries: [ShowBudgetEntry]
    var startDate: Date?
    var endDate: Date?

    init(id: UUID = UUID(), name: String, startingCents: Int64, reinvestmentPercent: Int = 65,
         createdAt: Date = Date(), entries: [ShowBudgetEntry] = [], startDate: Date? = nil, endDate: Date? = nil) {
        self.id = id; self.name = name; self.startingCents = startingCents
        self.reinvestmentPercent = reinvestmentPercent; self.createdAt = createdAt; self.entries = entries
        self.startDate = startDate; self.endDate = endDate
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              ShowBudgetMoney.isValid(startingCents), (0...100).contains(reinvestmentPercent),
              createdAt.timeIntervalSince1970.isFinite, entries.count <= ShowBudgetBook.maximumEntriesPerShow else {
            throw ShowBudgetFailure.invalidEvent
        }
        if let startDate, let endDate {
            guard startDate.timeIntervalSince1970.isFinite, endDate.timeIntervalSince1970.isFinite,
                  endDate >= startDate else { throw ShowBudgetFailure.invalidDates }
        } else if startDate != nil || endDate != nil { throw ShowBudgetFailure.invalidDates }
        guard Set(entries.map(\.id)).count == entries.count else { throw ShowBudgetFailure.duplicateIdentity }
        for entry in entries { try entry.validate() }
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
    static let maximumShows = 100
    static let maximumEntriesPerShow = 10_000
    static let maximumEntriesTotal = 20_000
    var version: Int
    var shows: [ShowBudgetEvent]
    var activeShowID: UUID?

    init(version: Int = 1, shows: [ShowBudgetEvent] = [], activeShowID: UUID? = nil) {
        self.version = version; self.shows = shows; self.activeShowID = activeShowID
    }

    func validate() throws {
        guard version == 1 else { throw ShowBudgetFailure.invalidVersion }
        guard shows.count <= Self.maximumShows,
              shows.reduce(0, { $0 + $1.entries.count }) <= Self.maximumEntriesTotal,
              activeShowID.map({ id in shows.contains { $0.id == id } }) ?? true else { throw ShowBudgetFailure.invalidBook }
        guard Set(shows.map(\.id)).count == shows.count else { throw ShowBudgetFailure.duplicateIdentity }
        var entryIDs: Set<UUID> = []
        for show in shows {
            try show.validate()
            _ = try show.totals()
            for entry in show.entries {
                guard entryIDs.insert(entry.id).inserted else { throw ShowBudgetFailure.duplicateIdentity }
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case version, shows, activeShowID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        shows = try values.decode([ShowBudgetEvent].self, forKey: .shows)
        activeShowID = try values.decodeIfPresent(UUID.self, forKey: .activeShowID)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(shows, forKey: .shows)
        try values.encodeIfPresent(activeShowID, forKey: .activeShowID)
    }
}
