import Foundation
import Observation
@preconcurrency import CoreBluetooth
import UIKit

struct NiimbotDiscoveredPrinter: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// A foreground-only, single-flight connection. Constructing this object never
/// creates CBCentralManager. Opening Price Tags or tapping Search requests access.
@MainActor @Observable final class NiimbotPrinter: NSObject, LabelPrinterSending {
    static let shared = NiimbotPrinter()

    private(set) var devices: [NiimbotDiscoveredPrinter] = []
    private(set) var isConnected = false
    private(set) var isScanning = false
    private(set) var isPrinting = false
    private(set) var isConfiguringPaper = false
    private var manualPaperMode: NiimbotPaperMode
    var paperMode: NiimbotPaperMode {
        if let type = LabelPaperPreferences.shared.detectedProduct?.paperType {
            return type == NiimbotPaperMode.transparent.commandValue ? .transparent : .gap
        }
        return manualPaperMode
    }
    private(set) var paperModeStatus: String?
    private(set) var rollProductStatus: String?
    var rollEstimate: NiimbotRollEstimate? { rollReader.estimate }
    var rollEstimateIsFresh: Bool { rollReader.freshness == .fresh }
    var rollEstimateFreshness: NiimbotRollEstimateFreshness { rollReader.freshness }
    var isReadingRoll: Bool { rollReader.isReading }
    var canRefreshRollEstimate: Bool {
        isConnected && UIApplication.shared.applicationState == .active && !isPrinting && !isConfiguringPaper
            && !isReadingRoll && !rollReplyGuard.isQuarantined && pending == nil
    }
    var rollEstimateStatus: String? {
        if rollReplyGuard.isQuarantined { return "Reconnect to refresh the roll estimate." }
        switch rollReader.freshness {
        case .unknown, .fresh: return nil
        case .stale: return "Refresh to update the estimate."
        case .unavailable: return "Roll estimate unavailable."
        }
    }
    private(set) var status = "Search for a NIIMBOT D110 or D110-M to connect."
    var modelName: String { identity?.modelName ?? "D110 / D110-M" }
    var supportsContinuousPrinting: Bool { isConnected && identity?.modelID == 2320 }
    var error: String?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var discovered: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var notifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var writeType: CBCharacteristicWriteType = .withResponse
    @ObservationIgnored private var parser = NiimbotStreamParser()
    @ObservationIgnored private var pending: Transfer?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var autoReconnectID: UUID?
    @ObservationIgnored private var permissionSearchIntent = NiimbotPermissionSearchIntent()
    @ObservationIgnored private var scanTimeout: Task<Void, Never>?
    @ObservationIgnored private var connectionTimeout: Task<Void, Never>?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?
    @ObservationIgnored private var printOperation: UUID?
    @ObservationIgnored private var printEndAcknowledged = false
    @ObservationIgnored private var activePrintMetrics: NiimbotPrintTransferMetrics?
    @ObservationIgnored private var lastPrintAttemptEnded: ContinuousClock.Instant?
    @ObservationIgnored private var activePrintStock: PreparedStockValidation?
    @ObservationIgnored private var printWasDispatched = false
    @ObservationIgnored private var sendingPages: [Int] = []
    @ObservationIgnored private var dispatchedPages: Set<Int> = []
    @ObservationIgnored private var printCancellation: LabelPrinterIssue?
    @ObservationIgnored private var identity: NiimbotD110Identity?
    @ObservationIgnored private var paperTask: Task<Void, Never>?
    @ObservationIgnored private var connectionStage: ConnectionStage?
    @ObservationIgnored private var identificationStep: NiimbotIdentificationStep?
    @ObservationIgnored private let rollReader = NiimbotRollReadCoordinator()
    @ObservationIgnored private var rollReplyGuard = NiimbotOptionalRollReplyGuard()
    private static let paperModeDefaultsKey = "niimbotPaperMode"
    private static let lastPrinterDefaultsKey = "niimbotLastVerifiedPrinter"

    private enum ConnectionStage: String { case connecting, services, characteristics, notifications, identification }
    private enum ConnectionEndSource: String {
        case replaceConnection = "replace_connection", manualDisconnect = "manual_disconnect", stopRequested = "stop_requested"
        case printCancelled = "print_cancelled", requiredFailure = "required_failure", requestCancelled = "request_cancelled"
    }
    private enum PrintPhase: String { case batchStarted = "batch_started", pageStarted = "page_started", pageCompleted = "page_completed" }
    private enum DiagnosticPhase: String {
        case search, connect, identified, cancel, complete, uncertain
        case connectFailed = "connect_failed"
        case printFailed = "print_failed"
        case notSent = "not_sent"
        case paperRead = "paper_read"
        case paperApplied = "paper_applied"
        case paperFailed = "paper_failed"
        case linkReady = "link_ready"
        case servicesReady = "services_ready"
        case channelReady = "channel_ready"
        case notificationsReady = "notifications_ready"
        case requestStarted = "request_started"
        case requestSent = "request_sent"
        case writeBlocked = "write_blocked"
        case replyReceived = "reply_received"
        case printerWarning = "printer_warning"
    }

    private final class Transfer {
        let id: UUID
        let command: UInt8
        let bytes: Data
        let expectedResponse: UInt8?
        let responseAlternatives: Set<UInt8>
        let beginsPrint: Bool
        let optionalRollRead: Bool
        let pageCopies: Int
        let cleanupHeartbeat: Bool
        let writeType: CBCharacteristicWriteType
        let continuation: CheckedContinuation<NiimbotPacket?, Error>
        var offset = 0
        var awaitingWriteResponse = false
        var response: NiimbotPacket?
        var timeout: Task<Void, Never>?
        var reportedSent = false
        var reportedWriteBlocked = false
        var notificationCount = 0
        var notificationBytes = 0
        var packetCount = 0
        var lastResponseCode: UInt8?
        var waitTiming = NiimbotTransferWaitTiming()

        init(id: UUID, command: UInt8, bytes: Data, expectedResponse: UInt8?, responseAlternatives: Set<UInt8>, beginsPrint: Bool,
             optionalRollRead: Bool, pageCopies: Int, cleanupHeartbeat: Bool, writeType: CBCharacteristicWriteType,
             continuation: CheckedContinuation<NiimbotPacket?, Error>) {
            self.id = id
            self.command = command
            self.bytes = bytes
            self.expectedResponse = expectedResponse
            self.responseAlternatives = responseAlternatives
            self.beginsPrint = beginsPrint
            self.pageCopies = pageCopies
            self.cleanupHeartbeat = cleanupHeartbeat
            self.optionalRollRead = optionalRollRead; self.writeType = writeType
            self.continuation = continuation
        }
    }

