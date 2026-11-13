import Foundation

/// An explicit refresh always shows its plan. A complete saved pack can open
/// immediately when starting capture, without another download prompt.
enum ScannerDownloadGateAction: Equatable, Sendable {
    case initialLoad, refresh
}

enum ScannerDownloadGateState {
    case idle
    case checking(ScannerDownloadGateAction)
    case ready(ScannerDownloadPreview, ScannerDownloadGateAction)
    case unavailable(ScannerDownloadGateAction)

    var action: ScannerDownloadGateAction? {
        switch self {
        case .idle: nil
        case .checking(let action), .ready(_, let action), .unavailable(let action): action
        }
    }
}

/// Keeps metadata checks separate from payload downloads. Cancellation retires
/// both the async request and its continuation, even if a loader finishes late.
@MainActor final class ScannerDownloadGate {
    typealias Loader = @MainActor (String, Bool) async throws -> ScannerDownloadPreview
    private struct Pending {
        let game: String
        let action: ScannerDownloadGateAction
        let proceed: @MainActor () -> Void
    }

    private let loader: Loader
    private let stateChanged: @MainActor (ScannerDownloadGateState) -> Void
    private var pending: Pending?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private(set) var state: ScannerDownloadGateState = .idle

    init(loader: @escaping Loader = { game, preferSaved in
        try await ScannerDownloadPreviewService.shared.preview(game: game, preferSaved: preferSaved)
    }, stateChanged: @escaping @MainActor (ScannerDownloadGateState) -> Void = { _ in }) {
        self.loader = loader
        self.stateChanged = stateChanged
    }

    deinit { work?.cancel() }

    func begin(game: String, action: ScannerDownloadGateAction, proceed: @escaping @MainActor () -> Void) {
        cancel()
        let request = UUID()
        generation = request
        pending = Pending(game: game, action: action, proceed: proceed)
        publish(.checking(action))
        let loader = loader
        work = Task { [weak self] in
            do {
                let preview = try await loader(game, action == .initialLoad)
                try Task.checkCancellation()
                guard let self, self.generation == request, self.pending != nil else { return }
                self.work = nil
                guard preview.gameKey == TCGGameRegistry.scannerKey(for: game) else {
                    self.publish(.unavailable(action)); return
                }
                if action == .initialLoad, preview.missingFiles == 0 {
                    self.finish()
                } else {
                    self.publish(.ready(preview, action))
                }
            } catch {
                guard let self, self.generation == request, self.pending != nil else { return }
                self.work = nil
                if error is CancellationError || Task.isCancelled {
                    self.cancel()
                } else {
                    self.publish(.unavailable(action))
                }
            }
        }
    }

    func approve() {
        guard case .ready = state else { return }
        finish()
    }

    func continueWithoutEstimate() {
        guard case .unavailable = state else { return }
        finish()
    }

    func retry() {
        guard case .unavailable = state, let pending else { return }
        begin(game: pending.game, action: pending.action, proceed: pending.proceed)
    }

    func cancel() {
        generation = UUID()
        work?.cancel(); work = nil
        pending = nil
        publish(.idle)
    }

    private func finish() {
        guard let pending else { return }
        cancel()
        pending.proceed()
    }

    private func publish(_ value: ScannerDownloadGateState) {
        state = value
        stateChanged(value)
    }
}
