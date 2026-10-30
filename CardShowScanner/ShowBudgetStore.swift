import Foundation
import Observation

enum ShowBudgetStoreFailure: LocalizedError, Equatable, Sendable {
    case notLoaded, saving, showNotFound, entryNotFound, conflictingEntry, fileTooLarge, loadFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The saved show budget could not be opened. Retry loading it before making changes. Your existing file has been kept."
        case .saving: return "The show budget is already being saved."
        case .showNotFound: return "This show budget is no longer available. Reopen the show and retry."
        case .entryNotFound: return "This budget entry is no longer available. Reopen the show and retry."
        case .conflictingEntry: return "This transaction was already recorded with different details. Review the existing entry before adding another."
        case .fileTooLarge: return "The saved show budget is too large to open or update safely. The original file has been kept."
        case .loadFailed: return "The saved show budget could not be opened. Your existing file has been kept. Retry after storage becomes available."
        case .saveFailed: return "The show budget was not saved. Your entries and selections have been kept; retry saving."
        }
    }
}

/// Independent, versioned financial records. Changes are published only after
/// an atomic file write; inventory storage, migration and offers are untouched.
@MainActor @Observable final class ShowBudgetStore {
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void

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

    init(url: URL? = nil, read: Reader? = nil, write: Writer? = nil) {
        self.url = url ?? Self.defaultURL
        self.read = read ?? Self.readFile
        self.write = write ?? Self.writeFile
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
    func create(name: String, startingCents: Int64) throws -> UUID {
        try requireWritable()
        let show = ShowBudgetEvent(name: name.trimmingCharacters(in: .whitespacesAndNewlines), startingCents: startingCents)
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
        guard let index = book.shows.firstIndex(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard book.shows[index].name != trimmed || book.shows[index].startingCents != startingCents else { return }
        var next = book
        next.shows[index].name = trimmed
        next.shows[index].startingCents = startingCents
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
