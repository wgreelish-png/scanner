import Foundation
import Observation

/// Owns an explicitly started job independently of a presented sheet's lifetime.
/// A full counter is not success until the printer task has also returned.
@MainActor @Observable final class LabelPrintProgressSession {
    private(set) var requestedIDs: Set<UUID> = []
    private(set) var isPresented = false
    private(set) var isRunning = false
    private(set) var didSucceed = false
    private(set) var didRequestStop = false
    private(set) var issue: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var startWhenPresented: (@MainActor () -> Void)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var successfulEntries: [LabelQueueEntry] = []
    @ObservationIgnored private var presentationCompleted = false
    @ObservationIgnored private var queueRunID: UUID?

    deinit { task?.cancel() }

    var total: Int { requestedIDs.count }

    func completed(in entries: [LabelQueueEntry]) -> Int {
        entries.lazy.filter { self.requestedIDs.contains($0.id) && $0.state == .completed }.count
    }

    func status(in entries: [LabelQueueEntry], printerStatus: String) -> String {
        if isRunning {
            if didRequestStop { return "Stopping new labels. The printer may finish labels already received." }
            if total > 0, completed(in: entries) == total { return "Finishing print job…" }
            return printerStatus
        }
        return issue ?? "Review the saved queue before continuing."
    }

    @discardableResult
    func start(queue: LabelPrintQueue, using sender: any LabelPrinterSending,
               deferUntilPresented: Bool = false,
               canFinish: @escaping @MainActor () -> Bool = { true }) -> Bool {
        guard task == nil, !isRunning, queue.canStart else { return false }
        let ids = Set(queue.entries.lazy.filter { $0.state == .pending }.map(\.id))
        guard !ids.isEmpty else { return false }
        let current = UUID()
        generation = current
        requestedIDs = ids
        isPresented = true
        isRunning = true
        didSucceed = false
        didRequestStop = false
        issue = nil
        successfulEntries = []
        presentationCompleted = false
        queueRunID = nil
        if deferUntilPresented {
            startWhenPresented = { [weak self] in
                self?.launch(queue: queue, using: sender, ids: ids, generation: current, canFinish: canFinish)
            }
        } else {
            launch(queue: queue, using: sender, ids: ids, generation: current, canFinish: canFinish)
        }
        return true
    }

    func presentationDidAppear() {
        let start = startWhenPresented
        startWhenPresented = nil
        start?()
    }

    private func launch(queue: LabelPrintQueue, using sender: any LabelPrinterSending, ids: Set<UUID>,
                        generation current: UUID, canFinish: @escaping @MainActor () -> Bool) {
        guard generation == current, !didRequestStop else { return }
        guard queue.canStart, Set(queue.entries.lazy.filter { $0.state == .pending }.map(\.id)) == ids else {
            isRunning = false
            issue = "The saved queue changed. Review it before printing."
            return
        }
        task = Task { [weak self] in
            guard self?.generation == current, self?.didRequestStop == false, !Task.isCancelled else {
                if let self, self.generation == current {
                    self.task = nil; self.isRunning = false
                    self.issue = "Printing paused before any labels were sent."
                }
                return
            }
            await queue.start(using: sender, onStarted: { [weak self] runID in
                guard let self, self.generation == current else { return }
                self.queueRunID = runID
            })
            guard let self, self.generation == current else { return }
            self.task = nil
            self.isRunning = false
            let completedIDs = Set(queue.entries.lazy.filter { $0.state == .completed }.map(\.id))
            self.didSucceed = !self.didRequestStop && !Task.isCancelled && canFinish()
                && queue.lastRunCompletedSuccessfully && !queue.isPrinting
                && queue.isLoaded && queue.error == nil && ids.isSubset(of: completedIDs)
                && queue.entries.allSatisfy { $0.state == .completed }
            if self.didSucceed {
                self.successfulEntries = queue.entries.filter { ids.contains($0.id) }
                self.isPresented = false
            } else {
                self.issue = queue.error ?? (self.didRequestStop
                    ? "Printing paused. Check any labels the printer may already have received."
                    : "Printing stopped. Review the queue before continuing.")
            }
        }
    }

