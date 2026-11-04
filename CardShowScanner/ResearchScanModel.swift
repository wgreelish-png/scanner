import Foundation
import Observation

/// Recognition for a research lookup only. Choosing a match never adds a card
/// to inventory, creates a scan session, or changes a show budget.
@MainActor @Observable final class ResearchScanModel {
    private(set) var result: ScanResult?
    private(set) var error: String?
    private(set) var isScanning = false
    var candidates: [CardCandidate] { result?.candidates ?? [] }
    var liveProvider: TCGTrackingScannerProvider? { provider as? TCGTrackingScannerProvider }

    private let provider: any ScannerProvider
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var game: String?
    @ObservationIgnored private var chosen = false

    init(provider: (any ScannerProvider)? = nil) {
        self.provider = provider ?? TCGTrackingScannerProvider()
    }

    func start(game: String) {
        guard TCGTrackingScannerProvider.gameKeys[game] != nil else {
            stop()
            error = "Choose a supported game before scanning."
            DiagnosticLog.shared.record("research.scan_blocked", ["reason": "unsupported_game"])
            return
        }
        let changedGame = self.game != game
        active = true
        self.game = game
        // A held match survives navigation/backgrounding. Opening the screen
        // again must not start a camera underneath its frozen candidates.
        guard result == nil else { return }
        if changedGame { stopCapture() }
        guard !isScanning else { return }
        beginCapture()
    }

    func stop() {
        active = false
        stopCapture()
    }

    func scanAgain() {
        stopCapture()
        result = nil
        chosen = false
        error = nil
        DiagnosticLog.shared.record("research.scan_retried")
        if active { beginCapture() }
    }

    /// Returns the exact frozen match once. Research owns subsequent printing,
    /// condition and market lookups; this model does not guess those values.
    func choose(_ candidate: CardCandidate) -> CardCandidate? {
        guard !chosen, candidates.contains(candidate) else { return nil }
        chosen = true
        stop()
        var card = candidate
        if card.identity.condition != "Near Mint" {
            card.identity.skuID = nil
            card.marketPrice = nil
            card.printingQuotes = nil
            card.marketPriceMetadata = nil
        }
        card.identity.condition = "Near Mint"
        DiagnosticLog.shared.record("research.scan_selected", ["candidates": String(candidates.count)])
        return card
    }

    private func beginCapture() {
        guard active, result == nil, !isScanning, let game else { return }
        error = nil
        runID = UUID()
        let request = runID
        // Providers replace their AsyncStream on start. Subscribe only after
        // starting so resuming never listens to a finished earlier stream.
        provider.start(game: game)
        let stream = provider.results
        isScanning = true
        DiagnosticLog.shared.record("research.scan_started", ["provider": liveProvider == nil ? "injected" : "live"])
        consumer = Task { [weak self] in
            for await scan in stream {
                guard let self, !Task.isCancelled, self.runID == request else { return }
                self.receive(scan)
            }
            guard let self, !Task.isCancelled, self.runID == request else { return }
            self.stopCapture()
            if self.result == nil {
                self.error = "The scanner stopped. Tap Retry to try again."
                DiagnosticLog.shared.record("research.scan_stopped", ["reason": "stream_finished"])
            }
        }
    }

    private func receive(_ scan: ScanResult) {
        guard active, isScanning, result == nil, scan.visible, !scan.same,
              !scan.candidates.isEmpty else { return }
        var frozen = scan
        frozen.candidates = Array(scan.candidates.prefix(5))
        result = frozen
        DiagnosticLog.shared.record("research.scan_frozen", ["candidates": String(frozen.candidates.count)])
        // The bundled bridge already settles and holds recognition. Releasing
        // the camera here also protects this read-only picker from later frames
        // and avoids capturing while the user compares matches.
        stopCapture()
    }

    private func stopCapture() {
        runID = UUID()
        consumer?.cancel()
        consumer = nil
        if isScanning { provider.stop() }
        isScanning = false
    }
}
