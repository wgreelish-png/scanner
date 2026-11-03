import Foundation
import Observation

enum LabelQueueState: String, Codable, Equatable, Sendable {
    case pending, sending, completed, failed, uncertain

    var title: String {
        switch self {
        case .pending: return "Queued"
        case .sending: return "Printing"
        case .completed: return "Completed"
        case .failed: return "Not printed"
        case .uncertain: return "Check label"
        }
    }

    var isRetryable: Bool { self == .failed || self == .uncertain }
}

/// An immutable snapshot of one physical label. Queue work cannot change the
/// inventory lot, its asking price, or any financial record.
struct LabelQueueEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let inventoryID: UUID
    let cardName: String
    let priceCents: Int64
    let copyNumber: Int
    let paperSize: InventoryLabelSize
    let style: InventoryLabelStyle
    let raster: LabelRaster
    var state: LabelQueueState
    var lastIssue: LabelPrinterIssue?

    var priceText: String { ShowBudgetMoney.decimal(priceCents).money }

    init(draft: InventoryLabelDraft, raster: LabelRaster, copyNumber: Int) throws {
        try draft.validate()
        try raster.validate()
        guard let cents = draft.priceCents, (1...draft.copies).contains(copyNumber) else {
            throw LabelPrintQueueFailure.invalidEntry
        }
        self.id = UUID()
        self.inventoryID = draft.id
        self.cardName = draft.cardName
        self.priceCents = cents
        self.copyNumber = copyNumber
        self.paperSize = draft.paperSize
        self.style = draft.style
        self.raster = raster
        self.state = .pending
        self.lastIssue = nil
        try validate()
    }

    func validate() throws {
        guard !cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cardName.count <= 500,
              ShowBudgetMoney.isValid(priceCents),
              (1...100).contains(copyNumber),
              raster.width == paperSize.headDots,
              raster.height == paperSize.feedDots else { throw LabelPrintQueueFailure.invalidEntry }
        try raster.validate()
        switch state {
        case .pending, .sending, .completed:
            guard lastIssue == nil else { throw LabelPrintQueueFailure.invalidEntry }
        case .failed, .uncertain:
            guard lastIssue != nil else { throw LabelPrintQueueFailure.invalidEntry }
        }
    }
}

enum LabelPrintQueueFailure: LocalizedError, Equatable, Sendable {
    case printing, notLoaded, unfinishedQueue, tooManyLabels, invalidEntry, duplicateIdentity
    case invalidVersion, fileTooLarge, loadFailed, saveFailed, invalidSelection, acknowledgeUncertain

    var errorDescription: String? {
        switch self {
        case .printing: return "Stop the current print job before changing the queue."
        case .notLoaded: return "The saved label queue is unavailable. Reload it or explicitly discard it before printing. Your saved queue has been kept."
        case .unfinishedQueue: return "Finish or clear the current label queue before adding a new batch."
        case .tooManyLabels: return "A label queue can contain at most 250 labels. Reduce the number of cards or copies."
        case .invalidEntry: return "A queued label has invalid card details, price, copy number, or image. Review the labels and try again."
        case .duplicateIdentity: return "The label queue contains a duplicate identifier. Your saved queue has been kept."
        case .invalidVersion: return "This saved label queue uses an unsupported format. Your saved queue has been kept."
        case .fileTooLarge: return "The saved label queue is too large to open or update safely. Your saved queue has been kept."
        case .loadFailed: return "The saved label queue could not be opened. Retry loading it or explicitly discard it. Your saved queue has been kept."
        case .saveFailed: return "The label queue could not be saved, so printing stopped. Reload the queue before continuing and check any label marked Check label before retrying."
        case .invalidSelection: return "Select only labels marked Not printed or Check label. Completed labels cannot be retried."
        case .acknowledgeUncertain: return "Check the printer and the physical labels first. Confirm that each selected Check label item needs another copy before retrying."
        }
    }
}

private struct LabelQueueFile: Codable {
    var version = 1
    var entries: [LabelQueueEntry] = []
}

/// The durable queue never starts by itself. Each copy is saved as `sending`
/// before transport can emit bytes; an interrupted copy therefore requires a
/// physical-label check and an explicit retry after restart.
@MainActor @Observable final class LabelPrintQueue {
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void

    static let shared = LabelPrintQueue()
    static let maximumLabels = 250
    static let maximumBytes = 8 * 1_024 * 1_024

