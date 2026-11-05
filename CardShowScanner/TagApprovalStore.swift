import Foundation
import Observation

/// Per-copy pricing settings. A missing profit target remains unknown until the
/// user chooses one; it must never silently become a zero-profit policy.
struct TagPricingPreferences: Codable, Equatable, Sendable {
    var minimumDesiredProfitCents: Int64? = nil
    var allocatedExpensesCents: Int64 = 0
    var fixedPaymentFeeCents: Int64 = 0
    /// A fraction, for example 0.029 for a 2.9% payment fee.
    var percentagePaymentFee: Decimal = 0
    var enableTwoFiveForNine = false
    var enableThreeFiveForThirteen = false
    var allowPromotionStacking = false

    /// Use the same first-copy remainder allocation as an actual checkout.
    /// For a bundle, averaging its consumed basis lets the bundle calculation
    /// recover the exact selected total without rounding every copy upward.
    func profitInputs(for item: ShowInventoryItem, quantity: Int = 1) -> TagProfitInputs {
        let acquisitionCost: Decimal?
        if quantity > 0,
           let cents = try? ShowCostBasisMath.consumedCost(totalCostCents: item.remainingCostCents,
                quantity: item.quantity, consumedQuantity: quantity) {
            acquisitionCost = ShowBudgetMoney.decimal(cents) / Decimal(quantity)
        } else {
            acquisitionCost = nil
        }
        return TagProfitInputs(acquisitionCost: acquisitionCost,
            allocatedExpenses: ShowBudgetMoney.decimal(allocatedExpensesCents),
            minimumDesiredProfit: minimumDesiredProfitCents.map(ShowBudgetMoney.decimal),
            fixedPaymentFee: ShowBudgetMoney.decimal(fixedPaymentFeeCents),
            percentagePaymentFee: percentagePaymentFee)
    }

    fileprivate func validate() throws {
        guard minimumDesiredProfitCents.map(ShowBudgetMoney.isValid) ?? true,
              ShowBudgetMoney.isValid(allocatedExpensesCents),
              ShowBudgetMoney.isValid(fixedPaymentFeeCents),
              !percentagePaymentFee.isNaN,
              percentagePaymentFee >= 0, percentagePaymentFee < 1 else {
            throw TagApprovalStoreFailure.invalidPreferences
        }
    }
}

struct TagApprovalRequest: Equatable, Sendable {
    let id: UUID
    let approvedTag: StickerPrice
    let currentMarket: Decimal?
    let isManualOverride: Bool

    init(id: UUID, approvedTag: StickerPrice, currentMarket: Decimal?, isManualOverride: Bool = false) {
        self.id = id
        self.approvedTag = approvedTag
        self.currentMarket = currentMarket
        self.isManualOverride = isManualOverride
    }
}

/// Approval and physical-label history are separate from financial receipts.
struct TagApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var approvedTag: StickerPrice
    /// Identifies this price cycle so an older completed queue cannot confirm
    /// a later return to the same numeric tag.
    var priceRevisionID: UUID
    var marketAtLastApproval: Decimal?
    var isManualOverride: Bool
    var approvedAt: Date
    var lastPrintedTag: StickerPrice?
    var lastPrintedAt: Date?

    var needsLabels: Bool {
        approvedTag.integerPriceCents != nil && approvedTag != lastPrintedTag
    }
}

enum TagApprovalStoreFailure: LocalizedError, Equatable, Sendable {
    case notLoaded, invalidApproval, invalidPreferences, invalidSelection
    case duplicateIdentity, tooManyRecords, invalidVersion, fileTooLarge, loadFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Saved tag approvals are unavailable. Retry loading them before making changes. Your saved file has been kept."
        case .invalidApproval:
            return "Review the approved tags and market values. Individual tags must use nonnegative whole-dollar prices."
        case .invalidPreferences:
            return "Enter valid nonnegative pricing costs and a payment percentage below 100%."
        case .invalidSelection:
            return "Select approved individual tags before marking them labeled."
        case .duplicateIdentity:
            return "Tag approvals contain a duplicate inventory identifier. Your saved file has been kept."
        case .tooManyRecords:
            return "There are too many saved tag approvals to update safely. Your saved file has been kept."
        case .invalidVersion:
            return "This saved tag approval file uses an unsupported format. Your saved file has been kept."
        case .fileTooLarge:
            return "The saved tag approval file is too large to open or update safely. Your saved file has been kept."
        case .loadFailed:
            return "Saved tag approvals could not be opened. Retry loading them. Your saved file has been kept."
        case .saveFailed:
            return "Tag approvals could not be saved. Reload them before continuing."
        }
    }
}

private struct TagApprovalFile: Codable {
    var version = 1
    var records: [TagApprovalRecord] = []
    var preferences = TagPricingPreferences()
}

