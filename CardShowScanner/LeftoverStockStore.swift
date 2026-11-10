import Foundation
import Observation

struct LeftoverStockSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let baseline: LeftoverStockBaseline
    var countListIDs: [UUID] = []
    private(set) var countComplete = false
    private(set) var completedCountFingerprint: String? = nil

    func isCountComplete(for counts: [LeftoverStockCountRow]) -> Bool {
        countComplete && completedCountFingerprint == LeftoverStockReconciliation.countFingerprint(counts)
    }

    fileprivate mutating func setCountComplete(_ complete: Bool, counts: [LeftoverStockCountRow]) {
        countComplete = complete
        completedCountFingerprint = complete ? LeftoverStockReconciliation.countFingerprint(counts) : nil
    }

    fileprivate mutating func invalidateCompletion() {
        countComplete = false; completedCountFingerprint = nil
    }

    fileprivate func validate() throws {
        guard createdAt.timeIntervalSince1970.isFinite,
              countListIDs.count <= LeftoverStockStore.maximumCountLists,
              Set(countListIDs).count == countListIDs.count else { throw LeftoverStockFailure.loadFailed }
        if countComplete {
            guard let fingerprint = completedCountFingerprint, fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw LeftoverStockFailure.loadFailed
            }
        } else if completedCountFingerprint != nil { throw LeftoverStockFailure.loadFailed }
        try LeftoverStockReconciliation.validate(baseline: baseline)
    }
}

private struct LeftoverStockFile: Codable {
    var version = 1
    var active: LeftoverStockSession?
}

/// Only this independent file is changed. List UUID references may precede a
/// scan draft's first commit; loading never creates or deletes a SwiftData list.
@MainActor @Observable final class LeftoverStockStore {
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void
    typealias Clock = @MainActor () -> Date

    static let shared = LeftoverStockStore()
    nonisolated static let maximumBytes = 16 * 1_024 * 1_024
    nonisolated static let maximumCountLists = 100

    private(set) var active: LeftoverStockSession?
    private(set) var isLoaded = false
    private(set) var error: String?

    private let url: URL
    private let read: Reader
    private let write: Writer
    private let now: Clock

    init(directory: URL? = nil, read: Reader? = nil, write: Writer? = nil, now: @escaping Clock = Date.init) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LeftoverStock", isDirectory: true)
        url = directory.appendingPathComponent("leftover-stock.json")
        self.read = read ?? Self.readFile
        self.write = write ?? Self.writeFile
        self.now = now
        reload()
    }

    func reload() {
        do {
            let next: LeftoverStockFile
            if let data = try read(url) {
                guard data.count <= Self.maximumBytes else { throw LeftoverStockFailure.fileTooLarge }
                next = try JSONDecoder().decode(LeftoverStockFile.self, from: data)
                guard next.version == 1 else { throw LeftoverStockFailure.invalidVersion }
                try next.active?.validate()
            } else { next = LeftoverStockFile() }
            active = next.active; isLoaded = true; error = nil
        } catch {
            // Retain the last in-memory state and the original file. An unreadable
            // file must never turn into a writable empty reconciliation store.
            isLoaded = false
            self.error = (error as? LeftoverStockFailure)?.errorDescription ?? LeftoverStockFailure.loadFailed.errorDescription
        }
    }

    @discardableResult
    func start(baseline: LeftoverStockBaseline) throws -> LeftoverStockSession {
        try requireLoaded()
        guard active == nil else { throw LeftoverStockFailure.activeSessionExists }
        try LeftoverStockReconciliation.validate(baseline: baseline)
        let session = LeftoverStockSession(id: UUID(), createdAt: now(), baseline: baseline)
        try commit(session)
        return session
    }

    /// The user has explicitly started a new count after a complete new fetch.
    /// Replace only this sidecar in one atomic write; keep all ordinary lists.
    @discardableResult
    func restart(baseline: LeftoverStockBaseline, sessionID: UUID) throws -> LeftoverStockSession {
        _ = try matching(sessionID)
        try LeftoverStockReconciliation.validate(baseline: baseline)
        let session = LeftoverStockSession(id: UUID(), createdAt: now(), baseline: baseline)
        try commit(session)
        return session
    }

    func addCountList(id: UUID, sessionID: UUID) throws {
        var session = try matching(sessionID)
        guard !session.countListIDs.contains(id) else { return }
        guard session.countListIDs.count < Self.maximumCountLists else { throw LeftoverStockFailure.capacityExceeded }
        session.countListIDs.append(id); session.invalidateCompletion()
        try commit(session)
    }

    func removeCountList(id: UUID, sessionID: UUID) throws {
        var session = try matching(sessionID)
        guard session.countListIDs.contains(id) else { return }
        session.countListIDs.removeAll { $0 == id }; session.invalidateCompletion()
        try commit(session)
    }

    /// Callers must also require every referenced count list to be available.
    /// A missing list might be an interrupted draft or an intentional deletion;
    /// this store does not infer that its previous physical count was zero.
    func setCountComplete(_ complete: Bool, sessionID: UUID, counts: [LeftoverStockCountRow]) throws {
        var session = try matching(sessionID)
        if complete {
            guard counts.count <= LeftoverStockReconciliation.maximumCountRows else { throw LeftoverStockFailure.capacityExceeded }
            guard LeftoverStockReconciliation.compare(baseline: session.baseline, counts: counts).canExport else {
                throw LeftoverStockFailure.unresolvedCards
            }
        }
        session.setCountComplete(complete, counts: counts)
        try commit(session)
    }

    func clear(sessionID: UUID) throws {
        _ = try matching(sessionID)
        try commit(nil)
    }

    private func matching(_ id: UUID) throws -> LeftoverStockSession {
        try requireLoaded()
        guard let active, active.id == id else { throw LeftoverStockFailure.sessionUnavailable }
        return active
    }

    private func requireLoaded() throws {
        guard isLoaded else { throw LeftoverStockFailure.notLoaded }
    }

    private func commit(_ next: LeftoverStockSession?) throws {
        try requireLoaded()
        try next?.validate()
        do {
            let data = try JSONEncoder().encode(LeftoverStockFile(active: next))
            guard data.count <= Self.maximumBytes else { throw LeftoverStockFailure.fileTooLarge }
            try write(data, url)
            active = next; error = nil
        } catch {
            let failure = error as? LeftoverStockFailure ?? .saveFailed
            self.error = failure.errorDescription
            throw failure
        }
    }

    private static func readFile(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw LeftoverStockFailure.loadFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LeftoverStockFailure.loadFailed }
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= Int64(maximumBytes) else { throw LeftoverStockFailure.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw LeftoverStockFailure.fileTooLarge }
        return data
    }

    private static func writeFile(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