    private override init() {
        manualPaperMode = UserDefaults.standard.string(forKey: NiimbotPrinter.paperModeDefaultsKey)
            .flatMap(NiimbotPaperMode.init(rawValue:)) ?? .gap
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func applicationWillResignActive() {
        let permissionIntent = permissionSearchIntent
        let reconnectID = autoReconnectID
        let preserveSearch = scanRequested && peripheral == nil && !isPrinting
            && permissionIntent.preserveOnInactive(permissionUndetermined: CBManager.authorization == .notDetermined)
        stop()
        if preserveSearch {
            // CBCentralManager's first permission prompt makes the app inactive.
            // Retain only that user-requested Search; no connection or job can
            // survive this foreground boundary.
            permissionSearchIntent = permissionIntent
            scanRequested = true
            autoReconnectID = reconnectID
            status = "Waiting for Bluetooth permission…"
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard UIApplication.shared.applicationState == .active, permissionSearchIntent.awaitingDecision else { return }
        let authorization = CBManager.authorization
        guard permissionSearchIntent.resumeWhenActive(permissionGranted: authorization == .allowedAlways,
                                                       permissionUndetermined: authorization == .notDetermined) else {
            if authorization == .denied || authorization == .restricted {
                stopScanning()
                present(.permissionDenied)
            }
            return
        }
        guard scanRequested, let central else { return }
        // If the central is still unknown, its subsequent state callback starts
        // this same Search. If authorization arrived while inactive, start now.
        updateBluetoothState(central)
    }

    /// Price Tags is the user's foreground entry point for printer discovery.
    /// Only a previously verified peripheral may be connected automatically.
    func startPriceTagsConnection() {
        guard !ProcessInfo.processInfo.arguments.contains("--uitest-disable-printer-auto-connect"),
              UIApplication.shared.applicationState == .active,
              !isPrinting, !isConfiguringPaper,
              peripheral == nil, !scanRequested else { return }
        autoReconnectID = UserDefaults.standard.string(forKey: Self.lastPrinterDefaultsKey).flatMap(UUID.init(uuidString:))
        requestSearch()
    }

    func startSearch() {
        autoReconnectID = nil
        requestSearch()
    }

    private func requestSearch() {
        guard UIApplication.shared.applicationState == .active else {
            present(.notActive)
            return
        }
        guard !isPrinting, !isConfiguringPaper else { present(.printerBusy); return }
        guard peripheral == nil else {
            status = isConnected ? "\(modelName) connected." : "Connecting to printer…"
            return
        }
        error = nil
        scanRequested = true
        permissionSearchIntent.request(permissionUndetermined: CBManager.authorization == .notDetermined)
        if let central {
            updateBluetoothState(central)
        } else {
            status = "Waiting for Bluetooth permission…"
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func connect(_ id: UUID) {
        guard UIApplication.shared.applicationState == .active else { present(.notActive); return }
        guard !isPrinting, !isConfiguringPaper else { present(.printerBusy); return }
        guard let central, central.state == .poweredOn else { present(.bluetoothUnavailable); return }
        guard let selected = discovered[id] else { present(.notConnected); return }
        if selected === peripheral {
            if isConnected { status = "\(modelName) connected." }
            return
        }
        guard selected.state == .disconnected else { present(.printerNotReady); return }
        endConnection(issue: .cancelled, source: .replaceConnection)
        stopScanning()
        error = nil
        connectionStage = .connecting
        identificationStep = nil
        status = "Connecting to printer…"
        peripheral = selected
        selected.delegate = self
        let generation = connectionGeneration
        central.connect(selected, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: false])
        connectionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.connectionGeneration == generation, !self.isConnected else { return }
            self.connectionFailed(.responseTimeout)
        }
        diagnostic(.connect)
    }

    func disconnect() {
        if isPrinting { printCancellation = .cancelled }
        stopScanning()
        endConnection(issue: .cancelled, source: .manualDisconnect)
        status = "Disconnected."
    }

    /// Called when the app leaves the foreground. There is no restoration,
    /// background reconnect or automatic print replay on returning.
    func stop() {
        if isPrinting { printCancellation = .notActive }
        stopScanning()
        endConnection(issue: .notActive, source: .stopRequested)
        devices = []
        discovered = [:]
        status = "Disconnected. Search again when ready."
    }

    func cancelPrinting() {
        guard isPrinting else { return }
        printCancellation = .cancelled
        endConnection(issue: .cancelled, source: .printCancelled)
        status = "Printing stopped. Check the printer before trying again."
        diagnostic(.cancel)
    }

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
        await printLabel(raster, paperMode: paperMode)
    }

    /// A queue captures the physical roll setting once, before its first copy.
    /// Saved artwork and completion receipts do not need to be rewritten.
    func senderForCurrentPaperMode(expectedPaper: InventoryLabelSize? = nil) -> any LabelPrinterSending {
        PaperModeSender(printer: self, paperMode: paperMode, expectedPapers: expectedPaper.map { [$0] } ?? [])
    }

    private typealias PreparedStockValidation = NiimbotPrintStockSnapshot

    @MainActor private final class PaperModeSender: LabelContinuousPrinterSending, LabelBatchPrinterSending, LabelStockValidating {
        let printer: NiimbotPrinter
        var paperMode: NiimbotPaperMode
        var expectedPapers: [InventoryLabelSize]
        private var stockValidation: PreparedStockValidation?

        init(printer: NiimbotPrinter, paperMode: NiimbotPaperMode, expectedPapers: [InventoryLabelSize]) {
            self.printer = printer; self.paperMode = paperMode; self.expectedPapers = expectedPapers
        }
        func queuedPaperIssue(_ papers: [InventoryLabelSize]) async -> String? {
            let connection = printer.connectionGeneration
            await printer.rollReader.waitUntilIdle()
            guard !Task.isCancelled, printer.isConnected, printer.connectionGeneration == connection else {
                return "Reconnect the printer before printing these labels."
            }
            let product = LabelPaperPreferences.shared.detectedProduct
            if let issue = LabelStockCompatibility.issue(for: papers, detected: product) { return issue }
            expectedPapers = papers
            paperMode = printer.paperMode
            stockValidation = PreparedStockValidation(connection: connection, product: product, paperMode: paperMode)
            return nil
        }
        func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
            await printer.performPrintJob([raster], paperMode: paperMode, continuous: false,
                beforePages: { _ in }, afterPages: { _ in }, expectedPapers: expectedPapers, stockValidation: stockValidation)
        }
        func printBatch(_ rasters: [LabelRaster],
                        beforePage: @escaping @MainActor (Int) async throws -> Void,
                        afterPage: @escaping @MainActor (Int) async throws -> Void) async -> LabelSendOutcome {
            await printer.performPrintJob(rasters, paperMode: paperMode, continuous: false,
                beforePages: { pages in for page in pages { try await beforePage(page) } },
                afterPages: { pages in for page in pages { try await afterPage(page) } },
                expectedPapers: expectedPapers, stockValidation: stockValidation)
        }
        func printContinuously(_ rasters: [LabelRaster],
                               beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                               afterPages: @escaping @MainActor ([Int]) async throws -> Void) async -> LabelSendOutcome {
            await printer.performPrintJob(rasters, paperMode: paperMode, continuous: true,
                                          beforePages: beforePages, afterPages: afterPages,
                                          expectedPapers: expectedPapers, stockValidation: stockValidation)
        }
        func cancelPrinting() { printer.cancelPrinting() }
    }