    private(set) var entries: [LabelQueueEntry] = []
    private(set) var isPrinting = false
    private(set) var isLoaded = false
    private(set) var error: String?

    var canStart: Bool { isLoaded && !isPrinting && pendingCount > 0 }
    var pendingCount: Int { entries.filter { $0.state == .pending }.count }
    var completedCount: Int { entries.filter { $0.state == .completed }.count }
    var failedCount: Int { entries.filter { $0.state == .failed }.count }
    var uncertainCount: Int { entries.filter { $0.state == .uncertain }.count }

    private let url: URL
    private let read: Reader
    private let write: Writer
    private var stopRequested = false
    private var activeSessionID: UUID?
    @ObservationIgnored private weak var activePrinter: (any LabelPrinterSending)?

    init(url: URL? = nil, read: Reader? = nil, write: Writer? = nil) {
        self.url = url ?? Self.defaultURL
        self.read = read ?? Self.readFile
        self.write = write ?? Self.writeFile
        reload()
    }

    /// A failed read never overwrites the original bytes. Recovery of an
    /// interrupted send is itself saved before Start can become available.
    func reload() {
        guard !isPrinting else { return }
        do {
            var next: [LabelQueueEntry] = []
            if let data = try read(url) {
                guard data.count <= Self.maximumBytes else { throw LabelPrintQueueFailure.fileTooLarge }
                let saved = try JSONDecoder().decode(LabelQueueFile.self, from: data)
                guard saved.version == 1 else { throw LabelPrintQueueFailure.invalidVersion }
                next = saved.entries
                try Self.validate(next)
            }
            let interrupted = next.indices.filter { next[$0].state == .sending }
            for index in interrupted {
                next[index].state = .uncertain
                next[index].lastIssue = .connectionLost
            }
            if !interrupted.isEmpty {
                do { try save(next) }
                catch {
                    // The recovered status can be shown while storage is
                    // unavailable, but it cannot enable any new send.
                    entries = next
                    throw LabelPrintQueueFailure.saveFailed
                }
            }
            entries = next
            isLoaded = true
            error = nil
        } catch {
            isLoaded = false
            self.error = (error as? LabelPrintQueueFailure)?.errorDescription
                ?? LabelPrintQueueFailure.loadFailed.errorDescription
        }
    }

    func replace(with next: [LabelQueueEntry]) throws {
        try requireWritable()
        guard entries.allSatisfy({ $0.state == .completed }) else { throw LabelPrintQueueFailure.unfinishedQueue }
        guard next.allSatisfy({ $0.state == .pending && $0.lastIssue == nil }) else {
            throw LabelPrintQueueFailure.invalidEntry
        }
        try commit(next)
    }

    /// Only an explicit user action calls this method. Failure pauses the whole
    /// batch; neither reconnecting nor retrying selected entries starts it.
    func start(using printer: any LabelPrinterSending) async {
        guard canStart, !Task.isCancelled else { return }
        isPrinting = true
        stopRequested = false
        let sessionID = UUID()
        activeSessionID = sessionID
        activePrinter = printer
        error = nil
        defer {
            activePrinter = nil
            activeSessionID = nil
            isPrinting = false
            stopRequested = false
        }

        while !stopRequested && !Task.isCancelled,
              let index = entries.firstIndex(where: { $0.state == .pending }) {
            var sending = entries
            sending[index].state = .sending
            sending[index].lastIssue = nil
            do {
                try commit(sending)
            } catch { return } // No bytes may be sent without this durable marker.

            let outcome: LabelSendOutcome
            if Task.isCancelled {
                outcome = .notSent(.cancelled)
            } else {
                outcome = await withTaskCancellationHandler {
                    await printer.printLabel(sending[index].raster)
                } onCancel: {
                    Task { @MainActor [weak self] in self?.requestStop(sessionID: sessionID) }
                }
            }

            // Even after Stop, keep the transport's result for the active copy.
            // A confirmed completion must never become a pending automatic retry.
            var finished = entries
            switch outcome {
            case .completed:
                finished[index].state = .completed
                finished[index].lastIssue = nil
            case .notSent(let issue):
                finished[index].state = .failed
                finished[index].lastIssue = issue
            case .uncertain(let issue):
                finished[index].state = .uncertain
                finished[index].lastIssue = issue
            }
            do {
                try commit(finished)
            } catch {
                // Keep the observed result visible, but block all work. The
                // saved sending marker will require a check on the next reload.
                entries = finished
                return
            }
            switch outcome {
            case .completed: break
            case .notSent(let issue), .uncertain(let issue):
                error = issue.localizedDescription
                return
            }
        }
    }

