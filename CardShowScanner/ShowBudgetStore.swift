import Foundation
import Observation

enum ShowBudgetStoreFailure: LocalizedError, Equatable, Sendable {
    case notLoaded, saving, showNotFound, entryNotFound, conflictingEntry, outsideShowDates, fileTooLarge, loadFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The saved show budget could not be opened. Retry loading it before making changes. Your existing file has been kept."
        case .saving: return "The show budget is already being saved."
        case .showNotFound: return "This show budget is no longer available. Reopen the show and retry."
        case .outsideShowDates: return "This show budget applies only during its scheduled dates. Choose an active show or update its dates before recording cash."
        case .entryNotFound: return "This budget entry is no longer available. Reopen the show and retry."
        case .conflictingEntry: return "This transaction was already recorded with different details. Review the existing entry before adding another."
        case .fileTooLarge: return "The saved show budget is too large to open or update safely. The original file has been kept."
        case .loadFailed: return "The saved show budget could not be opened. Your existing file has been kept. Retry after storage becomes available."
        case .saveFailed: return "The show budget was not saved. Your entries and selections have been kept; retry saving."
        }
    }
}

/// Independent, versioned financial records. Changes are published only after
/// an atomic file write. List-outcome commands coordinate their recoverable
/// SwiftData projection without a second financial charge.
@MainActor @Observable final class ShowBudgetStore {
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void
    typealias Clock = @MainActor () -> Date

    static let shared = ShowBudgetStore()
    static let maximumBytes = 8 * 1_024 * 1_024

    private(set) var book = ShowBudgetBook()
    private(set) var error: String?
    private(set) var isLoaded = false
    private(set) var isSaving = false

    var activeShow: ShowBudgetEvent? {
        guard isLoaded, let id = book.activeShowID else { return nil }
        return book.shows.first { $0.id == id }
    }

    private let url: URL
    private let read: Reader
    private let write: Writer
    private let now: Clock
    let calendar: Calendar

    var currentDate: Date { now() }

    /// Selection remains available for review; funds apply only on show days.
    var eligibleActiveShow: ShowBudgetEvent? {
        guard let show = activeShow, show.applies(on: now(), calendar: calendar) else { return nil }
        return show
    }

    func canRecord(showID: UUID) -> Bool {
        guard isLoaded, let show = book.shows.first(where: { $0.id == showID }) else { return false }
        return show.applies(on: now(), calendar: calendar)
    }

    init(url: URL? = nil, read: Reader? = nil, write: Writer? = nil,
         now: @escaping Clock = Date.init, calendar: Calendar = .current) {
        self.url = url ?? Self.defaultURL
        self.read = read ?? Self.readFile
        self.write = write ?? Self.writeFile
        self.now = now; self.calendar = calendar
        reload()
    }

    func reload() {
        guard !isSaving else { return }
        do {
            let next: ShowBudgetBook
            if let data = try read(url) {
                guard data.count <= Self.maximumBytes else { throw ShowBudgetStoreFailure.fileTooLarge }
                next = try JSONDecoder().decode(ShowBudgetBook.self, from: data)
            } else { next = ShowBudgetBook() }
            try next.validate()
            book = next
            isLoaded = true
            error = nil
        } catch {
            // Never replace an unreadable file with an empty/default budget.
            // Retain any in-memory book, but block financial changes until a
            // successful reload establishes the current durable state.
            isLoaded = false
            self.error = (error as? ShowBudgetStoreFailure)?.errorDescription
                ?? ShowBudgetStoreFailure.loadFailed.errorDescription
            DiagnosticLog.shared.record("budget.load_failed")
        }
    }

    @discardableResult
    func create(name: String, startingCents: Int64, startDate: Date? = nil, endDate: Date? = nil) throws -> UUID {
        try requireWritable()
        let show = ShowBudgetEvent(name: name.trimmingCharacters(in: .whitespacesAndNewlines), startingCents: startingCents,
                                   startDate: startDate, endDate: endDate)
        var next = book
        next.shows.append(show)
        next.activeShowID = show.id
        try commit(next)
        return show.id
    }