    private func printLabel(_ raster: LabelRaster, paperMode: NiimbotPaperMode) async -> LabelSendOutcome {
        await printBatch([raster], paperMode: paperMode, beforePage: { _ in }, afterPage: { _ in })
    }

    private func printBatch(_ rasters: [LabelRaster], paperMode: NiimbotPaperMode,
                            beforePage: @escaping @MainActor (Int) async throws -> Void,
                            afterPage: @escaping @MainActor (Int) async throws -> Void) async -> LabelSendOutcome {
        await performPrintJob(rasters, paperMode: paperMode, continuous: false,
            beforePages: { pages in for page in pages { try await beforePage(page) } },
            afterPages: { pages in for page in pages { try await afterPage(page) } })
    }

    private func performPrintJob(_ rasters: [LabelRaster], paperMode: NiimbotPaperMode, continuous: Bool,
                                 beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                                 afterPages: @escaping @MainActor ([Int]) async throws -> Void,
                                 expectedPapers: [InventoryLabelSize] = [],
                                 stockValidation: PreparedStockValidation? = nil) async -> LabelSendOutcome {
        guard UIApplication.shared.applicationState == .active else { return .notSent(.notActive) }
        guard isConnected else { return .notSent(.notConnected) }
        guard !isPrinting, !isConfiguringPaper, pending == nil || pending?.optionalRollRead == true else { return .notSent(.printerBusy) }
        guard !rasters.isEmpty, rasters.count <= 250 else { return .notSent(.invalidLabel) }
        do { for raster in rasters { try raster.validate() } } catch { return .notSent(.invalidLabel) }

        let operation = UUID()
        printOperation = operation
        printEndAcknowledged = false
        printWasDispatched = false
        sendingPages = []
        dispatchedPages = []
        printCancellation = nil
        isPrinting = true
        error = nil
        status = "Checking \(modelName)…"
        defer {
            if printOperation == operation {
                printOperation = nil
                printEndAcknowledged = false
                activePrintStock = nil
                isPrinting = false
                printCancellation = nil
                sendingPages = []
                dispatchedPages = []
                refreshRollEstimate(force: false)
            }
        }

        return await withTaskCancellationHandler {
            do {
                await rollReader.waitUntilIdle()
                try checkPrintOperation(operation)
                let detected = LabelPaperPreferences.shared.detectedProduct
                if let stockValidation {
                    guard stockValidation.matches(connection: connectionGeneration, product: detected,
                                                   paperMode: self.paperMode) else { throw LabelPrinterIssue.paperMismatch }
                }
                if !expectedPapers.isEmpty,
                   LabelStockCompatibility.issue(for: expectedPapers, detected: detected) != nil {
                    throw LabelPrinterIssue.paperMismatch
                }
                // The latest RFID read owns both geometry and media mode. A
                // count becoming stale during printing does not erase the roll.
                let mode = detected == nil ? paperMode : self.paperMode
                activePrintStock = PreparedStockValidation(connection: connectionGeneration, product: detected, paperMode: mode)
                rollReader.markStale()
                try await sendBatch(rasters, operation: operation, paperMode: mode, continuous: continuous,
                                    beforePages: beforePages, afterPages: afterPages)
                try checkPrintOperation(operation)
                status = rasters.count == 1 ? "Label printed." : "\(rasters.count) labels printed."
                diagnostic(.complete)
                return .completed
            } catch {
                let issue = printCancellation ?? (error as? LabelPrinterIssue)
                    ?? (error is CancellationError ? .cancelled : .writeFailed)
                let wasDispatched = printWasDispatched
                endConnection(issue: issue, source: .requiredFailure)
                present(issue)
                diagnostic(wasDispatched ? .uncertain : .notSent, issue: issue)
                return wasDispatched ? .uncertain(issue) : .notSent(issue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.printOperation == operation else { return }
                self.cancelPrinting()
            }
        }
    }

    func selectPaperMode(_ mode: NiimbotPaperMode) {
        guard !isPrinting, !isConfiguringPaper, LabelPaperPreferences.shared.detectedProduct == nil else { return }
        savePaperMode(mode)
        paperModeStatus = nil
    }

    func readPaperMode() { configurePaper(reading: true) }
    func applyPaperMode() { configurePaper(reading: false) }

    /// Read-only and optional: inability to read a roll never prevents printing.
    func refreshRollEstimate(force: Bool = true) {
        if isReadingRoll {
            DiagnosticLog.shared.record("label.roll_read", ["roll_read_source": "in_flight", "roll_read_ms": "0"])
            return
        }
        guard canRefreshRollEstimate else {
            DiagnosticLog.shared.record("label.roll_read", ["roll_read_source": "unavailable", "roll_read_ms": "0"])
            return
        }
        let generation = connectionGeneration
        let load: @MainActor () async throws -> NiimbotRollInfo? = { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            defer {
                DiagnosticLog.shared.record("label.roll_read", ["roll_read_source": force ? "forced" : "read",
                    "roll_read_ms": String(NiimbotPrintTransferMetrics.milliseconds(started.duration(to: clock.now)))])
            }
            guard let self, self.connectionGeneration == generation,
                  self.isConnected, !self.rollReplyGuard.isQuarantined else { throw LabelPrinterIssue.printerBusy }
            // This task was authorized while idle. Print/settings may claim
            // their flags meanwhile, but must drain this read before writing.
            return try await NiimbotD110Session.readRollInfo { [weak self] request in
                guard let self, self.connectionGeneration == generation else { throw LabelPrinterIssue.connectionLost }
                return try await self.exchange(request, timeout: .milliseconds(750), optionalRollRead: true)
            }
        }
        let update: @MainActor (NiimbotRollInfo?) -> Void = { [weak self] info in
            guard let self, self.connectionGeneration == generation else { return }
            self.updateDetectedRoll(info)
        }
        if force { rollReader.refreshInfo(load: load, onUpdate: update) }
        else {
            let source = rollReader.refreshInfoIfNeeded(load: load, onUpdate: update)
            if source != .read {
                DiagnosticLog.shared.record("label.roll_read", ["roll_read_source": source.rawValue, "roll_read_ms": "0"])
            }
        }
    }

    private func updateDetectedRoll(_ info: NiimbotRollInfo?) {
        guard let info else {
            LabelPaperPreferences.shared.updateDetectedProduct(nil)
            rollProductStatus = "Roll could not be identified. Choose the paper size manually."
            return
        }
        guard let product = info.matchedProduct(in: .shared) else {
            LabelPaperPreferences.shared.updateDetectedProduct(nil)
            rollProductStatus = "Roll could not be matched to the offline catalog. Choose paper settings manually."
            return
        }
        LabelPaperPreferences.shared.updateDetectedProduct(product)
        rollProductStatus = "Label dimensions detected from the roll."
    }

    private func clearDetectedRoll() {
        LabelPaperPreferences.shared.updateDetectedProduct(nil)
        rollProductStatus = nil
    }

    private func savePaperMode(_ mode: NiimbotPaperMode) {
        if manualPaperMode != mode { rollReader.markStale() }
        manualPaperMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.paperModeDefaultsKey)
    }

