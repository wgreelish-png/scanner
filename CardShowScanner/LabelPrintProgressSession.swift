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

    deinit { task?.cancel() }

    var total: Int { requestedIDs.count }

    func completed(in entries: [LabelQueueEntry]) -> Int {
        entries.lazy.filter { requestedIDs.contains($0.id) && $0.state == .completed }.count
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
            await queue.start(using: sender)
            guard let self, self.generation == current else { return }
            self.task = nil
            self.isRunning = false
            let completedIDs = Set(queue.entries.lazy.filter { $0.state == .completed }.map(\.id))
            self.didSucceed = !self.didRequestStop && !Task.isCancelled && canFinish()
                && queue.lastRunCompletedSuccessfully && !queue.isPrinting
                && queue.isLoaded && queue.error == nil && ids.isSubset(of: completedIDs)
                && queue.entries.allSatisfy { $0.state == .completed }
            if self.didSucceed {
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
        queue.stop(using: printer)
    }

    func close() {
        guard !isRunning else { return }
        isPresented = false
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
    enum Stage: Equatable { case idle, labels, finishing }
    private(set) var stage = Stage.idle
    private let fails: Bool
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    private init(fails: Bool) { self.fails = fails }

    static func configured() -> LabelPrintProgressFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--show-transactions-ui-fixture"),
              let token = arguments.first(where: { $0.hasPrefix("--show-transactions-fixture-id=") }),
              UUID(uuidString: String(token.dropFirst("--show-transactions-fixture-id=".count))) != nil,
              let mode = arguments.first(where: { $0.hasPrefix("--label-print-progress-fixture=") })
                .map({ String($0.dropFirst("--label-print-progress-fixture=".count)) }),
              ["success", "failure"].contains(mode) else { return nil }
        return LabelPrintProgressFixture(fails: mode == "failure")
    }

    func confirm() {
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: true)
    }

    func cancelPrinting() {
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: false)
    }

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { .notSent(.unsupportedResponse) }

    func printContinuously(_ rasters: [LabelRaster],
                           beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                           afterPages: @escaping @MainActor ([Int]) async throws -> Void) async -> LabelSendOutcome {
        let pages = Array(rasters.indices)
        do {
            try await beforePages(pages)
            stage = .labels
            let confirmed = await withCheckedContinuation { continuation = $0 }
            guard confirmed, !Task.isCancelled else { return .uncertain(.cancelled) }
            guard !fails else { return .uncertain(.writeFailed) }
            try await afterPages(pages)
            stage = .finishing
            let ended = await withCheckedContinuation { continuation = $0 }
            return ended && !Task.isCancelled ? .completed : .uncertain(.cancelled)
        } catch {
            return .notSent((error as? LabelPrinterIssue) ?? .writeFailed)
        }
    }
}
#endif