/// Only explicit approval changes the market baseline. Loading a quote or an old
/// print queue never creates an approval, and queue cleanup never erases history.
@MainActor @Observable final class TagApprovalStore {
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void
    typealias Clock = @MainActor () -> Date

    static let shared = TagApprovalStore()
    static let maximumRecords = 100_000
    static let maximumBytes = 32 * 1_024 * 1_024

    private(set) var records: [TagApprovalRecord] = []
    private(set) var preferences = TagPricingPreferences()
    private(set) var isLoaded = false
    private(set) var error: String?
    @ObservationIgnored private var recordsByID: [UUID: TagApprovalRecord] = [:]

    private let url: URL
    private let read: Reader
    private let write: Writer
    private let now: Clock

    init(url: URL? = nil, read: Reader? = nil, write: Writer? = nil, now: @escaping Clock = { Date() }) {
        self.url = url ?? Self.defaultURL
        self.read = read ?? Self.readFile
        self.write = write ?? Self.writeFile
        self.now = now
        reload()
    }

    func record(for id: UUID) -> TagApprovalRecord? {
        // Register the observable collection read while keeping repeated row
        // lookups constant-time during inventory pricing and sorting.
        _ = records
        return recordsByID[id]
    }

    func reload() {
        do {
            var saved = TagApprovalFile()
            if let data = try read(url) {
                guard data.count <= Self.maximumBytes else { throw TagApprovalStoreFailure.fileTooLarge }
                saved = try JSONDecoder().decode(TagApprovalFile.self, from: data)
                guard saved.version == 1 else { throw TagApprovalStoreFailure.invalidVersion }
                try Self.validate(saved.records, preferences: saved.preferences)
            }
            publishRecords(saved.records)
            preferences = saved.preferences
            isLoaded = true
            error = nil
        } catch {
            isLoaded = false
            self.error = (error as? TagApprovalStoreFailure)?.errorDescription
                ?? TagApprovalStoreFailure.loadFailed.errorDescription
        }
    }