    private func configurePaper(reading: Bool) {
        guard UIApplication.shared.applicationState == .active else { present(.notActive); return }
        guard isConnected, identity != nil else { present(.notConnected); return }
        guard !isPrinting, !isConfiguringPaper, pending == nil || pending?.optionalRollRead == true else { present(.printerBusy); return }
        let generation = connectionGeneration
        isConfiguringPaper = true
        paperModeStatus = reading ? "Reading printer setting…" : "Applying paper type…"
        error = nil
        paperTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionGeneration == generation {
                    self.isConfiguringPaper = false
                    self.paperTask = nil
                    if !self.rollEstimateIsFresh { self.refreshRollEstimate(force: false) }
                }
            }
            do {
                await self.rollReader.waitUntilIdle()
                try Task.checkCancellation()
                guard self.connectionGeneration == generation else { return }
                let selected = self.paperMode
                let exchange: NiimbotD110Session.Exchange = { [weak self] request in
                    guard let self, self.connectionGeneration == generation,
                          self.isConfiguringPaper else { throw LabelPrinterIssue.connectionLost }
                    return try await self.exchange(request)
                }
                if reading {
                    let mode = try await NiimbotD110Session.readPaperMode(exchange: exchange)
                    try Task.checkCancellation()
                    guard self.connectionGeneration == generation else { return }
                    if LabelPaperPreferences.shared.detectedProduct == nil { self.savePaperMode(mode) }
                    self.paperModeStatus = "Printer setting: \(mode.title)"
                    self.diagnostic(.paperRead)
                } else {
                    self.rollReader.markStale()
                    try await NiimbotD110Session.applyPaperMode(selected, exchange: exchange)
                    try Task.checkCancellation()
                    guard self.connectionGeneration == generation else { return }
                    self.paperModeStatus = "\(selected.title) applied to printer."
                    self.diagnostic(.paperApplied)
                }
            } catch {
                guard self.connectionGeneration == generation else { return }
                let issue = (error as? LabelPrinterIssue) ?? .unsupportedResponse
                self.paperModeStatus = reading
                    ? "The printer setting could not be read. Choose the paper type manually."
                    : "Paper type was not confirmed. Try again before printing."
                self.diagnostic(.paperFailed, issue: issue)
            }
        }
    }

    private var activePrintStockMatches: Bool {
        guard let stock = activePrintStock else { return true }
        return stock.matches(connection: connectionGeneration, product: LabelPaperPreferences.shared.detectedProduct,
                             paperMode: paperMode)
    }

    private func checkPrintOperation(_ operation: UUID) throws {
        if let printCancellation { throw printCancellation }
        try Task.checkCancellation()
        guard printOperation == operation else { throw LabelPrinterIssue.cancelled }
        guard UIApplication.shared.applicationState == .active else { throw LabelPrinterIssue.notActive }
        guard isConnected, peripheral?.state == .connected else { throw LabelPrinterIssue.connectionLost }
        // Stock changes after the positive final receipt affect the next job,
        // while cancellation, app state and the actual Bluetooth link above
        // still gate the cleanup heartbeat and successful return.
        guard printEndAcknowledged || activePrintStockMatches else { throw LabelPrinterIssue.paperMismatch }
    }

    private func stopScanning() {
        scanRequested = false
        autoReconnectID = nil
        permissionSearchIntent.cancel()
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        isScanning = false
    }

    private func beginScanning(_ central: CBCentralManager) {
        guard scanRequested, !isScanning, UIApplication.shared.applicationState == .active else { return }
        permissionSearchIntent.cancel()
        scanTimeout?.cancel()
        devices = []
        discovered = [:]
        isScanning = true
        status = "Searching for NIIMBOT D110 / D110-M…"
        // D110 advertisements do not consistently include their service UUID.
        // Name filtering is followed by service and protocol identity checks.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self else { return }
            self.stopScanning()
            self.status = self.devices.isEmpty
                ? "No D110 or D110-M found. Disconnect it in other apps, turn it on and search again."
                : "Select your printer."
        }
        diagnostic(.search)
    }

    private func updateBluetoothState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanRequested { beginScanning(central) }
        case .unauthorized:
            stopScanning()
            endConnection(issue: .permissionDenied, source: .requiredFailure)
            present(.permissionDenied)
        case .poweredOff, .unsupported:
            stopScanning()
            endConnection(issue: .bluetoothUnavailable, source: .requiredFailure)
            present(.bluetoothUnavailable)
        case .resetting:
            stopScanning()
            endConnection(issue: .connectionLost, source: .requiredFailure)
            status = "Bluetooth is resetting. Search again when ready."
        case .unknown:
            status = "Waiting for Bluetooth…"
        @unknown default:
            stopScanning()
            endConnection(issue: .bluetoothUnavailable, source: .requiredFailure)
            present(.bluetoothUnavailable)
        }
    }

    private func endConnection(issue: LabelPrinterIssue, source: ConnectionEndSource) {
        if peripheral != nil || pending != nil || isConnected {
            let phase = UIApplication.shared.applicationState
            DiagnosticLog.shared.record("label.connection_ended", ["connection_end_source": source.rawValue,
                "reason": issue.rawValue, "phase": phase == .active ? "active" : phase == .background ? "background" : "inactive"])
        }
        if isPrinting, printCancellation == nil { printCancellation = issue }
        connectionGeneration = UUID()
        printEndAcknowledged = false
        activePrintStock = nil
        rollReader.reset(); rollReplyGuard = NiimbotOptionalRollReplyGuard()
        clearDetectedRoll()
        connectionStage = nil
        identificationStep = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        paperTask?.cancel()
        paperTask = nil
        isConfiguringPaper = false
        paperModeStatus = nil
        failTransfer(issue)
        isConnected = false
        identity = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        parser = NiimbotStreamParser()
        if let peripheral {
            peripheral.delegate = nil
            if peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
        }
        peripheral = nil
    }

    private func connectionFailed(_ issue: LabelPrinterIssue) {
        let duringSetup = !isConnected && !isPrinting
        // Preserve the pending command and progress before teardown clears it.
        diagnostic(isPrinting ? .printFailed : .connectFailed, issue: issue)
        endConnection(issue: issue, source: .requiredFailure)
        if duringSetup && issue == .responseTimeout {
            let message = "Printer setup timed out. Turn the printer off and on, then search and connect again."
            error = message; status = message
        } else { present(issue) }
    }

    private func present(_ issue: LabelPrinterIssue) {
        error = issue.localizedDescription
        status = issue.localizedDescription
    }

    private func diagnostic(_ phase: DiagnosticPhase, issue: LabelPrinterIssue? = nil) {
        // Fixed phases, typed issues and negotiated model codes only.
        // Never record advertised names, peripheral IDs,
        // notification payloads, raster bytes, or label text.
        var fields = ["phase": phase.rawValue]
        if let issue { fields["reason"] = issue.rawValue }
        if isPrinting {
            fields["stage"] = pending.map { Self.printStage(for: $0.command) } ?? "printing"
        } else if !isConnected, let connectionStage {
            fields["stage"] = identificationStep?.rawValue ?? connectionStage.rawValue
        }
        if isPrinting || connectionStage != nil {
            fields["write_mode"] = writeType == .withResponse ? "acknowledged" : "unacknowledged"
        }
        if let transaction = pending {
            fields["request_code"] = String(transaction.command)
            if let response = transaction.expectedResponse { fields["response_code"] = String(response) }
            if let response = transaction.lastResponseCode { fields["last_response_code"] = String(response) }
            fields["sent_bytes"] = String(transaction.offset)
            fields["notification_count"] = String(transaction.notificationCount)
            fields["notification_bytes"] = String(transaction.notificationBytes)
            fields["packet_count"] = String(transaction.packetCount)
        }
        if phase == .identified, let identity {
            fields["code"] = String(identity.modelID)
            fields["stage"] = "protocol_" + String(identity.protocolVersion)
        }
        DiagnosticLog.shared.record("label.bluetooth", fields)
    }

    private static func printStage(for command: UInt8) -> String {
        switch command {
        case 0x21: return "print_density"
        case 0x23: return "paper_type"
        case 0x01: return "print_start"
        case 0x03: return "page_start"
        case 0x13: return "page_size"
        case 0x83, 0x84, 0x85: return "image_rows"
        case 0xe3: return "page_end"
        case 0xa3: return "print_status"
        case 0xf3: return "print_end"
        case 0xdc: return "printer_status"
        default: return "print_command"
        }
    }

    /// Trace control requests and failures, without logging every raster row.
    private var tracesPendingTransfer: Bool {
        pending?.optionalRollRead != true && (!isConnected || (isPrinting && pending?.expectedResponse != nil))
    }

    /// Exactly one request is in flight. Required-command timeouts retire the
    /// connection. Optional RFID timeouts instead quarantine further reads
    /// until reconnect, so a late reply cannot be accepted as fresh metadata.
    private func transfer(command: UInt8, data: Data, response: UInt8?, responseAlternatives: Set<UInt8> = [],
                          beginsPrint: Bool = false,
                          optionalRollRead: Bool = false,
                          timeout: Duration = .seconds(5)) async throws -> NiimbotPacket? {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw LabelPrinterIssue.notActive }
        guard peripheral?.state == .connected, writeCharacteristic != nil else { throw LabelPrinterIssue.notConnected }
        guard pending == nil else { throw LabelPrinterIssue.printerBusy }
        let cleanupHeartbeat = printEndAcknowledged && command == 0xdc && data == Data([1]) && response == nil
        if isPrinting && !optionalRollRead && !cleanupHeartbeat, !activePrintStockMatches { throw LabelPrinterIssue.paperMismatch }
        if optionalRollRead {
            guard command == 0x1a, response == 0x1b, responseAlternatives.isEmpty, !beginsPrint,
                  writeCharacteristic?.properties.contains(.writeWithoutResponse) == true else {
                rollReplyGuard.markUnsupported()
                throw LabelPrinterIssue.unsupportedResponse
            }
        }
        let bytes = try encodePacket(command: command, data: data)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: LabelPrinterIssue.cancelled); return }
                // Printing/settings retain their negotiated ATT write type.
                // The tiny optional read uses the advertised no-response path
                // so abandoning it cannot misapply a later ATT write callback.
                let transaction = Transfer(id: id, command: command, bytes: bytes, expectedResponse: response,
                                           responseAlternatives: responseAlternatives, beginsPrint: beginsPrint,
                                           optionalRollRead: optionalRollRead,
                                           pageCopies: NiimbotPrintTransferMetrics.pageCopies(command: command, data: data),
                                           cleanupHeartbeat: cleanupHeartbeat,
                                           writeType: optionalRollRead ? .withoutResponse : writeType,
                                           continuation: continuation)
                pending = transaction
                if tracesPendingTransfer { diagnostic(.requestStarted) }
                transaction.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.pending?.id == id else { return }
                    if optionalRollRead { self.failOptionalRollTransfer(.responseTimeout, ambiguous: (self.pending?.offset ?? 0) > 0) }
                    else { self.connectionFailed(.responseTimeout) }
                }
                driveWrite()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pending?.id == id else { return }
                if self.pending?.optionalRollRead == true {
                    self.failOptionalRollTransfer(.cancelled, ambiguous: (self.pending?.offset ?? 0) > 0)
                } else { self.endConnection(issue: .cancelled, source: .requestCancelled) }
            }
        }
    }

    private func driveWrite() {
        guard let transaction = pending, !transaction.awaitingWriteResponse else { return }
        guard UIApplication.shared.applicationState == .active else { connectionFailed(.notActive); return }
        if isPrinting && !transaction.optionalRollRead && !transaction.cleanupHeartbeat,
           !activePrintStockMatches { connectionFailed(.paperMismatch); return }
        guard let peripheral, peripheral.state == .connected, let writeCharacteristic else {
            connectionFailed(.connectionLost)
            return
        }
        let maximumLength = peripheral.maximumWriteValueLength(for: transaction.writeType)
        if transaction.optionalRollRead && maximumLength < transaction.bytes.count {
            failOptionalRollTransfer(.unsupportedResponse, ambiguous: false)
            return
        }
        guard maximumLength > 0 else { connectionFailed(.writeFailed); return }
        // CoreBluetooth reports the negotiated payload limit for this write
        // type. No ATT size is assumed; without-response writes additionally
        // observe the peripheral's transmit backpressure.
        let chunkLength = maximumLength

        while transaction.offset < transaction.bytes.count {
            if transaction.writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                if !transaction.reportedWriteBlocked {
                    transaction.reportedWriteBlocked = true
                    diagnostic(.writeBlocked)
                }
                return
            }
            let end = min(transaction.offset + chunkLength, transaction.bytes.count)
            let chunk = transaction.bytes.subdata(in: transaction.offset..<end)
            let startsRequest = transaction.offset == 0
            transaction.offset = end
            if transaction.beginsPrint {
                dispatchedPages.formUnion(sendingPages)
                printWasDispatched = !dispatchedPages.isEmpty
            }
            if transaction.writeType == .withResponse {
                transaction.awaitingWriteResponse = true
                transaction.waitTiming.startAcknowledgement(at: ContinuousClock().now)
            }
            peripheral.writeValue(chunk, for: writeCharacteristic, type: transaction.writeType)
            if !transaction.optionalRollRead {
                activePrintMetrics?.recordWrite(command: transaction.command, response: transaction.expectedResponse,
                    copies: transaction.pageCopies, byteCount: chunk.count, startsRequest: startsRequest)
            }
            if transaction.writeType == .withResponse { return }
        }
        if transaction.expectedResponse != nil && transaction.response == nil {
            transaction.waitTiming.startReply(at: ContinuousClock().now)
        }
        if tracesPendingTransfer && !transaction.reportedSent {
            transaction.reportedSent = true
            diagnostic(.requestSent)
        }
        finishTransferIfReady()
    }

    private func encodePacket(command: UInt8, data: Data) throws -> Data {
        let clock = ContinuousClock()
        let started = clock.now
        defer { activePrintMetrics?.add(.packetEncode, duration: started.duration(to: clock.now)) }
        return try NiimbotProtocol.encode(command: command, data: data)
    }

    private func finishTransferTiming(_ transaction: Transfer) {
        transaction.waitTiming.finish(at: ContinuousClock().now)
        guard !transaction.optionalRollRead else { return }
        activePrintMetrics?.add(.attAcknowledgement, duration: transaction.waitTiming.acknowledgement)
        activePrintMetrics?.add(.printerReply, duration: transaction.waitTiming.reply)
    }

    private func finishTransferIfReady() {
        guard let transaction = pending, !transaction.awaitingWriteResponse,
              transaction.offset == transaction.bytes.count,
              transaction.expectedResponse == nil || transaction.response != nil else { return }
        finishTransferTiming(transaction)
        pending = nil
        transaction.timeout?.cancel()
        if isPrinting, transaction.command == 0xf3, transaction.expectedResponse == 0xf4 {
            // Both the ATT write and the positive printer reply must complete
            // before a late cleanup/status error can become a warning.
            let end = NiimbotRequest(0xf3, response: 0xf4, requiresTrue: true)
            do { try end.validateResponse(transaction.response); printEndAcknowledged = true }
            catch { /* Required response validation remains fatal in the session. */ }
        }
        transaction.continuation.resume(returning: transaction.response)
    }

    private func failTransfer(_ issue: LabelPrinterIssue) {
        guard let transaction = pending else { return }
        finishTransferTiming(transaction)
        pending = nil
        transaction.timeout?.cancel()
        transaction.continuation.resume(throwing: issue)
    }

    private func failOptionalRollTransfer(_ issue: LabelPrinterIssue, ambiguous: Bool) {
        guard pending?.optionalRollRead == true else { return }
        rollReplyGuard.abandonRead(wasSent: ambiguous)
        if issue == .unsupportedResponse { rollReplyGuard.markUnsupported() }
        failTransfer(issue)
    }

    private var errorReplyDisposition: NiimbotErrorReplyDisposition {
        let request: NiimbotErrorReplyDisposition.Request
        if let pending {
            request = pending.optionalRollRead ? .optionalRoll : pending.cleanupHeartbeat ? .cleanupHeartbeat : .required
        } else { request = .none }
        return NiimbotErrorReplyDisposition.resolve(verified: isConnected && identity != nil,
            settingUp: connectionStage != nil, printing: isPrinting, configuring: isConfiguringPaper,
            printEndAcknowledged: printEndAcknowledged, request: request)
    }

    /// Parsed error replies and unsolicited post-end stock/readiness changes
    /// cannot invalidate a completed job. Radio failures and required-command
    /// errors/timeouts retain their existing teardown.
    private func handlePrinterErrorReply(_ issue: LabelPrinterIssue) -> Bool {
        let disposition = errorReplyDisposition
        guard disposition != .disconnect else { connectionFailed(issue); return false }
        diagnostic(.printerWarning, issue: issue)
        if disposition == .rejectOptionalRoll {
            failOptionalRollTransfer(issue, ambiguous: (pending?.offset ?? 0) > 0)
        } else { rollReader.markStale() }
        if issue == .paperMismatch { clearDetectedRoll() }
        switch issue {
        case .paperMismatch, .printerNotReady:
            error = "Printer connected. Check that it is closed and loaded with the correct labels."
        case .printerBusy:
            error = "Printer connected. Wait for it to finish before printing again."
        default:
            error = "Printer connected, but reported a status warning. Check the printer before printing again."
        }
        if !isPrinting { status = "\(modelName) connected. Check the printer before printing again." }
        return true
    }

    private func receive(_ bytes: Data) {
        if let transaction = pending {
            transaction.notificationCount = min(1_000_000, transaction.notificationCount + 1)
            transaction.notificationBytes = min(1_000_000, transaction.notificationBytes + bytes.count)
        }
        for packet in parser.append(bytes) {
            if let transaction = pending {
                transaction.packetCount = min(1_000_000, transaction.packetCount + 1)
                transaction.lastResponseCode = packet.command
            }
            if packet.command == 0xdb {
                if !handlePrinterErrorReply(NiimbotProtocol.issueForPrintError(packet)) { return }
                continue
            }
            if rollReplyGuard.consumeLateResponse(packet.command) { continue }
            if packet.command == 0x00 {
                if !handlePrinterErrorReply(isConnected ? .unsupportedResponse : .unsupportedPrinter) { return }
                continue
            }
            if packet.command == 0x1b && pending?.optionalRollRead != true {
                rollReader.markStale()
                let known = LabelPaperPreferences.shared.detectedProduct
                let reported = (try? NiimbotProtocol.rollInfo(packet))?.matchedProduct(in: .shared)
                if known == nil || reported != known {
                    clearDetectedRoll()
                    if isPrinting {
                        guard errorReplyDisposition == .warnConnected else { connectionFailed(.paperMismatch); return }
                        _ = handlePrinterErrorReply(.paperMismatch)
                    }
                }
                continue
            }
            if let identity, [UInt8(0xdd), 0xd9].contains(packet.command) {
                do { try NiimbotProtocol.validateReadiness(packet, identity: identity) }
                catch {
                    rollReader.markStale(); clearDetectedRoll()
                    if isPrinting {
                        let issue = (error as? LabelPrinterIssue) ?? .paperMismatch
                        guard errorReplyDisposition == .warnConnected else { connectionFailed(issue); return }
                        _ = handlePrinterErrorReply(issue)
                    }
                }
            }
            guard let transaction = pending,
                  transaction.offset == transaction.bytes.count,
                  transaction.expectedResponse == packet.command || transaction.responseAlternatives.contains(packet.command),
                  transaction.response == nil else { continue }
            transaction.waitTiming.finishReply(at: ContinuousClock().now)
            transaction.response = packet
            if tracesPendingTransfer { diagnostic(.replyReceived) }
            finishTransferIfReady()
        }
    }

    private func beginHandshake() {
        guard handshakeTask == nil else { return }
        let generation = connectionGeneration
        connectionStage = .identification
        status = "Identifying printer…"
        handshakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await NiimbotD110Session.identify(onStep: { [weak self] step in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.identificationStep = step
                }) { [weak self] request in
                    guard let self, self.connectionGeneration == generation else { throw LabelPrinterIssue.connectionLost }
                    return try await self.exchange(request)
                }
                try Task.checkCancellation()
                guard self.connectionGeneration == generation else { return }
                self.identity = identity
                self.connectionStage = nil
                self.identificationStep = nil
                self.isConnected = true
                if let id = self.peripheral?.identifier {
                    UserDefaults.standard.set(id.uuidString, forKey: Self.lastPrinterDefaultsKey)
                }
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                self.handshakeTask = nil
                self.status = "\(identity.modelName) connected. Confirm the loaded label size before printing."
                self.diagnostic(.identified)
                self.refreshRollEstimate(force: false)
            } catch {
                guard self.connectionGeneration == generation else { return }
                self.connectionFailed((error as? LabelPrinterIssue) ?? .unsupportedPrinter)
            }
        }
    }

    private func exchange(_ request: NiimbotRequest, timeout: Duration = .seconds(5), optionalRollRead: Bool = false) async throws -> NiimbotPacket? {
        // The reference's BLE transport spaces complete packets by 10ms. Radio
        // backpressure alone does not bound the UART module's consumer speed.
        try await pacePacket()
        return try await transfer(command: request.command, data: request.data, response: request.response,
                                  responseAlternatives: request.responseAlternatives, beginsPrint: request.beginsPrint,
                                  optionalRollRead: optionalRollRead,
                                  timeout: timeout)
    }

    private func pacePacket() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        defer { activePrintMetrics?.add(.packetPacing, duration: started.duration(to: clock.now)) }
        try await Task.sleep(for: .milliseconds(10))
    }

    private func sendBatch(_ rasters: [LabelRaster], operation: UUID, paperMode: NiimbotPaperMode, continuous: Bool,
                           beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                           afterPages: @escaping @MainActor ([Int]) async throws -> Void) async throws {
        guard let identity else { throw LabelPrinterIssue.unsupportedPrinter }
        let clock = ContinuousClock()
        let started = clock.now
        activePrintMetrics = NiimbotPrintTransferMetrics(identity: identity, continuous: continuous, total: rasters.count,
            previousJobGap: lastPrintAttemptEnded.map { $0.duration(to: started) })
        defer {
            let ended = clock.now
            let elapsed = NiimbotPrintTransferMetrics.milliseconds(started.duration(to: ended))
            if let metrics = activePrintMetrics {
                DiagnosticLog.shared.record("label.transfer_summary", metrics.diagnosticFields(elapsedMilliseconds: elapsed))
            }
            activePrintMetrics = nil
            lastPrintAttemptEnded = ended
        }
        // Refresh on submission and physical progress so a healthy buffered
        // job is not limited by the former single-label task deadline.
        var deadline = clock.now.advanced(by: .seconds(60))
        var pageStarts: [Int: ContinuousClock.Instant] = [:]
        var groupStarts: [Int: NiimbotPrintTransferMetrics] = [:]
        recordPrintProgress(.batchStarted, page: 0, total: rasters.count, started: clock.now, quantity: rasters.count)
        let exchange: NiimbotD110Session.Exchange = { [weak self] request in
            guard let self else { throw LabelPrinterIssue.connectionLost }
            try self.checkPrintOperation(operation)
            guard clock.now < deadline else { throw LabelPrinterIssue.responseTimeout }
            // The reference gives buffered page setup/end acknowledgements
            // ten seconds, allowing the printer to make room for another page.
            let bufferedPage = continuous && rasters.count > 1 && identity.modelID == 2320
                && [UInt8(0x03), 0x13, 0xe3].contains(request.command)
            let requestStarted = clock.now
            defer {
                self.activePrintMetrics?.recordRequestSpan(command: request.command, response: request.response,
                    duration: requestStarted.duration(to: clock.now))
            }
            return try await self.exchange(request, timeout: bufferedPage ? .seconds(10) : .seconds(5))
        }
        let pause: @MainActor () async throws -> Void = { [weak self] in
            let started = clock.now
            defer { self?.activePrintMetrics?.add(.statusBackoff, duration: started.duration(to: clock.now)) }
            try await Task.sleep(for: .milliseconds(300))
        }
        let willSend: @MainActor ([Int]) async throws -> Void = { [weak self] pages in
            guard let self else { throw LabelPrinterIssue.connectionLost }
            guard let first = pages.first, let last = pages.last,
                  pages.allSatisfy({ rasters.indices.contains($0) }) else { throw LabelPrinterIssue.unsupportedResponse }
            // Legacy D110 starts a separate physical job for each copy. A
            // previous copy's final receipt cannot relax this copy's checks.
            self.printEndAcknowledged = false
            try self.checkPrintOperation(operation)
            try await beforePages(pages)
            try self.checkPrintOperation(operation)
            self.sendingPages = pages
            deadline = clock.now.advanced(by: .seconds(60))
            let started = clock.now
            for page in pages { pageStarts[page] = started }
            let range = first == last ? "\(first + 1)" : "\(first + 1)–\(last + 1)"
            self.status = "Sending labels \(range) of \(rasters.count)…"
            self.recordPrintProgress(.pageStarted, page: first + 1, total: rasters.count,
                                     started: started, quantity: pages.count)
        }
        let didComplete: @MainActor ([Int]) async throws -> Void = { [weak self] pages in
            guard let self, self.printOperation == operation else { throw LabelPrinterIssue.cancelled }
            guard let first = pages.first, let last = pages.last else { throw LabelPrinterIssue.unsupportedResponse }
            // Persist the whole physical counter proof, including when Stop
            // arrived with it. Later buffered pages remain unconfirmed.
            self.dispatchedPages.subtract(pages)
            self.printWasDispatched = !self.dispatchedPages.isEmpty
            let started = pageStarts[first] ?? clock.now
            try await afterPages(pages)
            deadline = clock.now.advanced(by: .seconds(60))
            for page in pages { pageStarts[page] = nil }
            self.status = "Printed \(last + 1) of \(rasters.count) labels."
            self.recordPrintProgress(.pageCompleted, page: last + 1, total: rasters.count,
                                     started: started, quantity: pages.count)
        }
        let observe: NiimbotD110Session.Measurement = { [weak self] measurement in
            guard let self else { return }
            switch measurement {
            case let .planEncoded(duration): self.activePrintMetrics?.add(.planEncode, duration: duration)
            case let .groupStarted(pages): groupStarts[pages.lowerBound] = self.activePrintMetrics
            case let .groupSubmitted(pages, duration, accepted):
                if let metrics = self.activePrintMetrics, let before = groupStarts.removeValue(forKey: pages.lowerBound) {
                    DiagnosticLog.shared.record("label.group_transfer", metrics.groupFields(since: before,
                        elapsed: duration, pages: pages, accepted: accepted))
                }
            }
        }
        if continuous {
            try await NiimbotD110Session.printContinuously(rasters, identity: identity, paperMode: paperMode,
                exchange: exchange, pause: pause, onPagesWillSend: willSend, onPagesCompleted: didComplete, onMeasurement: observe)
        } else {
            try await NiimbotD110Session.printBatch(rasters, identity: identity, paperMode: paperMode,
                exchange: exchange, pause: pause, onPageWillSend: { try await willSend([$0]) },
                onPageCompleted: { try await didComplete([$0]) }, onMeasurement: observe)
        }
    }

    private func recordPrintProgress(_ phase: PrintPhase, page: Int, total: Int, started: ContinuousClock.Instant, quantity: Int = 1) {
        let elapsed = NiimbotPrintTransferMetrics.milliseconds(started.duration(to: ContinuousClock().now))
        DiagnosticLog.shared.record("label.print", ["phase": phase.rawValue, "page": String(page),
            "total": String(total), "quantity": String(quantity), "elapsed_ms": String(elapsed)])
    }

    /// CoreBluetooth callbacks need not reuse the discovery wrapper object.
    /// The current peripheral and selected service/channel identify the link.
    private func matchesChannel(_ characteristic: CBCharacteristic, _ selected: CBCharacteristic?) -> Bool {
        guard let selected, let expectedService = selected.service?.uuid,
              let actualService = characteristic.service?.uuid else { return false }
        return characteristic.uuid == selected.uuid && actualService == expectedService
    }
}

