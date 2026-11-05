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
    private(set) var paperMode: NiimbotPaperMode
    private(set) var paperModeStatus: String?
    private(set) var status = "Search for a NIIMBOT D110 or D110-M to connect."
    var modelName: String { identity?.modelName ?? "D110 / D110-M" }
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
    @ObservationIgnored private var printWasDispatched = false
    @ObservationIgnored private var printCancellation: LabelPrinterIssue?
    @ObservationIgnored private var identity: NiimbotD110Identity?
    @ObservationIgnored private var paperTask: Task<Void, Never>?
    @ObservationIgnored private var connectionStage: ConnectionStage?
    @ObservationIgnored private var identificationStep: NiimbotIdentificationStep?
    private static let paperModeDefaultsKey = "niimbotPaperMode"
    private static let lastPrinterDefaultsKey = "niimbotLastVerifiedPrinter"

    private enum ConnectionStage: String { case connecting, services, characteristics, notifications, identification }
    private enum PrintPhase: String { case batchStarted = "batch_started", pageStarted = "page_started", pageCompleted = "page_completed" }
    private enum DiagnosticPhase: String {
        case search, connect, identified, cancel, complete, uncertain
        case connectFailed = "connect_failed"
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
    }

    private final class Transfer {
        let id: UUID
        let command: UInt8
        let bytes: Data
        let expectedResponse: UInt8?
        let responseAlternatives: Set<UInt8>
        let beginsPrint: Bool
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

        init(id: UUID, command: UInt8, bytes: Data, expectedResponse: UInt8?, responseAlternatives: Set<UInt8>, beginsPrint: Bool,
             writeType: CBCharacteristicWriteType,
             continuation: CheckedContinuation<NiimbotPacket?, Error>) {
            self.id = id
            self.command = command
            self.bytes = bytes
            self.expectedResponse = expectedResponse
            self.responseAlternatives = responseAlternatives
            self.beginsPrint = beginsPrint
            self.writeType = writeType
            self.continuation = continuation
        }
    }

    private override init() {
        paperMode = UserDefaults.standard.string(forKey: NiimbotPrinter.paperModeDefaultsKey)
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
        endConnection(issue: .cancelled)
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
        endConnection(issue: .cancelled)
        status = "Disconnected."
    }

    /// Called when the app leaves the foreground. There is no restoration,
    /// background reconnect or automatic print replay on returning.
    func stop() {
        if isPrinting { printCancellation = .notActive }
        stopScanning()
        endConnection(issue: .notActive)
        devices = []
        discovered = [:]
        status = "Disconnected. Search again when ready."
    }

    func cancelPrinting() {
        guard isPrinting else { return }
        printCancellation = .cancelled
        endConnection(issue: .cancelled)
        status = "Printing stopped. Check the printer before trying again."
        diagnostic(.cancel)
    }

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
        await printLabel(raster, paperMode: paperMode)
    }

    /// A queue captures the physical roll setting once, before its first copy.
    /// Saved artwork and completion receipts do not need to be rewritten.
    func senderForCurrentPaperMode() -> any LabelPrinterSending {
        PaperModeSender(printer: self, paperMode: paperMode)
    }

    @MainActor private final class PaperModeSender: LabelBatchPrinterSending {
        let printer: NiimbotPrinter
        let paperMode: NiimbotPaperMode

        init(printer: NiimbotPrinter, paperMode: NiimbotPaperMode) {
            self.printer = printer; self.paperMode = paperMode
        }
        func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
            await printer.printLabel(raster, paperMode: paperMode)
        }
        func printBatch(_ rasters: [LabelRaster],
                        beforePage: @escaping @MainActor (Int) async throws -> Void,
                        afterPage: @escaping @MainActor (Int) async throws -> Void) async -> LabelSendOutcome {
            await printer.printBatch(rasters, paperMode: paperMode, beforePage: beforePage, afterPage: afterPage)
        }
        func cancelPrinting() { printer.cancelPrinting() }
    }

    private func printLabel(_ raster: LabelRaster, paperMode: NiimbotPaperMode) async -> LabelSendOutcome {
        await printBatch([raster], paperMode: paperMode, beforePage: { _ in }, afterPage: { _ in })
    }

    private func printBatch(_ rasters: [LabelRaster], paperMode: NiimbotPaperMode,
                            beforePage: @escaping @MainActor (Int) async throws -> Void,
                            afterPage: @escaping @MainActor (Int) async throws -> Void) async -> LabelSendOutcome {
        guard UIApplication.shared.applicationState == .active else { return .notSent(.notActive) }
        guard isConnected else { return .notSent(.notConnected) }
        guard !isPrinting, !isConfiguringPaper, pending == nil else { return .notSent(.printerBusy) }
        guard !rasters.isEmpty, rasters.count <= 250 else { return .notSent(.invalidLabel) }
        do { for raster in rasters { try raster.validate() } } catch { return .notSent(.invalidLabel) }

        let operation = UUID()
        printOperation = operation
        printWasDispatched = false
        printCancellation = nil
        isPrinting = true
        error = nil
        status = "Checking \(modelName)…"
        defer {
            if printOperation == operation {
                printOperation = nil
                isPrinting = false
                printCancellation = nil
            }
        }

        return await withTaskCancellationHandler {
            do {
                try checkPrintOperation(operation)
                try await sendBatch(rasters, operation: operation, paperMode: paperMode,
                                    beforePage: beforePage, afterPage: afterPage)
                try checkPrintOperation(operation)
                status = rasters.count == 1 ? "Label printed." : "\(rasters.count) labels printed."
                diagnostic(.complete)
                return .completed
            } catch {
                let issue = printCancellation ?? (error as? LabelPrinterIssue)
                    ?? (error is CancellationError ? .cancelled : .writeFailed)
                let wasDispatched = printWasDispatched
                endConnection(issue: issue)
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
        guard !isPrinting, !isConfiguringPaper else { return }
        savePaperMode(mode)
        paperModeStatus = nil
    }

    func readPaperMode() { configurePaper(reading: true) }
    func applyPaperMode() { configurePaper(reading: false) }

    private func savePaperMode(_ mode: NiimbotPaperMode) {
        paperMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.paperModeDefaultsKey)
    }

    private func configurePaper(reading: Bool) {
        guard UIApplication.shared.applicationState == .active else { present(.notActive); return }
        guard isConnected, identity != nil else { present(.notConnected); return }
        guard !isPrinting, !isConfiguringPaper, pending == nil else { present(.printerBusy); return }
        let generation = connectionGeneration, selected = paperMode
        isConfiguringPaper = true
        paperModeStatus = reading ? "Reading printer setting…" : "Applying \(selected.title)…"
        error = nil
        paperTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionGeneration == generation {
                    self.isConfiguringPaper = false
                    self.paperTask = nil
                }
            }
            do {
                let exchange: NiimbotD110Session.Exchange = { [weak self] request in
                    guard let self, self.connectionGeneration == generation,
                          self.isConfiguringPaper else { throw LabelPrinterIssue.connectionLost }
                    return try await self.exchange(request)
                }
                if reading {
                    let mode = try await NiimbotD110Session.readPaperMode(exchange: exchange)
                    try Task.checkCancellation()
                    guard self.connectionGeneration == generation else { return }
                    self.savePaperMode(mode)
                    self.paperModeStatus = "Printer setting: \(mode.title)"
                    self.diagnostic(.paperRead)
                } else {
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

    private func checkPrintOperation(_ operation: UUID) throws {
        if let printCancellation { throw printCancellation }
        try Task.checkCancellation()
        guard printOperation == operation else { throw LabelPrinterIssue.cancelled }
        guard UIApplication.shared.applicationState == .active else { throw LabelPrinterIssue.notActive }
        guard isConnected, peripheral?.state == .connected else { throw LabelPrinterIssue.connectionLost }
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
            endConnection(issue: .permissionDenied)
            present(.permissionDenied)
        case .poweredOff, .unsupported:
            stopScanning()
            endConnection(issue: .bluetoothUnavailable)
            present(.bluetoothUnavailable)
        case .resetting:
            stopScanning()
            endConnection(issue: .connectionLost)
            status = "Bluetooth is resetting. Search again when ready."
        case .unknown:
            status = "Waiting for Bluetooth…"
        @unknown default:
            stopScanning()
            endConnection(issue: .bluetoothUnavailable)
            present(.bluetoothUnavailable)
        }
    }

    private func endConnection(issue: LabelPrinterIssue) {
        if isPrinting, printCancellation == nil { printCancellation = issue }
        connectionGeneration = UUID()
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
        diagnostic(.connectFailed, issue: issue)
        endConnection(issue: issue)
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
        if !isConnected, let connectionStage {
            fields["stage"] = identificationStep?.rawValue ?? connectionStage.rawValue
            fields["write_mode"] = writeType == .withResponse ? "acknowledged" : "unacknowledged"
            if let transaction = pending {
                fields["request_code"] = String(transaction.command)
                if let response = transaction.expectedResponse { fields["response_code"] = String(response) }
                if let response = transaction.lastResponseCode { fields["last_response_code"] = String(response) }
                fields["sent_bytes"] = String(transaction.offset)
                fields["notification_count"] = String(transaction.notificationCount)
                fields["notification_bytes"] = String(transaction.notificationBytes)
                fields["packet_count"] = String(transaction.packetCount)
            }
        }
        if phase == .identified, let identity {
            fields["code"] = String(identity.modelID)
            fields["stage"] = "protocol_" + String(identity.protocolVersion)
        }
        DiagnosticLog.shared.record("label.bluetooth", fields)
    }

    /// Exactly one request is in flight. NIIMBOT frames have no transaction ID;
    /// a timeout tears down the connection so a late reply cannot match a later
    /// request with the same opcode. Commands are never automatically retried.
    private func transfer(command: UInt8, data: Data, response: UInt8?, responseAlternatives: Set<UInt8> = [],
                          beginsPrint: Bool = false,
                          timeout: Duration = .seconds(5)) async throws -> NiimbotPacket? {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw LabelPrinterIssue.notActive }
        guard peripheral?.state == .connected, writeCharacteristic != nil else { throw LabelPrinterIssue.notConnected }
        guard pending == nil else { throw LabelPrinterIssue.printerBusy }
        let bytes = try NiimbotProtocol.encode(command: command, data: data)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: LabelPrinterIssue.cancelled); return }
                // Bitmap rows are one-way UART data. Use the reference's fast
                // write path with CoreBluetooth backpressure; control requests
                // retain acknowledged writes on channels that support them.
                let imageRow = response == nil && [UInt8(0x83), 0x84, 0x85].contains(command)
                let transaction = Transfer(id: id, command: command, bytes: bytes, expectedResponse: response,
                                           responseAlternatives: responseAlternatives, beginsPrint: beginsPrint,
                                           writeType: imageRow ? .withoutResponse : writeType,
                                           continuation: continuation)
                pending = transaction
                if !isConnected { diagnostic(.requestStarted) }
                transaction.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.pending?.id == id else { return }
                    self.connectionFailed(.responseTimeout)
                }
                driveWrite()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pending?.id == id else { return }
                self.endConnection(issue: .cancelled)
            }
        }
    }

    private func driveWrite() {
        guard let transaction = pending, !transaction.awaitingWriteResponse else { return }
        guard UIApplication.shared.applicationState == .active else { connectionFailed(.notActive); return }
        guard let peripheral, peripheral.state == .connected, let writeCharacteristic else {
            connectionFailed(.connectionLost)
            return
        }
        let writeType = transaction.writeType
        let maximumLength = peripheral.maximumWriteValueLength(for: writeType)
        guard maximumLength > 0 else { connectionFailed(.writeFailed); return }
        // CoreBluetooth reports the negotiated payload limit for this write
        // type. No ATT size is assumed; without-response writes additionally
        // observe the peripheral's transmit backpressure.
        let chunkLength = maximumLength

        while transaction.offset < transaction.bytes.count {
            if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                if !isConnected && !transaction.reportedWriteBlocked {
                    transaction.reportedWriteBlocked = true
                    diagnostic(.writeBlocked)
                }
                return
            }
            let end = min(transaction.offset + chunkLength, transaction.bytes.count)
            let chunk = transaction.bytes.subdata(in: transaction.offset..<end)
            transaction.offset = end
            if transaction.beginsPrint { printWasDispatched = true }
            if writeType == .withResponse { transaction.awaitingWriteResponse = true }
            peripheral.writeValue(chunk, for: writeCharacteristic, type: writeType)
            if writeType == .withResponse { return }
        }
        if !isConnected && !transaction.reportedSent {
            transaction.reportedSent = true
            diagnostic(.requestSent)
        }
        finishTransferIfReady()
    }

    private func finishTransferIfReady() {
        guard let transaction = pending, !transaction.awaitingWriteResponse,
              transaction.offset == transaction.bytes.count,
              transaction.expectedResponse == nil || transaction.response != nil else { return }
        pending = nil
        transaction.timeout?.cancel()
        transaction.continuation.resume(returning: transaction.response)
    }

    private func failTransfer(_ issue: LabelPrinterIssue) {
        guard let transaction = pending else { return }
        pending = nil
        transaction.timeout?.cancel()
        transaction.continuation.resume(throwing: issue)
    }

    private func receive(_ bytes: Data) {
        if !isConnected, let transaction = pending {
            transaction.notificationCount = min(1_000_000, transaction.notificationCount + 1)
            transaction.notificationBytes = min(1_000_000, transaction.notificationBytes + bytes.count)
        }
        for packet in parser.append(bytes) {
            if !isConnected, let transaction = pending {
                transaction.packetCount = min(1_000_000, transaction.packetCount + 1)
                transaction.lastResponseCode = packet.command
            }
            if packet.command == 0xdb {
                connectionFailed(NiimbotProtocol.issueForPrintError(packet))
                return
            }
            if packet.command == 0x00 {
                connectionFailed(isConnected ? .unsupportedResponse : .unsupportedPrinter)
                return
            }
            guard let transaction = pending,
                  transaction.offset == transaction.bytes.count,
                  transaction.expectedResponse == packet.command || transaction.responseAlternatives.contains(packet.command),
                  transaction.response == nil else { continue }
            transaction.response = packet
            if !isConnected { diagnostic(.replyReceived) }
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
                self.isConnected = true
                if let id = self.peripheral?.identifier {
                    UserDefaults.standard.set(id.uuidString, forKey: Self.lastPrinterDefaultsKey)
                }
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                self.handshakeTask = nil
                self.status = "\(identity.modelName) connected. Confirm the loaded label size before printing."
                self.diagnostic(.identified)
            } catch {
                guard self.connectionGeneration == generation else { return }
                self.connectionFailed((error as? LabelPrinterIssue) ?? .unsupportedPrinter)
            }
        }
    }

    private func exchange(_ request: NiimbotRequest) async throws -> NiimbotPacket? {
        // The reference's BLE transport spaces complete packets by 10ms. Radio
        // backpressure alone does not bound the UART module's consumer speed.
        try await Task.sleep(for: .milliseconds(10))
        return try await transfer(command: request.command, data: request.data, response: request.response,
                                  responseAlternatives: request.responseAlternatives, beginsPrint: request.beginsPrint)
    }

    private func sendBatch(_ rasters: [LabelRaster], operation: UUID, paperMode: NiimbotPaperMode,
                           beforePage: @escaping @MainActor (Int) async throws -> Void,
                           afterPage: @escaping @MainActor (Int) async throws -> Void) async throws {
        guard let identity else { throw LabelPrinterIssue.unsupportedPrinter }
        let clock = ContinuousClock()
        // Bound each page, not the entire batch: a long, healthy job must not
        // inherit the former single-label 60-second task deadline.
        var deadline = clock.now.advanced(by: .seconds(60))
        var pageStarted = Date()
        recordPrintProgress(.batchStarted, page: 0, total: rasters.count, started: pageStarted)
        try await NiimbotD110Session.printBatch(rasters, identity: identity, paperMode: paperMode) { [weak self] request in
            guard let self else { throw LabelPrinterIssue.connectionLost }
            try self.checkPrintOperation(operation)
            guard clock.now < deadline else { throw LabelPrinterIssue.responseTimeout }
            return try await self.exchange(request)
        } pause: {
            try await Task.sleep(for: .milliseconds(300))
        } onPageWillSend: { [weak self] page in
            guard let self else { throw LabelPrinterIssue.connectionLost }
            try self.checkPrintOperation(operation)
            try await beforePage(page)
            try self.checkPrintOperation(operation)
            deadline = clock.now.advanced(by: .seconds(60))
            pageStarted = Date()
            self.status = "Printing label \(page + 1) of \(rasters.count)…"
            self.recordPrintProgress(.pageStarted, page: page + 1, total: rasters.count, started: pageStarted)
        } onPageCompleted: { [weak self] page in
            guard let self, self.printOperation == operation else { throw LabelPrinterIssue.cancelled }
            // Physical proof must reach durable storage even if Stop arrived
            // with the reply. The next page still passes the foreground gate.
            self.printWasDispatched = false
            try await afterPage(page)
            self.recordPrintProgress(.pageCompleted, page: page + 1, total: rasters.count, started: pageStarted)
        }
    }

    private func recordPrintProgress(_ phase: PrintPhase, page: Int, total: Int, started: Date) {
        let elapsed = Int(max(0, min(3_600_000, Date().timeIntervalSince(started) * 1_000)))
        DiagnosticLog.shared.record("label.print", ["phase": phase.rawValue, "page": String(page),
            "total": String(total), "elapsed_ms": String(elapsed)])
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
        guard error == nil else { connectionFailed(.writeFailed); return }
        transaction.awaitingWriteResponse = false
        driveWrite()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        driveWrite()
    }
}