    /// Every approval resets the baseline to the current quote, including a
    /// retained tag or manual override. Explicit physical-sticker confirmations
    /// can be saved in the same atomic update. Only changed tag values are returned.
    @discardableResult
    func approve(_ requests: [TagApprovalRequest], keepingExistingStickerIDs: Set<UUID> = []) throws -> [UUID] {
        try requireWritable()
        let requestIDs = Set(requests.map(\.id))
        guard requestIDs.count == requests.count else {
            throw TagApprovalStoreFailure.duplicateIdentity
        }
        guard keepingExistingStickerIDs.isSubset(of: requestIDs) else {
            throw TagApprovalStoreFailure.invalidSelection
        }
        for request in requests {
            try Self.validate(tag: request.approvedTag)
            try Self.validate(market: request.currentMarket)
            guard !keepingExistingStickerIDs.contains(request.id) || request.approvedTag.integerPriceCents != nil else {
                throw TagApprovalStoreFailure.invalidSelection
            }
        }
        guard !requests.isEmpty else { return [] }
        let timestamp = now()
        var next = records
        let indicesByID = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.id, $0.offset) })
        var changed: [UUID] = []
        for request in requests {
            let index: Int
            if let existing = indicesByID[request.id] {
                index = existing
                if next[index].approvedTag != request.approvedTag {
                    changed.append(request.id)
                    next[index].priceRevisionID = UUID()
                }
                next[index].approvedTag = request.approvedTag
                next[index].marketAtLastApproval = request.currentMarket
                next[index].isManualOverride = request.isManualOverride
                next[index].approvedAt = timestamp
            } else {
                index = next.count
                changed.append(request.id)
                next.append(TagApprovalRecord(id: request.id, approvedTag: request.approvedTag, priceRevisionID: UUID(),
                    marketAtLastApproval: request.currentMarket, isManualOverride: request.isManualOverride,
                    approvedAt: timestamp, lastPrintedTag: nil, lastPrintedAt: nil))
            }
            if keepingExistingStickerIDs.contains(request.id), next[index].needsLabels {
                next[index].lastPrintedTag = next[index].approvedTag
                next[index].lastPrintedAt = timestamp
            }
        }
        try commit(next, preferences: preferences)
        return changed
    }

    func updatePreferences(_ next: TagPricingPreferences) throws {
        try requireWritable()
        try next.validate()
        guard next != preferences else { return }
        try commit(records, preferences: next)
    }

    /// A lot is labeled after every queued copy at its current approved price
    /// completes in its current price cycle. Legacy queues and older cycles
    /// cannot acknowledge a newer approval, even at the same numeric price.
    func observeCompletedQueue(_ entries: [LabelQueueEntry]) throws {
        let inventoryEntries = entries.filter { $0.source != .custom }
        // Standalone labels have no acquisition or sticker approval history.
        // They must also work when the unrelated approval file is unavailable.
        guard !inventoryEntries.isEmpty else { return }
        try requireWritable()
        var grouped: [UUID: [LabelQueueEntry]] = [:]
        for entry in inventoryEntries {
            guard let inventoryID = entry.inventoryID else { throw TagApprovalStoreFailure.invalidSelection }
            grouped[inventoryID, default: []].append(entry)
        }
        var next = records
        let timestamp = now()
        var changed = false
        for index in next.indices where next[index].needsLabels {
            guard let cents = next[index].approvedTag.integerPriceCents,
                  let lotEntries = grouped[next[index].id] else { continue }
            let matching = lotEntries.filter {
                $0.priceCents == cents && $0.pricingRevisionID == next[index].priceRevisionID
            }
            guard !matching.isEmpty, matching.allSatisfy({ $0.state == .completed }) else { continue }
            next[index].lastPrintedTag = next[index].approvedTag
            next[index].lastPrintedAt = timestamp
            changed = true
        }
        if changed { try commit(next, preferences: preferences) }
    }

    /// An explicit physical-label confirmation for cards labeled outside the queue.
    func markLabeled(ids: Set<UUID>) throws {
        try requireWritable()
        let indices = records.indices.filter { ids.contains(records[$0].id) }
        guard !ids.isEmpty, indices.count == ids.count,
              indices.allSatisfy({ records[$0].approvedTag.integerPriceCents != nil }) else {
            throw TagApprovalStoreFailure.invalidSelection
        }
        var next = records
        let timestamp = now()
        var changed = false
        for index in indices where next[index].needsLabels {
            next[index].lastPrintedTag = next[index].approvedTag
            next[index].lastPrintedAt = timestamp
            changed = true
        }
        if changed { try commit(next, preferences: preferences) }
    }

    private func requireWritable() throws {
        guard isLoaded else { throw TagApprovalStoreFailure.notLoaded }
    }

    private func commit(_ next: [TagApprovalRecord], preferences: TagPricingPreferences) throws {
        try Self.validate(next, preferences: preferences)
        let data = try JSONEncoder().encode(TagApprovalFile(records: next, preferences: preferences))
        guard data.count <= Self.maximumBytes else { throw TagApprovalStoreFailure.fileTooLarge }
        do {
            try write(data, url)
            publishRecords(next)
            self.preferences = preferences
            error = nil
        } catch {
            isLoaded = false
            self.error = TagApprovalStoreFailure.saveFailed.errorDescription
            throw TagApprovalStoreFailure.saveFailed
        }
    }

    private func publishRecords(_ next: [TagApprovalRecord]) {
        records = next
        recordsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
    }

    private static func validate(_ records: [TagApprovalRecord], preferences: TagPricingPreferences) throws {
        guard records.count <= maximumRecords else { throw TagApprovalStoreFailure.tooManyRecords }
        guard Set(records.map(\.id)).count == records.count else { throw TagApprovalStoreFailure.duplicateIdentity }
        try preferences.validate()
        for record in records {
            try validate(tag: record.approvedTag)
            try validate(market: record.marketAtLastApproval)
            if let tag = record.lastPrintedTag { try validate(tag: tag) }
            guard validDate(record.approvedAt),
                  (record.lastPrintedTag == nil) == (record.lastPrintedAt == nil),
                  record.lastPrintedAt.map(validDate) ?? true else {
                throw TagApprovalStoreFailure.invalidApproval
            }
        }
    }

    private static func validate(tag: StickerPrice) throws {
        if let cents = tag.integerPriceCents {
            guard ShowBudgetMoney.isValid(cents), cents % 100 == 0 else {
                throw TagApprovalStoreFailure.invalidApproval
            }
        }
    }

    private static func validate(market: Decimal?) throws {
        guard let market else { return }
        guard !market.isNaN, market >= 0,
              market <= ShowBudgetMoney.decimal(ShowBudgetMoney.maximumCents) else {
            throw TagApprovalStoreFailure.invalidApproval
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }

    private static var defaultURL: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-transactions-ui-fixture") {
            let prefix = "--show-transactions-fixture-id="
            let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            let token = argument.flatMap { UUID(uuidString: String($0.dropFirst(prefix.count))) } ?? UUID()
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ShowTransactionsFixture-" + token.uuidString, isDirectory: true)
                .appendingPathComponent("tag-approvals.json")
        }
        #endif
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("CardShowScanner", isDirectory: true)
            .appendingPathComponent("tag-approvals.json")
    }

    private static func readFile(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw TagApprovalStoreFailure.loadFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TagApprovalStoreFailure.loadFailed }
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else {
            throw TagApprovalStoreFailure.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw TagApprovalStoreFailure.fileTooLarge }
        return data
    }

    private static func writeFile(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