extension NiimbotPrinter: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateBluetoothState(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isScanning, UIApplication.shared.applicationState == .active else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let isRemembered = autoReconnectID == peripheral.identifier
        guard isRemembered || name.map(NiimbotProtocol.isD110Advertisement) == true else { return }
        discovered[peripheral.identifier] = peripheral
        if isRemembered {
            connect(peripheral.identifier)
            return
        }
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        devices.append(NiimbotDiscoveredPrinter(id: peripheral.identifier, name: name ?? "NIIMBOT printer"))
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, UIApplication.shared.applicationState == .active else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectionStage = .services
        diagnostic(.linkReady)
        status = "Checking printer services…"
        peripheral.discoverServices([CBUUID(string: NiimbotProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectionFailed(.connectionLost)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectionFailed(.connectionLost)
    }
}

extension NiimbotPrinter: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: NiimbotProtocol.serviceUUID)
        }) else { connectionFailed(.unsupportedPrinter); return }
        connectionStage = .characteristics
        diagnostic(.servicesReady)
        // The reference discovers the UART channel by properties. It does not
        // assume fixed FFE1/FFE2 characteristic UUIDs, or two separate channels.
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil,
              let channel = service.characteristics?.first(where: {
                  $0.properties.contains(.notify) && $0.properties.contains(.writeWithoutResponse)
              }) else {
            connectionFailed(.unsupportedPrinter)
            return
        }
        writeCharacteristic = channel
        notifyCharacteristic = channel
        // Use ATT acknowledgement when this UART channel explicitly supports it.
        // Firmware with only writeWithoutResponse retains the reference path.
        writeType = channel.properties.contains(.write) ? .withResponse : .withoutResponse
        connectionStage = .notifications
        diagnostic(.channelReady)
        peripheral.setNotifyValue(true, for: channel)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, matchesChannel(characteristic, notifyCharacteristic) else { return }
        guard error == nil, characteristic.isNotifying else { connectionFailed(.unsupportedPrinter); return }
        diagnostic(.notificationsReady)
        beginHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, matchesChannel(characteristic, notifyCharacteristic) else { return }
        guard error == nil, let value = characteristic.value else { connectionFailed(.connectionLost); return }
        receive(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, matchesChannel(characteristic, writeCharacteristic),
              let transaction = pending, transaction.awaitingWriteResponse else { return }
        let acknowledged = ContinuousClock().now
        transaction.waitTiming.finishAcknowledgement(at: acknowledged)
        guard error == nil else { connectionFailed(.writeFailed); return }
        transaction.awaitingWriteResponse = false
        if transaction.offset == transaction.bytes.count && transaction.expectedResponse != nil && transaction.response == nil {
            transaction.waitTiming.startReply(at: acknowledged)
        }
        driveWrite()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        driveWrite()
    }
}