    func select(showID: UUID?) throws {
        try requireWritable()
        guard showID == nil || book.shows.contains(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        guard book.activeShowID != showID else { return }
        var next = book
        next.activeShowID = showID
        try commit(next)
    }

    func update(showID: UUID, name: String, startingCents: Int64) throws {
        try requireWritable()
        guard let show = book.shows.first(where: { $0.id == showID }) else { throw ShowBudgetStoreFailure.showNotFound }
        try update(showID: showID, name: name, startingCents: startingCents, startDate: show.startDate, endDate: show.endDate)
    }

    func update(showID: UUID, name: String, startingCents: Int64, startDate: Date?, endDate: Date?) throws {
        try requireWritable()
        guard let index = book.shows.firstIndex(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard book.shows[index].name != trimmed || book.shows[index].startingCents != startingCents ||
                book.shows[index].startDate != startDate || book.shows[index].endDate != endDate else { return }
        var next = book
        next.shows[index].name = trimmed
        next.shows[index].startingCents = startingCents
        next.shows[index].startDate = startDate; next.shows[index].endDate = endDate
        try commit(next)
    }

    func record(_ entry: ShowBudgetEntry, showID: UUID) throws {
        try requireWritable()
        guard let index = book.shows.firstIndex(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        for show in book.shows {
            if let existing = show.entries.first(where: { $0.id == entry.id }) {
                guard show.id == showID, existing == entry else { throw ShowBudgetStoreFailure.conflictingEntry }
                return // The exact same confirmation/retry has already committed.
            }
        }
        // Recheck at commit time: an open form or a midnight boundary must not
        // post cash outside the scheduled days. Exact committed retries above
        // remain idempotent even after the show has ended.
        guard book.shows[index].applies(on: now(), calendar: calendar) else {
            throw ShowBudgetStoreFailure.outsideShowDates
        }
        var next = book
        next.shows[index].entries.append(entry)
        try commit(next)
    }

    func void(entryID: UUID, showID: UUID, now: Date = .now) throws {
        try requireWritable()
        guard let show = book.shows.firstIndex(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        guard let entry = book.shows[show].entries.firstIndex(where: { $0.id == entryID }) else {
            throw ShowBudgetStoreFailure.entryNotFound
        }
        guard book.shows[show].entries[entry].voidedAt == nil else { return }
        var next = book
        next.shows[show].entries[entry].voidedAt = now
        try commit(next)
    }

    /// Budget cash and its pending SwiftData projection share this one durable
    /// write. Repeated semantic requests reuse the original operation before
    /// today's date is checked, so old committed cash is never charged twice.
    func applyListOutcome(_ request: ListBudgetOutcomeRequest) throws -> BudgetListOutcomeUpdate {
        try requireWritable()
        guard !request.listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.listName.count <= 250 else { throw ShowBudgetFailure.invalidBook }
        let candidate = BudgetListOutcomeUpdate(id: UUID(), listID: request.listID,
            desiredOutcomeData: request.desiredOutcomeData, calculatedPaidCents: request.paidCents,
            calculatedReceivedCents: request.receivedCents, createdAt: request.recordedAt,
            showID: nil, entryID: nil, disposition: request.hasCash ? .noApplicableShow : .noCash, mirrored: false)
        try candidate.validate()
        guard candidate.outcomeKind == request.kind else { throw ShowBudgetFailure.invalidBook }
        if let previous = book.listOutcomeUpdates?.first(where: { $0.listID == request.listID }) {
            let same = previous.outcomeKind == request.kind && previous.calculatedPaidCents == request.paidCents &&
                previous.calculatedReceivedCents == request.receivedCents
            if same {
                if !previous.mirrored { return previous }
                if previous.disposition == .noApplicableShow {
                    if eligibleActiveShow == nil { return previous }
                } else if let entryID = previous.entryID {
                    if book.shows.contains(where: { $0.entries.contains { $0.id == entryID && $0.voidedAt == nil } }) { return previous }
                } else { return previous }
            }
            guard previous.mirrored else { throw ShowBudgetStoreFailure.conflictingEntry }
        }
        let priorAuto = book.shows.flatMap(\.entries).filter {
            $0.listID == request.listID && $0.outcomeOperationID != nil && $0.voidedAt == nil
        }
        let manualCash = book.shows.flatMap(\.entries).contains {
            $0.listID == request.listID && $0.outcomeOperationID == nil && $0.voidedAt == nil &&
                ($0.paidCents > 0 || $0.grossReceivedCents > 0)
        }
        if request.hasCash && manualCash { throw ListBudgetOutcomeFailure.manualReceiptExists }
        let target = request.hasCash ? eligibleActiveShow : nil
        if let target, request.hasCash, book.shows.contains(where: { show in
            show.id != target.id && show.entries.contains { $0.listID == request.listID && $0.outcomeOperationID != nil && $0.voidedAt == nil }
        }) { throw ListBudgetOutcomeFailure.differentShowReplacement }
        if request.hasCash && target == nil && !priorAuto.isEmpty {
            throw ListBudgetOutcomeFailure.noApplicableShowForReplacement
        }
        var next = book
        // Zero-cash corrections are allowed after the original show's dates.
        // They reverse only this app's auto receipts, never manual cash records.
        for show in next.shows.indices {
            for entry in next.shows[show].entries.indices {
                let old = next.shows[show].entries[entry]
                if old.listID == request.listID && old.outcomeOperationID != nil && old.voidedAt == nil {
                    next.shows[show].entries[entry].voidedAt = max(request.recordedAt, old.recordedAt)
                }
            }
        }
        var showID: UUID?, entryID: UUID?
        let disposition: BudgetListOutcomeUpdate.Disposition
        if let target, let index = next.shows.firstIndex(where: { $0.id == target.id }) {
            let receipt = ShowBudgetEntry(id: candidate.id, kind: request.kind == .purchase ? .purchase : .trade,
                paidCents: request.paidCents, grossReceivedCents: request.receivedCents,
                reinvestmentPercent: target.reinvestmentPercent, splitBasis: .grossProceeds,
                recordedAt: request.recordedAt, listID: request.listID, listName: request.listName,
                note: "Recorded from list outcome", outcomeOperationID: candidate.id)
            next.shows[index].entries.append(receipt)
            showID = target.id; entryID = receipt.id; disposition = .applied
        } else if request.hasCash { disposition = .noApplicableShow }
        else if manualCash { disposition = .manualCashPreserved }
        else { disposition = priorAuto.isEmpty ? .noCash : .applied }
        let update = BudgetListOutcomeUpdate(id: candidate.id, listID: request.listID,
            desiredOutcomeData: request.desiredOutcomeData, calculatedPaidCents: request.paidCents,
            calculatedReceivedCents: request.receivedCents, createdAt: request.recordedAt,
            showID: showID, entryID: entryID, disposition: disposition, mirrored: false)
        var updates = next.listOutcomeUpdates ?? []
        updates.removeAll { $0.listID == request.listID }; updates.append(update)
        next.listOutcomeUpdates = updates
        try commit(next)
        DiagnosticLog.shared.record("list.outcome_budget_committed", ["phase": "budget", "reason": disposition.rawValue])
        return update
    }

    func acknowledgeListOutcome(_ operationID: UUID) throws {
        try requireWritable()
        guard let index = book.listOutcomeUpdates?.firstIndex(where: { $0.id == operationID }),
              book.listOutcomeUpdates?[index].mirrored == false else { return }
        var next = book
        next.listOutcomeUpdates?[index].mirrored = true
        try commit(next)
    }

    private func requireWritable() throws {
        guard isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
        guard !isSaving else { throw ShowBudgetStoreFailure.saving }
    }

    private func commit(_ next: ShowBudgetBook) throws {
        try requireWritable()
        isSaving = true
        defer { isSaving = false }
        do {
            try next.validate()
            let data = try JSONEncoder().encode(next)
            guard data.count <= Self.maximumBytes else { throw ShowBudgetStoreFailure.fileTooLarge }
            do { try write(data, url) }
            catch { throw ShowBudgetStoreFailure.saveFailed }
            book = next
            error = nil
            DiagnosticLog.shared.record("budget.saved")
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? ShowBudgetStoreFailure.saveFailed.errorDescription
            DiagnosticLog.shared.record("budget.save_failed")
            throw error
        }
    }

    private static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("show-budgets.json", isDirectory: false)
    }

    private static func readFile(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw ShowBudgetStoreFailure.loadFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ShowBudgetStoreFailure.loadFailed }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes) else {
            throw ShowBudgetStoreFailure.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw ShowBudgetStoreFailure.fileTooLarge }
        return data
    }

    private static func writeFile(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Application Support remains included in device backups. Budget and
        // transaction records are user data, not disposable caches.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