    func stop(using printer: any LabelPrinterSending) {
        guard isPrinting, !stopRequested else { return }
        stopRequested = true
        // The active transport owns the in-flight result; a passed-in stale
        // connection must not cancel a different printer's work.
        if let activePrinter { activePrinter.cancelPrinting() }
        else { printer.cancelPrinting() }
    }

    /// Converts only selected unsuccessful copies back to pending. A separate
    /// Start action is required, and completed copies are never eligible.
    func retry(ids: Set<UUID>, acknowledgeUncertain: Bool = false) throws {
        try requireWritable()
        guard !ids.isEmpty else { throw LabelPrintQueueFailure.invalidSelection }
        let indices = entries.indices.filter { ids.contains(entries[$0].id) }
        guard indices.count == ids.count,
              indices.allSatisfy({ entries[$0].state == .failed || entries[$0].state == .uncertain }) else {
            throw LabelPrintQueueFailure.invalidSelection
        }
        guard acknowledgeUncertain || !indices.contains(where: { entries[$0].state == .uncertain }) else {
            throw LabelPrintQueueFailure.acknowledgeUncertain
        }
        var next = entries
        for index in indices { next[index].state = .pending; next[index].lastIssue = nil }
        try commit(next)
    }

    func clearCompleted() throws {
        try requireWritable()
        try commit(entries.filter { $0.state != .completed })
    }

    func clear() throws {
        try requireWritable()
        try commit([])
    }

    /// Explicit destructive recovery, including an unreadable queue. Ordinary
    /// edits are deliberately unable to replace corrupt or unrecognized data.
    func discardSavedQueue() throws {
        guard !isPrinting else { throw LabelPrintQueueFailure.printing }
        try commit([])
    }

    private func requestStop(sessionID: UUID) {
        guard isPrinting, activeSessionID == sessionID, !stopRequested else { return }
        stopRequested = true
        activePrinter?.cancelPrinting()
    }

    private func requireWritable() throws {
        guard !isPrinting else { throw LabelPrintQueueFailure.printing }
        guard isLoaded else { throw LabelPrintQueueFailure.notLoaded }
    }

    private func commit(_ next: [LabelQueueEntry]) throws {
        try Self.validate(next)
        do {
            try save(next)
            entries = next
            isLoaded = true
            error = nil
        } catch {
            isLoaded = false
            self.error = LabelPrintQueueFailure.saveFailed.errorDescription
            throw LabelPrintQueueFailure.saveFailed
        }
    }

    private func save(_ next: [LabelQueueEntry]) throws {
        let data = try JSONEncoder().encode(LabelQueueFile(entries: next))
        guard data.count <= Self.maximumBytes else { throw LabelPrintQueueFailure.fileTooLarge }
        try write(data, url)
    }

    private static func validate(_ entries: [LabelQueueEntry]) throws {
        guard entries.count <= maximumLabels else { throw LabelPrintQueueFailure.tooManyLabels }
        guard Set(entries.map(\.id)).count == entries.count else { throw LabelPrintQueueFailure.duplicateIdentity }
        guard entries.filter({ $0.state == .sending }).count <= 1 else { throw LabelPrintQueueFailure.invalidEntry }
        for entry in entries { try entry.validate() }
    }

    private static var defaultURL: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-transactions-ui-fixture") {
            let prefix = "--show-transactions-fixture-id="
            let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            let token = argument.flatMap { UUID(uuidString: String($0.dropFirst(prefix.count))) } ?? UUID()
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ShowTransactionsFixture-" + token.uuidString, isDirectory: true)
                .appendingPathComponent("label-print-queue.json")
        }
        #endif
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("CardShowScanner", isDirectory: true)
            .appendingPathComponent("label-print-queue.json")
    }

    private static func readFile(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw LabelPrintQueueFailure.loadFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LabelPrintQueueFailure.loadFailed
        }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes) else {
            throw LabelPrintQueueFailure.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw LabelPrintQueueFailure.fileTooLarge }
        return data
    }

    private static func writeFile(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