    func stop(queue: LabelPrintQueue, using printer: any LabelPrinterSending) {
        guard isRunning else { return }
        didRequestStop = true
        if startWhenPresented != nil {
            startWhenPresented = nil
            isRunning = false
            issue = "Printing paused before any labels were sent."
            return
        }
        if let queueRunID { queue.stop(using: printer, runID: queueRunID) }
    }

    func close() {
        guard !isRunning else { return }
        isPresented = false
    }

    /// Cleanup follows dismissal, so the final confirmed counter stays visible
    /// until the printer's terminal acknowledgement has closed progress.
    @discardableResult
    func completePresentation(queue: LabelPrintQueue) throws -> Bool {
        guard didSucceed, !isRunning, !isPresented, !presentationCompleted else { return false }
        let custom = successfulEntries.filter { $0.source == .custom }
        do {
            if !custom.isEmpty { try queue.removeConfirmedCustomLabels(custom) }
            presentationCompleted = true
            return true
        } catch {
            issue = error.localizedDescription
            throw error
        }
    }

    func waitUntilFinished() async {
        let pending = task
        await pending?.value
    }
}

#if DEBUG
/// An explicitly enabled, token-isolated UI-test transport. It never creates a
/// Bluetooth connection and advances only when the test confirms each gate.
@MainActor @Observable final class LabelPrintProgressFixture: LabelContinuousPrinterSending {
    enum Stage: Equatable { case idle, uploading, labels, finishing }
    private(set) var stage = Stage.idle
    private(set) var uploadProgress: NiimbotUploadProgress?
    private let fails: Bool
    private let confirmsEachCopy: Bool
    private let showsUpload: Bool
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    private init(fails: Bool, confirmsEachCopy: Bool, showsUpload: Bool) {
        self.fails = fails
        self.confirmsEachCopy = confirmsEachCopy
        self.showsUpload = showsUpload
    }

    static func configured() -> LabelPrintProgressFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--show-transactions-ui-fixture"),
              let token = arguments.first(where: { $0.hasPrefix("--show-transactions-fixture-id=") }),
              UUID(uuidString: String(token.dropFirst("--show-transactions-fixture-id=".count))) != nil,
              let mode = arguments.first(where: { $0.hasPrefix("--label-print-progress-fixture=") })
                .map({ String($0.dropFirst("--label-print-progress-fixture=".count)) }),
              ["success", "failure", "success-per-copy", "success-upload", "failure-upload"].contains(mode) else { return nil }
        return LabelPrintProgressFixture(fails: mode == "failure" || mode == "failure-upload",
            confirmsEachCopy: mode == "success-per-copy" || mode == "success-upload",
            showsUpload: mode == "success-upload" || mode == "failure-upload")
    }

    func confirm() {
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: true)
    }

    func cancelPrinting() {
        uploadProgress = nil
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: false)
    }

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { .notSent(.unsupportedResponse) }

    func printContinuously(_ rasters: [LabelRaster],
                           beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                           afterPages: @escaping @MainActor ([Int]) async throws -> Void) async -> LabelSendOutcome {
        let pages = Array(rasters.indices)
        defer { uploadProgress = nil }
        do {
            try await beforePages(pages)
            if showsUpload {
                stage = .uploading
                for completedRequests in [0, 2, 4] {
                    uploadProgress = NiimbotUploadProgress(pages: 0..<rasters.count,
                        completedRequests: completedRequests, totalRequests: 4)
                    let advanced = await withCheckedContinuation { continuation = $0 }
                    guard advanced, !Task.isCancelled else { return .uncertain(.cancelled) }
                    if fails, completedRequests == 2 { return .uncertain(.writeFailed) }
                }
                uploadProgress = nil
            }
            stage = .labels
            for receipt in confirmsEachCopy ? pages.map({ [$0] }) : [pages] {
                let confirmed = await withCheckedContinuation { continuation = $0 }
                guard confirmed, !Task.isCancelled else { return .uncertain(.cancelled) }
                guard !fails else { return .uncertain(.writeFailed) }
                // Per-copy gates change only the queue receipt, without a new
                // upload, printer status or stage to refresh a stale screen.
                try await afterPages(receipt)
            }
            stage = .finishing
            let ended = await withCheckedContinuation { continuation = $0 }
            return ended && !Task.isCancelled ? .completed : .uncertain(.cancelled)
        } catch {
            return .notSent((error as? LabelPrinterIssue) ?? .writeFailed)
        }
    }
}
#endif
