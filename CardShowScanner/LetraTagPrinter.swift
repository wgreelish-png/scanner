import Foundation
import Observation
@preconcurrency import CoreBluetooth
import UIKit

struct LetraTagDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Explicit foreground-only BLE connection. Constructing this object never
/// initializes Bluetooth, asks permission, discovers devices or prints.
@MainActor @Observable final class LetraTagPrinter: NSObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = LetraTagPrinter()
    private(set) var status = "Not connected"
    private(set) var isScanning = false
    private(set) var isConnected = false
    private(set) var isPrinting = false
    private(set) var devices: [LetraTagDevice] = []
    private(set) var error: String?
    private(set) var lastPrintSucceeded = false
    private(set) var completedPrintCount = 0

    private enum LinkStage { case idle, connecting, discovering, subscribing, ready }
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var selected: CBPeripheral?
    @ObservationIgnored private var serviceUUID: String?
    @ObservationIgnored private var request: CBCharacteristic?
    @ObservationIgnored private var reply: CBCharacteristic?
    @ObservationIgnored private var stage = LinkStage.idle
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var resumeRequestedScan = false
    @ObservationIgnored private var connectionToken = UUID()
    @ObservationIgnored private var jobToken = UUID()
    @ObservationIgnored private var packets: [Data] = []
    @ObservationIgnored private var packetIndex = 0
    @ObservationIgnored private var awaitingResult = false
    @ObservationIgnored private var printStarted: Date?
    @ObservationIgnored private var scanTimeout: Task<Void, Never>?
    @ObservationIgnored private var connectionTimeout: Task<Void, Never>?
    @ObservationIgnored private var printTimeout: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    func scan() {
        guard UIApplication.shared.applicationState == .active, !isPrinting else { return }
        disconnect()
        peripherals.removeAll(); devices.removeAll(); error = nil
        scanRequested = true
        status = "Checking Bluetooth…"
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else { updateBluetoothState() }
        scanTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.scanRequested else { return }
            self.stopScanning()
            if self.devices.isEmpty { self.status = "No LetraTag found. Turn it on and try again." }
        }
        DiagnosticLog.shared.record("printer.scan", ["phase": "requested", "backend": "native_ble"])
    }

    func stopScanning() {
        scanRequested = false; isScanning = false
        central?.stopScan(); scanTimeout?.cancel(); scanTimeout = nil
        if stage == .idle && !isConnected { status = "Not connected" }
    }

    func connect(deviceID: UUID) {
        guard UIApplication.shared.applicationState == .active, !isPrinting,
              let central, central.state == .poweredOn, let peripheral = peripherals[deviceID] else { return }
        guard selected == nil else {
            if selected?.identifier != deviceID { error = "Disconnect the current printer first." }
            return
        }
        guard peripheral.state == .disconnected else {
            error = "Wait for the previous connection to close, then choose the printer again."
            return
        }
        stopScanning(); error = nil; lastPrintSucceeded = false
        connectionToken = UUID(); let token = connectionToken
        selected = peripheral; peripheral.delegate = self
        stage = .connecting; status = "Connecting…"
        central.connect(peripheral)
        connectionTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.connectionToken == token, !self.isConnected else { return }
            self.fail("The printer connection timed out. Turn the printer on and try again.", reason: "connection_timeout")
        }
        DiagnosticLog.shared.record("printer.connection", ["phase": "requested", "backend": "native_ble"])
    }

    func disconnect() {
        stopScanning()
        resumeRequestedScan = false
        let interrupted = isPrinting
        connectionToken = UUID(); jobToken = UUID()
        connectionTimeout?.cancel(); connectionTimeout = nil
        printTimeout?.cancel(); printTimeout = nil
        writeTask?.cancel(); writeTask = nil
        let old = selected
        selected = nil; request = nil; reply = nil; serviceUUID = nil
        stage = .idle; packets = []; packetIndex = 0; awaitingResult = false
        isConnected = false; isPrinting = false; lastPrintSucceeded = false
        status = "Not connected"
        if let old { central?.cancelPeripheralConnection(old) }
        if interrupted {
            error = "The connection stopped. The print outcome is unknown; check the tape before trying again."
            DiagnosticLog.shared.record("printer.print", ["phase": "unknown", "reason": "interrupted"])
        }
    }

    func stop() { disconnect() }

    /// Stop radio work whenever inactive. Resume only a previously requested
    /// discovery when this screen becomes active again (including permission
    /// alerts); never reconnect or resend an interrupted print automatically.
    func setActive(_ active: Bool) {
        if active {
            let resume = resumeRequestedScan
            resumeRequestedScan = false
            if resume { scan() }
        } else {
            let resume = resumeRequestedScan || scanRequested
            disconnect()
            resumeRequestedScan = resume
        }
    }

    func print(bitmapData: Data) {
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        guard !isPrinting else { return }
        guard isConnected, stage == .ready, let peripheral = selected,
              peripheral.state == .connected, let request, reply?.isNotifying == true else {
            error = "Connect your LetraTag before printing."
            return
        }
        do {
            let writeLimit = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let encoded = try LetraTagProtocol.encode(bitmapData: bitmapData,
                maximumWriteValueLength: writeLimit)
            guard request.properties.contains(.writeWithoutResponse) else {
                fail("This printer does not expose the expected print connection.", reason: "unsupported_write")
                return
            }
            error = nil; lastPrintSucceeded = false; isPrinting = true
            packets = encoded; packetIndex = 0; awaitingResult = false
            printStarted = Date(); jobToken = UUID(); let token = jobToken
            status = "Sending label…"
            printTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, self.isPrinting, self.jobToken == token else { return }
                self.fail("The printer did not confirm completion.", reason: "print_timeout")
            }
            DiagnosticLog.shared.record("printer.print", ["phase": "sending", "records": String(encoded.count),
                "total": String(writeLimit)])
            sendNextPacket()
        } catch { self.error = error.localizedDescription }
    }

    private func sendNextPacket() {
        guard isPrinting, stage == .ready, UIApplication.shared.applicationState == .active,
              let peripheral = selected, peripheral.state == .connected, let request,
              packetIndex < packets.count, writeTask == nil else { return }
        guard peripheral.canSendWriteWithoutResponse else { return }
        peripheral.writeValue(packets[packetIndex], for: request, type: .withoutResponse)
        packetIndex += 1
        if packetIndex == packets.count {
            awaitingResult = true
            status = "Waiting for printer confirmation…"
            DiagnosticLog.shared.record("printer.print", ["phase": "awaiting_reply"])
        } else {
            let token = jobToken
            writeTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                guard let self, self.jobToken == token else { return }
                self.writeTask = nil
                self.sendNextPacket()
            }
        }
    }

    private func updateBluetoothState() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            if scanRequested && UIApplication.shared.applicationState == .active {
                central.scanForPeripherals(withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                isScanning = true; status = "Looking for LetraTag printers…"
            }
        case .unauthorized:
            disconnect()
            status = "Bluetooth access is off"
            error = "Allow Bluetooth access for Card Show Scanner in iPhone Settings."
        case .poweredOff:
            disconnect(); status = "Bluetooth is off"
            error = "Turn on Bluetooth, then search again."
        case .unsupported:
            disconnect(); status = "Bluetooth is unavailable on this device."
        case .resetting:
            disconnect(); status = "Bluetooth restarted. Search for the printer again."
        case .unknown:
            if selected != nil || isPrinting { disconnect() }
            status = "Checking Bluetooth…"
        @unknown default: disconnect(); status = "Bluetooth is unavailable."
        }
    }

    private func fail(_ message: String, reason: String) {
        let uncertain = isPrinting
        disconnect()
        error = uncertain ? message + " Print outcome is unknown; check the tape before retrying." : message
        DiagnosticLog.shared.record("printer.failure", ["phase": uncertain ? "print" : "connection", "reason": reason])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateBluetoothState() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanRequested, isScanning, devices.count < 24 else { return }
        let rawName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let name = rawName.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let lower = name.lowercased()
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard lower.hasPrefix("letratag ") || lower == "letratag" || lower.hasPrefix("dymo lt-200b") ||
              services.contains(where: { LetraTagProtocol.matches(uuidString: $0.uuidString, role: .service) }) else { return }
        guard peripherals[peripheral.identifier] == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        devices.append(.init(id: peripheral.identifier, name: name.isEmpty ? "LetraTag 200B" : String(name.prefix(64))))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard selected === peripheral, stage == .connecting else { return }
        stage = .discovering; status = "Checking printer services…"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard selected === peripheral else { return }
        fail("The printer could not connect. Turn it on and try again.", reason: "connect_failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard selected === peripheral else { return }
        fail("The printer disconnected.", reason: "disconnected")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected === peripheral, stage == .discovering else { return }
        guard error == nil, let services = peripheral.services else {
            fail("Printer services could not be read.", reason: "service_discovery"); return
        }
        let matches = services.filter { LetraTagProtocol.matches(uuidString: $0.uuid.uuidString, role: .service) }
        guard matches.count == 1, let service = matches.first else {
            fail("This device does not expose the expected LetraTag service.", reason: "service_mismatch"); return
        }
        serviceUUID = service.uuid.uuidString
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected === peripheral, stage == .discovering, service.uuid.uuidString == serviceUUID else { return }
        guard error == nil, let characteristics = service.characteristics else {
            fail("Printer characteristics could not be read.", reason: "characteristic_discovery"); return
        }
        let requests = characteristics.filter {
            LetraTagProtocol.matches(uuidString: $0.uuid.uuidString, role: .printRequest, serviceUUID: serviceUUID) &&
                $0.properties.contains(.writeWithoutResponse)
        }
        let replies = characteristics.filter {
            LetraTagProtocol.matches(uuidString: $0.uuid.uuidString, role: .printReply, serviceUUID: serviceUUID) &&
                $0.properties.contains(.notify)
        }
        guard requests.count == 1, replies.count == 1, let tx = requests.first, let rx = replies.first else {
            fail("The expected LetraTag print channels are unavailable.", reason: "characteristic_mismatch"); return
        }
        request = tx; reply = rx; stage = .subscribing; status = "Enabling printer confirmation…"
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral, reply === characteristic else { return }
        if stage == .ready && error == nil && characteristic.isNotifying { return }
        guard stage == .subscribing, error == nil, characteristic.isNotifying else {
            if stage != .idle { fail("Printer confirmation could not be enabled.", reason: "notify_failed") }
            return
        }
        connectionTimeout?.cancel(); connectionTimeout = nil
        stage = .ready; isConnected = true; status = "Connected to LetraTag 200B"
        DiagnosticLog.shared.record("printer.connection", ["phase": "ready", "backend": "native_ble"])
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard selected === peripheral else { return }
        sendNextPacket()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral, reply === characteristic, isPrinting, awaitingResult else { return }
        guard error == nil, let data = characteristic.value,
              let result = LetraTagProtocol.parseStatus(data) else {
            fail("The printer returned an unrecognized reply.", reason: "invalid_reply"); return
        }
        switch result {
        case .success:
            printTimeout?.cancel(); printTimeout = nil
            writeTask?.cancel(); writeTask = nil
            awaitingResult = false; packets = []; packetIndex = 0
            completedPrintCount += 1
            isPrinting = false; lastPrintSucceeded = true
            status = "Printer confirmed label completion"
            var fields = ["phase": "confirmed", "code": "0"]
            if let started = printStarted { fields["elapsed_ms"] = String(Int(max(0, min(3_600_000, Date().timeIntervalSince(started) * 1_000)))) }
            DiagnosticLog.shared.record("printer.print", fields)
        case .unknown(let code):
            DiagnosticLog.shared.record("printer.status", ["phase": "reply", "code": String(code)])
            fail("Printer returned status \(code).", reason: "unverified_status")
        }
    }
}
