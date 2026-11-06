import Foundation

/// Only an explicit Search awaiting its first permission decision may survive
/// the system permission sheet's inactive interval. This carries no connection
/// or print intent, and public stop/close always cancels it.
struct NiimbotPermissionSearchIntent {
    private(set) var awaitingDecision = false

    mutating func request(permissionUndetermined: Bool) {
        awaitingDecision = permissionUndetermined
    }

    func preserveOnInactive(permissionUndetermined: Bool) -> Bool {
        awaitingDecision && permissionUndetermined
    }

    mutating func resumeWhenActive(permissionGranted: Bool, permissionUndetermined: Bool) -> Bool {
        guard awaitingDecision else { return false }
        guard !permissionUndetermined else { return false }
        awaitingDecision = false
        return permissionGranted
    }

    mutating func cancel() { awaitingDecision = false }
}

struct NiimbotPacket: Equatable, Sendable {
    let command: UInt8
    let data: Data
}

/// A bounded decoder for the eight-bit-length NIIMBOT UART protocol. Bluetooth
/// notifications can split a frame anywhere, or contain several complete frames.
struct NiimbotStreamParser {
    static let maximumFrameBytes = 262
    private var buffer: [UInt8] = []
    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ bytes: Data) -> [NiimbotPacket] {
        var packets: [NiimbotPacket] = []
        for byte in bytes {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == 0x55 else { buffer.removeFirst(); continue }
                guard buffer.count > 1 else { break }
                guard buffer[1] == 0x55 else { buffer.removeFirst(); continue }
                guard buffer.count >= 4 else { break }
                let length = Int(buffer[3])
                let frameLength = length + 7
                guard buffer.count >= frameLength else { break }
                let checksum = buffer[2..<(4 + length)].reduce(UInt8(0), ^)
                guard buffer[4 + length] == checksum,
                      buffer[5 + length] == 0xaa, buffer[6 + length] == 0xaa else {
                    buffer.removeFirst()
                    continue
                }
                packets.append(NiimbotPacket(command: buffer[2], data: Data(buffer[4..<(4 + length)])))
                buffer.removeFirst(frameLength)
            }
        }
        return packets
    }
}

struct NiimbotRequest: Equatable, Sendable {
    let command: UInt8
    let data: Data
    let response: UInt8?
    let responseAlternatives: Set<UInt8>
    let beginsPrint: Bool
    let requiresTrue: Bool

    /// Only existing one-way image rows may use the experimental transport.
    /// Any opcode with a reply/checkpoint retains the established write path.
    var allowsExperimentalImageWrite: Bool {
        Self.isImageDataCommand(command) && response == nil && responseAlternatives.isEmpty
            && !requiresTrue && !beginsPrint
    }

    static func isImageDataCommand(_ command: UInt8) -> Bool {
        command == 0x83 || command == 0x84 || command == 0x85
    }

    init(_ command: UInt8, _ data: [UInt8] = [1], response: UInt8? = nil,
         responseAlternatives: Set<UInt8> = [], beginsPrint: Bool = false, requiresTrue: Bool = false) {
        self.command = command
        self.data = Data(data)
        self.response = response
        self.responseAlternatives = responseAlternatives
        self.beginsPrint = beginsPrint
        self.requiresTrue = requiresTrue
    }

    func validateResponse(_ packet: NiimbotPacket?) throws {
        guard let response else { return }
        guard let packet, packet.command == response || responseAlternatives.contains(packet.command) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        // The reference explicitly defines these page/end replies as booleans.
        // Other commands are acknowledged by opcode; their values are not
        // invented here (some settings echo the new value).
        if requiresTrue {
            guard packet.data.count == 1 else { throw LabelPrinterIssue.unsupportedResponse }
            guard packet.data.first == 1 else { throw LabelPrinterIssue.printerNotReady }
        }
    }
}

struct NiimbotD110Identity: Equatable, Sendable {
    let modelID: Int
    let protocolVersion: Int
    let firmwareBytes: Data

    var modelName: String { modelID == 2320 ? "D110-M" : "D110" }
}

/// Selected once before a job can transmit. Unsupported requests use the
/// existing transport from the start; a partial page is never replayed.
struct NiimbotImageTransportSelection: Equatable, Sendable {
    enum Fallback: String, Sendable {
        case none, unsupportedModel = "unsupported_model", unsupportedCharacteristic = "unsupported_characteristic"
        case invalidWriteSize = "invalid_write_size"
    }

    let requested: NiimbotImageTransportConfiguration
    let mode: NiimbotImageTransportMode
    let fallback: Fallback
    let maximumResponseWrite: Int
    let maximumWithoutResponseWrite: Int

    init(requested: NiimbotImageTransportConfiguration, identity: NiimbotD110Identity,
         supportsWithoutResponse: Bool, maximumResponseWrite: Int, maximumWithoutResponseWrite: Int) {
        self.requested = requested
        self.maximumResponseWrite = max(0, maximumResponseWrite)
        self.maximumWithoutResponseWrite = max(0, maximumWithoutResponseWrite)
        if requested.mode == .acknowledged {
            mode = .acknowledged; fallback = .none
        } else if identity.modelID != 2320 || NiimbotProtocol.diagnosticCommandPath(for: identity) == nil {
            mode = .acknowledged; fallback = .unsupportedModel
        } else if !supportsWithoutResponse {
            mode = .acknowledged; fallback = .unsupportedCharacteristic
        } else if maximumWithoutResponseWrite <= 0 {
            mode = .acknowledged; fallback = .invalidWriteSize
        } else {
            mode = .pacedWithoutResponse; fallback = .none
        }
    }

    func usesWithoutResponse(for request: NiimbotRequest) -> Bool {
        mode == .pacedWithoutResponse && request.allowsExperimentalImageWrite
    }

    var diagnosticFields: [String: String] {
        ["transport_requested": requested.mode.rawValue, "transport_selected": mode.rawValue,
         "transport_fallback": fallback.rawValue, "max_write_response_bytes": String(maximumResponseWrite),
         "max_write_without_response_bytes": String(maximumWithoutResponseWrite),
         "image_pacing_ms": String(requested.pacingMilliseconds), "image_burst_writes": String(requested.burstWriteLimit),
         "image_burst_bytes": String(requested.burstByteLimit), "pending_packet_limit": "1",
         "readiness_recheck_ms": String(NiimbotImageReadinessRecheck.intervalMilliseconds),
         "readiness_recheck_limit": String(NiimbotImageReadinessRecheck.maximumChecks)]
    }
}

/// A read-only estimate from a discrete-label RFID counter. It is deliberately
/// not Codable and excludes the tag UID, roll serial and optional second UID.
struct NiimbotRollEstimate: Equatable, Sendable {
    let productCode: String
    let totalLabels: Int
    let usedLabels: Int
    let labelType: UInt8

    var remainingLabels: Int { totalLabels - usedLabels }
}

/// A syntactically valid RFID report. Product identity remains useful when the
/// optional counters are missing or inconsistent. Unique identifiers are never
/// represented here, persisted or passed to the product catalog.
struct NiimbotRollInfo: Equatable, Sendable {
    let productCode: String
    let totalLabels: Int
    let usedLabels: Int
    let labelType: UInt8

    var estimate: NiimbotRollEstimate? {
        guard totalLabels > 0, usedLabels >= 0, usedLabels <= totalLabels,
              labelType == NiimbotPaperMode.gap.commandValue
                || labelType == NiimbotPaperMode.transparent.commandValue else { return nil }
        return NiimbotRollEstimate(productCode: productCode, totalLabels: totalLabels,
                                   usedLabels: usedLabels, labelType: labelType)
    }

    init(productCode: String, totalLabels: Int, usedLabels: Int, labelType: UInt8) {
        self.productCode = productCode; self.totalLabels = totalLabels
        self.usedLabels = usedLabels; self.labelType = labelType
    }

    init(estimate: NiimbotRollEstimate) {
        self.init(productCode: estimate.productCode, totalLabels: estimate.totalLabels,
                  usedLabels: estimate.usedLabels, labelType: estimate.labelType)
    }

    func matchedProduct(in catalog: NiimbotLabelCatalog) -> NiimbotLabelProduct? {
        guard let product = catalog.product(code: productCode), product.paperType == labelType else { return nil }
        return product
    }
}

/// The printer's configured media mode, separate from physical label size.
/// These are the documented SetLabelType values supported by this app.
enum NiimbotPaperMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case gap, transparent
    var id: Self { self }
    var title: String { self == .gap ? "Gap" : "Transparent" }
    var commandValue: UInt8 { self == .gap ? 1 : 5 }
}

enum NiimbotIdentificationStep: String, Sendable {
    case connect = "connect_command"
    case model = "model"
    case protocolVersion = "protocol_version"
    case head = "print_head"
    case firmware = "firmware"
}

struct NiimbotPrintStatus: Equatable, Sendable {
    let completedPages: Int
    let printProgress: Int
    let feedProgress: Int

    var finishedOneLabel: Bool { completedPages == 1 }
}

struct NiimbotPrintBatchRequests: Sendable {
    let initialization: [NiimbotRequest]
    let pages: [[NiimbotRequest]]
    let usesCumulativePageCounter: Bool
}

struct NiimbotPrintGroupRequests: Sendable {
    let indices: Range<Int>
    let requests: [NiimbotRequest]
}

struct NiimbotContinuousPrintRequests: Sendable {
    let initialization: [NiimbotRequest]
    let groups: [NiimbotPrintGroupRequests]
    let usesCumulativePageCounter: Bool
}

/// Error replies describe printer state, not a CoreBluetooth link failure.
/// Keep failures fatal throughout required work. Optional metadata and a
/// positively acknowledged PrintEnd cannot invalidate a completed print job.
enum NiimbotErrorReplyDisposition: Equatable {
    enum Request: Equatable { case none, required, optionalRoll, cleanupHeartbeat }
    case disconnect, rejectOptionalRoll, warnConnected

    static func resolve(verified: Bool, settingUp: Bool, printing: Bool, configuring: Bool,
                        printEndAcknowledged: Bool, request: Request) -> Self {
        guard verified, !settingUp else { return .disconnect }
        if request == .optionalRoll { return .rejectOptionalRoll }
        guard !configuring else { return .disconnect }
        if printing {
            return printEndAcknowledged && (request == .none || request == .cleanupHeartbeat)
                ? .warnConnected : .disconnect
        }
        return request == .none ? .warnConnected : .disconnect
    }
}

/// Aggregate transport work only: no artwork, card text or printer identity.
/// Counts begin when the first ATT chunk is handed to CoreBluetooth, not when
/// a request is merely planned; they do not claim that the radio delivered it.
struct NiimbotPrintTransferMetrics {
    let task: String
    let total: Int
    let identity: NiimbotD110Identity
    let previousJobGap: Duration?
    let transport: NiimbotImageTransportSelection?
    private(set) var groups = 0
    private(set) var nativeCopies = 0
    private(set) var imagePackets = 0
    private(set) var requests = 0
    private(set) var wireBytes = 0
    private(set) var statusPolls = 0
    private(set) var printStarts = 0
    private(set) var printEnds = 0
    private(set) var responseWriteCount = 0
    private(set) var withoutResponseWriteCount = 0
    private(set) var imageResponseBytes = 0
    private(set) var imageWithoutResponseBytes = 0
    private(set) var imageResponseWriteCount = 0
    private(set) var imageWithoutResponseWriteCount = 0
    private(set) var worReadinessRechecks = 0
    private(set) var worReadinessCallbacks = 0
    private(set) var worReadinessBlockedChecks = 0
    private var confirmedPages: Set<Int> = []
    private var timings: [NiimbotPrintTiming: Duration] = [:]
    private struct Command: Hashable { let request: UInt8; let response: UInt8 }
    private struct CommandTiming {
        var count = 0
        var elapsed: Duration = .zero
        var acknowledgement: Duration = .zero
        var reply: Duration = .zero
        var actualResponses: Set<UInt8> = []
    }
    private var commands: [Command: CommandTiming] = [:]

    init(identity: NiimbotD110Identity, continuous: Bool, total: Int, previousJobGap: Duration? = nil,
         transport: NiimbotImageTransportSelection? = nil) {
        task = identity.modelID != 2320 ? "legacy_serial" : continuous ? "buffered_copies" : "declared_serial"
        self.total = total
        self.identity = identity
        self.previousJobGap = previousJobGap
        self.transport = transport
    }

    static func pageCopies(command: UInt8, data: Data) -> Int {
        // Both M page-size variants include quantity at bytes 4–5. Legacy
        // page sizes contain only dimensions and always represent one copy.
        guard command == 0x13, data.count >= 6 else { return 1 }
        return max(1, Int(data[4]) << 8 | Int(data[5]))
    }

    mutating func recordWrite(command: UInt8, response: UInt8?, copies: Int,
                              byteCount: Int, startsRequest: Bool, acknowledged: Bool = true) {
        wireBytes += max(0, byteCount)
        if acknowledged { responseWriteCount += 1 } else { withoutResponseWriteCount += 1 }
        if NiimbotRequest.isImageDataCommand(command) {
            if acknowledged {
                imageResponseBytes += max(0, byteCount); imageResponseWriteCount += 1
            } else {
                imageWithoutResponseBytes += max(0, byteCount); imageWithoutResponseWriteCount += 1
            }
        }
        guard startsRequest else { return }
        requests += 1
        if command == 0x01 { printStarts += 1 }
        if command == 0xf3 { printEnds += 1 }
        if command == 0x13 {
            groups += 1
            // Extra physical copies that reuse an image upload.
            nativeCopies += max(0, copies - 1)
        }
        if command == 0x83 || command == 0x84 || command == 0x85 { imagePackets += 1 }
        // M-v4 also emits a one-way A3 page preamble; it is not a status poll.
        if command == 0xa3 && response == 0xb3 { statusPolls += 1 }
    }

    mutating func add(_ timing: NiimbotPrintTiming, duration: Duration) {
        timings[timing, default: .zero] += max(.zero, duration)
    }

    mutating func recordReadinessCheck(rechecks: Int, blocked: Bool) {
        worReadinessRechecks = min(1_000_000, worReadinessRechecks + min(1_000_000, max(0, rechecks)))
        if blocked { worReadinessBlockedChecks = min(1_000_000, worReadinessBlockedChecks + 1) }
    }

    mutating func recordReadinessCallback() {
        worReadinessCallbacks = min(1_000_000, worReadinessCallbacks + 1)
    }

    mutating func recordRequestSpan(command: UInt8, response: UInt8?, duration: Duration) {
        if NiimbotRequest.isImageDataCommand(command) { add(.imageTransfer, duration: duration) }
        if command == 0x01 { add(.printStart, duration: duration) }
        if command == 0xf3 { add(.printEnd, duration: duration) }
        if command == 0xa3 && response == 0xb3 { add(.statusPoll, duration: duration) }
        if let response {
            let key = Command(request: command, response: response)
            var timing = commands[key] ?? CommandTiming()
            timing.count += 1; timing.elapsed += max(.zero, duration)
            commands[key] = timing
        }
    }

    mutating func recordCommandWait(command: UInt8, response: UInt8?, actualResponse: UInt8?,
                                    acknowledgement: Duration, reply: Duration) {
        guard let response else { return }
        let key = Command(request: command, response: response)
        var timing = commands[key] ?? CommandTiming()
        timing.acknowledgement += max(.zero, acknowledgement)
        timing.reply += max(.zero, reply)
        if let actualResponse { timing.actualResponses.insert(actualResponse) }
        commands[key] = timing
    }

    mutating func recordPhysicalProof(_ pages: [Int]) {
        guard pages.allSatisfy({ (0..<total).contains($0) }) else { return }
        confirmedPages.formUnion(pages)
    }

    var commandDiagnosticFields: [[String: String]] {
        commands.keys.sorted { ($0.request, $0.response) < ($1.request, $1.response) }.map { key in
            let timing = commands[key]!
            var fields = ["request_code": String(key.request), "response_code": String(key.response),
                "request_count": String(timing.count), "elapsed_ms": String(Self.milliseconds(timing.elapsed)),
                "att_ack_wait_ms": String(Self.milliseconds(timing.acknowledgement)),
                "printer_reply_wait_ms": String(Self.milliseconds(timing.reply))]
            if timing.actualResponses.count == 1, let actual = timing.actualResponses.first {
                fields["last_response_code"] = String(actual)
            }
            return fields
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = max(.zero, duration).components
        guard parts.seconds < 3_600 else { return 3_600_000 }
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    func groupFields(since before: Self, elapsed: Duration, pages: Range<Int>, accepted: Bool) -> [String: String] {
        ["page": String(pages.lowerBound + 1), "quantity": String(pages.count), "total": String(total),
         "accepted": String(accepted), "elapsed_ms": String(Self.milliseconds(elapsed)),
         "group_image_packets": String(imagePackets - before.imagePackets),
         "group_requests": String(requests - before.requests), "group_wire_bytes": String(wireBytes - before.wireBytes)]
    }

    func diagnosticFields(elapsedMilliseconds: Int, uncertainLabels: Int = 0) -> [String: String] {
        var fields: [String: String] = ["print_task": task, "total": String(total), "native_groups": String(groups),
         "native_copies": String(nativeCopies), "image_packets": String(imagePackets),
         "request_count": String(requests), "wire_bytes": String(wireBytes),
         "transfer_elapsed_ms": String(max(0, min(3_600_000, elapsedMilliseconds))),
         "status_polls": String(statusPolls), "print_start_count": String(printStarts), "print_end_count": String(printEnds),
         "printer_model": String(identity.modelID), "protocol_version": String(identity.protocolVersion)]
        fields["response_write_count"] = String(responseWriteCount)
        fields["without_response_write_count"] = String(withoutResponseWriteCount)
        fields["image_response_bytes"] = String(imageResponseBytes)
        fields["image_without_response_bytes"] = String(imageWithoutResponseBytes)
        fields["image_response_write_count"] = String(imageResponseWriteCount)
        fields["image_without_response_write_count"] = String(imageWithoutResponseWriteCount)
        fields["wor_readiness_rechecks"] = String(worReadinessRechecks)
        fields["wor_readiness_callbacks"] = String(worReadinessCallbacks)
        fields["wor_readiness_blocked_checks"] = String(worReadinessBlockedChecks)
        fields["expected_labels"] = String(total)
        fields["confirmed_labels"] = String(confirmedPages.count)
        fields["uncertain_labels"] = String(min(max(0, uncertainLabels), max(0, total - confirmedPages.count)))
        if identity.firmwareBytes.count == 2 {
            fields["firmware_byte_0"] = String(identity.firmwareBytes[0])
            fields["firmware_byte_1"] = String(identity.firmwareBytes[1])
        }
        if let transport { fields.merge(transport.diagnosticFields) { _, value in value } }
        fields["command_path"] = NiimbotProtocol.diagnosticCommandPath(for: identity)
        for timing in NiimbotPrintTiming.allCases { fields[timing.rawValue] = String(Self.milliseconds(timings[timing] ?? .zero)) }
        // Time the app explicitly spends querying/waiting for a completion
        // counter. Uploading can overlap the printer's physical feed, so it is
        // deliberately excluded from this accumulated wait measurement.
        fields["page_completion_wait_ms"] = String(Self.milliseconds(
            (timings[.statusPoll] ?? .zero) + (timings[.statusBackoff] ?? .zero)))
        if let previousJobGap { fields["previous_job_gap_ms"] = String(Self.milliseconds(previousJobGap)) }
        return fields
    }
}

enum NiimbotPrintTiming: String, CaseIterable {
    case planEncode = "plan_encode_ms", packetEncode = "packet_encode_ms", packetPacing = "packet_pacing_ms"
    case attAcknowledgement = "att_ack_wait_ms"
    case printerReply = "printer_reply_wait_ms", statusPoll = "status_poll_ms", statusBackoff = "status_backoff_ms"
    case printStart = "print_start_ms", printEnd = "print_end_ms"
    case imageTransfer = "image_transfer_ms", withoutResponseReadiness = "wor_readiness_wait_ms"
    case withoutResponsePacing = "wor_pacing_wait_ms"
}

/// Readiness and configured pacing can block simultaneously. These are
/// independent accumulated waits, not additive parts of job wall time.
struct NiimbotImagePumpWaitTiming {
    private var readinessStarted: ContinuousClock.Instant?
    private var pacingStarted: ContinuousClock.Instant?
    private(set) var readiness: Duration = .zero
    private(set) var pacing: Duration = .zero

    mutating func update(readiness: Bool, pacing: Bool, at now: ContinuousClock.Instant) {
        if readiness {
            if readinessStarted == nil { readinessStarted = now }
        } else if let started = readinessStarted {
            self.readiness += started.duration(to: now); readinessStarted = nil
        }
        if pacing {
            if pacingStarted == nil { pacingStarted = now }
        } else if let started = pacingStarted {
            self.pacing += started.duration(to: now); pacingStarted = nil
        }
    }

    mutating func finish(at now: ContinuousClock.Instant) { update(readiness: false, pacing: false, at: now) }
}

/// ATT write acknowledgements and printer replies can arrive in either order.
/// Only time after the last ATT acknowledgement belongs to reply-only waiting.
struct NiimbotTransferWaitTiming {
    private var acknowledgementStarted: ContinuousClock.Instant?
    private var replyStarted: ContinuousClock.Instant?
    private(set) var acknowledgement: Duration = .zero
    private(set) var reply: Duration = .zero

    mutating func startAcknowledgement(at now: ContinuousClock.Instant) { acknowledgementStarted = now }
    mutating func finishAcknowledgement(at now: ContinuousClock.Instant) {
        if let started = acknowledgementStarted { acknowledgement += started.duration(to: now) }
        acknowledgementStarted = nil
    }
    mutating func startReply(at now: ContinuousClock.Instant) {
        if acknowledgementStarted == nil && replyStarted == nil { replyStarted = now }
    }
    mutating func finishReply(at now: ContinuousClock.Instant) {
        if let started = replyStarted { reply += started.duration(to: now) }
        replyStarted = nil
    }
    mutating func finish(at now: ContinuousClock.Instant) {
        finishAcknowledgement(at: now)
        finishReply(at: now)
    }
}

/// Prepared-group transport progress, independent of physical print receipts.
/// A complete group has validated every exchange through PageEnd acceptance.
struct NiimbotUploadProgress: Equatable, Sendable {
    let pages: Range<Int>
    let completedRequests: Int
    let totalRequests: Int

    var fraction: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(max(0, min(completedRequests, totalRequests))) / Double(totalRequests)
    }
}

/// Keep packet-level progress in memory while bounding observable UI updates.
/// Group boundaries and the final validated exchange always publish promptly.
struct NiimbotUploadProgressThrottle {
    private var pages: Range<Int>?
    private var publishedAt: ContinuousClock.Instant?

    mutating func shouldPublish(_ progress: NiimbotUploadProgress, at now: ContinuousClock.Instant) -> Bool {
        let elapsed = publishedAt.map { $0.duration(to: now) >= .milliseconds(200) } ?? true
        let publish = pages != progress.pages || progress.fraction == 1 || elapsed
        guard publish else { return false }
        pages = progress.pages
        publishedAt = now
        return true
    }

    mutating func reset() { pages = nil; publishedAt = nil }
}

enum NiimbotPrintMeasurement {
    case planEncoded(Duration)
    case groupStarted(Range<Int>)
    case groupProgress(NiimbotUploadProgress)
    case groupSubmitted(Range<Int>, Duration, accepted: Bool)
}

/// Native Swift subset of niimbluelib's documented D110 and D110-M workflows.
/// Model and negotiated protocol choose the task; unknown hardware has no
/// fallback print algorithm.
enum NiimbotProtocol {
    static let maximumBatchPages = 250
    static let maximumContinuousGroupCopies = 8
    static let maximumContinuousGroupsInFlight = 2
    static let serviceUUID = "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"
    static let referenceURL = "https://github.com/MultiMote/niimbluelib"
    static let referenceCommit = "f451be49d8e30046dee0a8f9d14747fe38f303c2"
    static let thirdPartyNotice = """
    NIIMBOT protocol reference: niimbluelib
    https://github.com/MultiMote/niimbluelib
    Reference commit: f451be49d8e30046dee0a8f9d14747fe38f303c2

    MIT License

    Copyright (c) 2024 MultiMote

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    static func isD110Advertisement(_ name: String) -> Bool {
        let value = name.uppercased()
        guard value.hasPrefix("D110") else { return false }
        let suffix = value.dropFirst(4)
        guard let first = suffix.first else { return true }
        let separators: Set<Character> = ["_", "-", " "]
        // Both naming families are discoverable. Advertising is only a filter;
        // the model/head/protocol handshake remains authoritative.
        if first == "M" {
            let remainder = suffix.dropFirst()
            return remainder.isEmpty || remainder.first.map { separators.contains($0) } == true
        }
        return separators.contains(first)
    }

    static func encode(command: UInt8, data: Data) throws -> Data {
        guard data.count <= 255 else { throw LabelPrinterIssue.invalidLabel }
        var result = Data([0x55, 0x55, command, UInt8(data.count)])
        result.append(data)
        result.append(data.reduce(command ^ UInt8(data.count), ^))
        result.append(contentsOf: [0xaa, 0xaa])
        // Connect is the only command with this leading wake-up byte.
        if command == 0xc1 { result.insert(0x03, at: result.startIndex) }
        return result
    }

    /// The reference uses an eight-byte UID, signed-byte-length ASCII strings,
    /// big-endian counters and an optional two-byte capacity/eight-byte UID tail.
    /// Invalid counters do not erase a structurally valid product identity.
    static func rollInfo(_ packet: NiimbotPacket) throws -> NiimbotRollInfo? {
        guard packet.command == 0x1b, packet.data.count <= 255 else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        // The documented one-byte response means that no tag was read; its
        // byte is not a count and must never appear as zero remaining labels.
        if packet.data.count == 1 { return nil }
        guard packet.data.count >= 17 else { throw LabelPrinterIssue.unsupportedResponse }
        let bytes = Array(packet.data)
        var offset = 8 // Skip the unique tag identifier without retaining it.
        func readASCII() throws -> String {
            guard offset < bytes.count else { throw LabelPrinterIssue.unsupportedResponse }
            let length = Int(bytes[offset])
            offset += 1
            guard (1...127).contains(length), length <= bytes.count - offset else {
                throw LabelPrinterIssue.unsupportedResponse
            }
            let end = offset + length
            let value = bytes[offset..<end]
            guard value.allSatisfy({ (0x20...0x7e).contains($0) }),
                  let text = String(bytes: value, encoding: .ascii) else {
                throw LabelPrinterIssue.unsupportedResponse
            }
            offset = end
            return text
        }
        func readU16() throws -> Int {
            guard bytes.count - offset >= 2 else { throw LabelPrinterIssue.unsupportedResponse }
            let value = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            return value
        }
        let productCode = try readASCII()
        _ = try readASCII() // Validate and discard the unique roll serial.
        let total = try readU16(), used = try readU16()
        guard offset < bytes.count else { throw LabelPrinterIssue.unsupportedResponse }
        let type = bytes[offset]
        offset += 1
        switch bytes.count - offset {
        case 0: break
        case 2:
            _ = try readU16() // Capacity is not the remaining-label counter.
        case 10:
            _ = try readU16()
            offset += 8 // Discard the optional unique identifier.
        default:
            throw LabelPrinterIssue.unsupportedResponse
        }
        guard offset == bytes.count else { throw LabelPrinterIssue.unsupportedResponse }
        return NiimbotRollInfo(productCode: productCode, totalLabels: total, usedLabels: used, labelType: type)
    }

    /// Preserve the existing strict counter API. Unknown counters are never
    /// converted into zero; metadata callers use rollInfo independently.
    static func rollEstimate(_ packet: NiimbotPacket) throws -> NiimbotRollEstimate? {
        guard let info = try rollInfo(packet) else { return nil }
        guard let estimate = info.estimate else { throw LabelPrinterIssue.unsupportedResponse }
        return estimate
    }

    static func modelID(_ packet: NiimbotPacket) throws -> Int {
        guard packet.command == 0x48, (1...2).contains(packet.data.count) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        let bytes = Array(packet.data)
        return Int(bytes[0]) << 8 | (bytes.count == 2 ? Int(bytes[1]) : 0)
    }

    static func negotiatedVersion(connect: NiimbotPacket, status: NiimbotPacket? = nil) throws -> Int {
        guard connect.command == 0xc2, connect.data.count == 1 else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        switch connect.data.first {
        case 1: return 0
        case 2: return 1
        case 3:
            guard let status, status.command == 0xb5, status.data.count >= 13 else {
                throw LabelPrinterIssue.unsupportedResponse
            }
            let bytes = Array(status.data)
            let generation = Int(bytes[11]) * 100 + Int(bytes[12])
            switch generation {
            case 204..<300: return 3
            case 300..<302: return 4
            case 302..<400: return 5
            default: throw LabelPrinterIssue.unsupportedPrinter
            }
        default: throw LabelPrinterIssue.unsupportedPrinter
        }
    }

    /// ID 2305 is shared with a 120-dot HI_D110 in the reference model table.
    /// Both that ID and the M model require a reported 96-dot 203-dpi head.
    static func validateModel(_ model: Int, headInfo: NiimbotPacket? = nil) throws {
        if model == 2304 { return }
        guard [2305, 2320].contains(model), let headInfo,
              [UInt8(0xdf), 0xde].contains(headInfo.command), headInfo.data.count == 10 else {
            throw LabelPrinterIssue.unsupportedPrinter
        }
        let bytes = Array(headInfo.data)
        guard (Int(bytes[4]) << 8 | Int(bytes[5])) == 96, bytes[6] == 2 else {
            throw LabelPrinterIssue.unsupportedPrinter
        }
        // D110-M reports its firmware in this documented head heartbeat rather
        // than requiring the older standalone firmware-info request.
        if model == 2320, bytes[2] == 0 && bytes[3] == 0 { throw LabelPrinterIssue.unsupportedPrinter }
    }

    private enum PrintTask { case d110, b1, d110MV4 }

    private static func printTask(for identity: NiimbotD110Identity?) throws -> PrintTask {
        guard let identity else { return .d110 }
        guard [2304, 2305, 2320].contains(identity.modelID),
              [0, 1, 3, 4, 5].contains(identity.protocolVersion),
              identity.firmwareBytes.count == 2, identity.firmwareBytes.contains(where: { $0 != 0 }) else {
            throw LabelPrinterIssue.unsupportedPrinter
        }
        guard identity.modelID == 2320 else { return .d110 }
        // The pinned task table gives the version-4 match priority over the
        // general D110_M → B1 mapping. Do not apply the v4 task to v5 by guess.
        return identity.protocolVersion == 4 ? .d110MV4 : .b1
    }

    static func diagnosticCommandPath(for identity: NiimbotD110Identity) -> String? {
        guard let task = try? printTask(for: identity) else { return nil }
        switch task {
        case .d110: return "d110"
        case .b1: return "d110m_b1"
        case .d110MV4: return "d110m_v4"
        }
    }

    static func validateReadiness(_ packet: NiimbotPacket, identity: NiimbotD110Identity) throws {
        let bytes = Array(packet.data)
        if packet.command == 0xdd {
            let lidIndex: Int
            let paperIndex: Int?
            switch bytes.count {
            case 10: lidIndex = 8; paperIndex = nil
            case 13: lidIndex = 9; paperIndex = 11
            case 19: lidIndex = 15; paperIndex = 17
            default: throw LabelPrinterIssue.unsupportedResponse
            }
            guard bytes[lidIndex] <= 1 else { throw LabelPrinterIssue.unsupportedResponse }
            let lidClosed = identity.modelID == 2304 ? bytes[lidIndex] != 0 : bytes[lidIndex] == 0
            guard lidClosed else { throw LabelPrinterIssue.printerNotReady }
            if let paperIndex, bytes[paperIndex] != 0 { throw LabelPrinterIssue.printerNotReady }
        } else if packet.command == 0xd9 {
            guard [9, 11, 13, 14].contains(bytes.count) else { throw LabelPrinterIssue.unsupportedResponse }
            guard bytes[4] == 0, bytes[5] == 0 else { throw LabelPrinterIssue.printerNotReady }
        } else {
            throw LabelPrinterIssue.unsupportedResponse
        }
    }

    static func issueForPrintError(_ packet: NiimbotPacket) -> LabelPrinterIssue {
        guard packet.command == 0xdb, packet.data.count == 1, let code = packet.data.first else { return .unsupportedResponse }
        switch code {
        case 0x05: return .cancelled
        case 0x09: return .printerBusy
        case 0x10, 0x11: return .paperMismatch
        case 0x17: return .connectionLost
        default: return .printerNotReady
        }
    }

    static func printStatus(_ packet: NiimbotPacket, maximumPages: Int = 1) throws -> NiimbotPrintStatus {
        guard (1...maximumBatchPages).contains(maximumPages),
              packet.command == 0xb3, [4, 8, 10].contains(packet.data.count) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        let bytes = Array(packet.data)
        if bytes.count == 10, bytes[6] != 0 {
            throw issueForPrintError(NiimbotPacket(command: 0xdb, data: Data([bytes[6]])))
        }
        let page = Int(bytes[0]) << 8 | Int(bytes[1])
        guard page <= maximumPages, bytes[2] <= 100, bytes[3] <= 100 else { throw LabelPrinterIssue.unsupportedResponse }
        return NiimbotPrintStatus(completedPages: page, printProgress: Int(bytes[2]), feedProgress: Int(bytes[3]))
    }

    /// Stock height is feed direction; LabelRaster is already in head direction,
    /// MSB first. No second rotation or image re-render is performed here.
    static func printRequests(for raster: LabelRaster, identity: NiimbotD110Identity? = nil,
                              paperMode: NiimbotPaperMode = .gap) throws -> [NiimbotRequest] {
        try validateRaster(raster)
        let task = try printTask(for: identity)
        return initializationRequests(task: task, totalPages: 1, paperMode: paperMode)
            + pageRequests(for: raster, task: task, beginsPrint: false)
    }

    /// M tasks declare the complete count once, keeping intermediate pages at
    /// the head instead of ending and feeding a separate task for every label.
    /// The older D110 task has no declared-count start, so retain its established
    /// complete one-label workflow instead of inventing new legacy commands.
    static func batchRequests(for rasters: [LabelRaster], identity: NiimbotD110Identity,
                              paperMode: NiimbotPaperMode = .gap) throws -> NiimbotPrintBatchRequests {
        guard (1...maximumBatchPages).contains(rasters.count) else { throw LabelPrinterIssue.invalidLabel }
        let task = try printTask(for: identity)
        try rasters.forEach { try validateRaster($0) }
        switch task {
        case .d110:
            return NiimbotPrintBatchRequests(initialization: [], pages: try rasters.map {
                try printRequests(for: $0, identity: identity, paperMode: paperMode)
            }, usesCumulativePageCounter: false)
        case .b1, .d110MV4:
            return NiimbotPrintBatchRequests(
                initialization: initializationRequests(task: task, totalPages: rasters.count, paperMode: paperMode),
                pages: rasters.map { pageRequests(for: $0, task: task, beginsPrint: true) },
                usesCumulativePageCounter: true)
        }
    }

    /// A bounded native-copy group uploads an identical image only once. Only
    /// adjacent equal snapshots are grouped, so physical output keeps queue
    /// order and never changes the prepared artwork or selected label count.
    static func continuousRequests(for rasters: [LabelRaster], identity: NiimbotD110Identity,
                                   paperMode: NiimbotPaperMode = .gap) throws -> NiimbotContinuousPrintRequests {
        guard (1...maximumBatchPages).contains(rasters.count) else { throw LabelPrinterIssue.invalidLabel }
        let task = try printTask(for: identity)
        try rasters.forEach { try validateRaster($0) }
        if case .d110 = task {
            return NiimbotContinuousPrintRequests(initialization: [], groups: [], usesCumulativePageCounter: false)
        }
        var groups: [NiimbotPrintGroupRequests] = []
        var start = 0
        while start < rasters.count {
            var end = start + 1
            while end < rasters.count, end - start < maximumContinuousGroupCopies,
                  rasters[end] == rasters[start] { end += 1 }
            groups.append(NiimbotPrintGroupRequests(indices: start..<end,
                requests: pageRequests(for: rasters[start], task: task, beginsPrint: true, quantity: end - start)))
            start = end
        }
        return NiimbotContinuousPrintRequests(
            initialization: initializationRequests(task: task, totalPages: rasters.count, paperMode: paperMode),
            groups: groups, usesCumulativePageCounter: true)
    }

    private static func validateRaster(_ raster: LabelRaster) throws {
        do { try raster.validate() } catch { throw LabelPrinterIssue.invalidLabel }
    }

    private static func initializationRequests(task: PrintTask, totalPages: Int,
                                               paperMode: NiimbotPaperMode) -> [NiimbotRequest] {
        switch task {
        case .d110:
            // Preserve the established standard-D110 bytes and ordering.
            return [
                NiimbotRequest(0x21, [2], response: 0x31),
                NiimbotRequest(0x23, [paperMode.commandValue], response: 0x33),
                NiimbotRequest(0x01, response: 0x02, beginsPrint: true)
            ]
        case .b1:
            return [
                NiimbotRequest(0x21, [3], response: 0x31),
                NiimbotRequest(0x23, [paperMode.commandValue], response: 0x33),
                NiimbotRequest(0x01, u16(totalPages) + [0, 0, 0, 0, 0], response: 0x02, beginsPrint: true)
            ]
        case .d110MV4:
            return [
                NiimbotRequest(0x23, [paperMode.commandValue], response: 0x33),
                NiimbotRequest(0x21, [3], response: 0x31),
                NiimbotRequest(0x01, u16(totalPages) + [0, 0, 0, 0, 0, 1, 0], response: 0x02, beginsPrint: true)
            ]
        }
    }

    private static func pageRequests(for raster: LabelRaster, task: PrintTask,
                                     beginsPrint: Bool, quantity: Int = 1) -> [NiimbotRequest] {
        var requests: [NiimbotRequest]
        switch task {
        case .d110:
            requests = [
                NiimbotRequest(0x20, response: 0x30),
                NiimbotRequest(0x03, response: 0x04, beginsPrint: beginsPrint, requiresTrue: true),
                NiimbotRequest(0x13, u16(raster.height) + u16(raster.width), response: 0x14),
                NiimbotRequest(0x15, [0, 1], response: 0x16)
            ]
        case .b1:
            requests = [
                NiimbotRequest(0x03, response: 0x04, beginsPrint: beginsPrint, requiresTrue: true),
                NiimbotRequest(0x13, u16(raster.height) + u16(raster.width) + u16(quantity), response: 0x14)
            ]
        case .d110MV4:
            requests = [
                // The v4 task deliberately does not wait for this status reply.
                NiimbotRequest(0xa3),
                NiimbotRequest(0x13, u16(raster.height) + u16(raster.width) + u16(quantity) + [0, 0, 0, 0, 0, 0, 0],
                               response: 0x14, beginsPrint: beginsPrint)
            ]
        }
        let bytes = Array(raster.data)
        var row = 0
        while row < raster.height {
            let rowData = Array(bytes[(row * 12)..<(row * 12 + 12)])
            var repeats = 1
            while repeats < 255, row + repeats < raster.height,
                  // The reference encoder ends its compression run every 200
                  // rows, even when optional CheckLine packets are disabled.
                  (row + repeats) % 200 != 0,
                  Array(bytes[((row + repeats) * 12)..<((row + repeats + 1) * 12)]) == rowData {
                repeats += 1
            }
            let counts: [UInt8] = (0..<3).map { part in
                UInt8(rowData[(part * 4)..<(part * 4 + 4)].reduce(0) { $0 + $1.nonzeroBitCount })
            }
            let blackCount = counts.reduce(0) { $0 + Int($1) }
            let position = u16(row)
            if blackCount == 0 {
                requests.append(NiimbotRequest(0x84, position + [UInt8(repeats)]))
            } else if blackCount <= 6 {
                var indexes: [UInt8] = []
                for index in 0..<96 where rowData[index / 8] & (1 << (7 - index % 8)) != 0 {
                    indexes.append(contentsOf: u16(index))
                }
                requests.append(NiimbotRequest(0x83, position + counts + [UInt8(repeats)] + indexes))
            } else {
                requests.append(NiimbotRequest(0x85, position + counts + [UInt8(repeats)] + rowData))
            }
            row += repeats
        }
        requests.append(NiimbotRequest(0xe3, response: 0xe4, requiresTrue: true))
        return requests
    }

    private static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}

/// The handshake and workflow are independent of CoreBluetooth so deterministic
/// tests can exercise native requests, responses and completion without a radio.
@MainActor enum NiimbotD110Session {
    typealias Exchange = @MainActor (NiimbotRequest) async throws -> NiimbotPacket?
    typealias Measurement = @MainActor (NiimbotPrintMeasurement) -> Void

    private static func measuredPlan<T>(_ observe: Measurement, build: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        let started = clock.now
        defer { observe(.planEncoded(started.duration(to: clock.now))) }
        return try build()
    }

    private static func sendGroup(_ requests: [NiimbotRequest], indices: Range<Int>,
                                  exchange: Exchange, observe: Measurement) async throws {
        observe(.groupStarted(indices))
        observe(.groupProgress(NiimbotUploadProgress(pages: indices, completedRequests: 0, totalRequests: requests.count)))
        let clock = ContinuousClock()
        let started = clock.now
        var accepted = false
        defer { observe(.groupSubmitted(indices, started.duration(to: clock.now), accepted: accepted)) }
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            try request.validateResponse(try await exchange(request))
            observe(.groupProgress(NiimbotUploadProgress(pages: indices, completedRequests: index + 1,
                                                       totalRequests: requests.count)))
        }
        accepted = true
    }

    /// One optional read, with no retry, calibration, feed or setting command.
    static func readRollEstimate(exchange: Exchange) async throws -> NiimbotRollEstimate? {
        try Task.checkCancellation()
        guard let packet = try await exchange(NiimbotRequest(0x1a, [1], response: 0x1b)) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        return try NiimbotProtocol.rollEstimate(packet)
    }

    /// Read identity and counters together without requiring valid counters
    /// for offline product detection. This sends the same single RFID request.
    static func readRollInfo(exchange: Exchange) async throws -> NiimbotRollInfo? {
        try Task.checkCancellation()
        guard let packet = try await exchange(NiimbotRequest(0x1a, [1], response: 0x1b)) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        return try NiimbotProtocol.rollInfo(packet)
    }

    /// Read the configured label-type property. This does not establish which
    /// roll is physically loaded, and it does not change printer settings.
    static func readPaperMode(exchange: Exchange) async throws -> NiimbotPaperMode {
        let request = NiimbotRequest(0x40, [3], response: 0x43)
        guard let packet = try await exchange(request), packet.command == 0x43,
              packet.data.count == 1, let value = packet.data.first,
              let mode = NiimbotPaperMode.allCases.first(where: { $0.commandValue == value }) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        return mode
    }

    /// SetLabelType acknowledges by opcode; replies may echo Transparent's 5
    /// rather than a boolean 1. No undocumented calibration/feed command runs.
    static func applyPaperMode(_ mode: NiimbotPaperMode, exchange: Exchange) async throws {
        let request = NiimbotRequest(0x23, [mode.commandValue], response: 0x33)
        try request.validateResponse(try await exchange(request))
    }

    static func identify(onStep: @MainActor (NiimbotIdentificationStep) -> Void = { _ in },
                         exchange: Exchange) async throws -> NiimbotD110Identity {
        try Task.checkCancellation()
        onStep(.connect)
        guard let connect = try await exchange(NiimbotRequest(0xc1, response: 0xc2)) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        // Validate the connect result before sending further commands.
        guard connect.command == 0xc2, connect.data.count == 1,
              [UInt8(1), 2, 3].contains(connect.data.first ?? 0) else { throw LabelPrinterIssue.unsupportedPrinter }
        // The captured NIIMBOT D110-M exchange asks for model immediately after
        // Connect, then negotiates the newer protocol before requesting head info.
        try Task.checkCancellation()
        onStep(.model)
        guard let modelPacket = try await exchange(NiimbotRequest(0x40, [8], response: 0x48)) else {
            throw LabelPrinterIssue.unsupportedResponse
        }
        let model = try NiimbotProtocol.modelID(modelPacket)
        var status: NiimbotPacket?
        if connect.data.first == 3 {
            try Task.checkCancellation()
            onStep(.protocolVersion)
            status = try await exchange(NiimbotRequest(0xa5, response: 0xb5))
        }
        let version = try NiimbotProtocol.negotiatedVersion(connect: connect, status: status)
        var headInfo: NiimbotPacket?
        if model == 2305 || model == 2320 {
            try Task.checkCancellation()
            onStep(.head)
            headInfo = try await exchange(NiimbotRequest(0xdc, [3], response: 0xdf, responseAlternatives: [0xde]))
        }
        try Task.checkCancellation()
        try NiimbotProtocol.validateModel(model, headInfo: headInfo)
        if model == 2320, let headInfo {
            return NiimbotD110Identity(modelID: model, protocolVersion: version,
                firmwareBytes: Data(headInfo.data.dropFirst(2).prefix(2)))
        }
        try Task.checkCancellation()
        onStep(.firmware)
        guard let firmware = try await exchange(NiimbotRequest(0x40, [9], response: 0x49)),
              firmware.command == 0x49, firmware.data.count == 2,
              firmware.data.contains(where: { $0 != 0 }) else { throw LabelPrinterIssue.unsupportedPrinter }
        try Task.checkCancellation()
        return NiimbotD110Identity(modelID: model, protocolVersion: version, firmwareBytes: firmware.data)
    }

    static func printLabel(_ raster: LabelRaster, identity: NiimbotD110Identity,
                           paperMode: NiimbotPaperMode = .gap,
                           exchange: Exchange, pause: @MainActor () async throws -> Void,
                           onMeasurement: Measurement = { _ in }) async throws {
        // Validate the entire raster before sending the first print command.
        let requests = try measuredPlan(onMeasurement) {
            try NiimbotProtocol.printRequests(for: raster, identity: identity, paperMode: paperMode)
        }
        try await printPreparedLabel(requests, index: 0, identity: identity, exchange: exchange,
                                     pause: pause, onMeasurement: onMeasurement)
    }

    private static func printPreparedLabel(_ requests: [NiimbotRequest], index: Int, identity: NiimbotD110Identity,
                                          exchange: Exchange, pause: @MainActor () async throws -> Void,
                                          onMeasurement: Measurement) async throws {
        let advanced = identity.protocolVersion >= 3
        let readiness = NiimbotRequest(0xdc, [advanced ? 4 : 1], response: advanced ? 0xd9 : 0xdd,
                                      responseAlternatives: [0xdd, 0xd9])
        guard let reply = try await exchange(readiness) else { throw LabelPrinterIssue.unsupportedResponse }
        try NiimbotProtocol.validateReadiness(reply, identity: identity)
        try await sendGroup(requests, indices: index..<(index + 1), exchange: exchange, observe: onMeasurement)
        // PageEnd only acknowledges receipt. The printer's completed-page
        // counter is the D110 reference's completion condition, polled at 300ms.
        // Bound total polling as well as each individual BLE request timeout.
        for _ in 0..<100 {
            try await pause()
            guard let packet = try await exchange(NiimbotRequest(0xa3, response: 0xb3)) else {
                throw LabelPrinterIssue.unsupportedResponse
            }
            if try NiimbotProtocol.printStatus(packet).finishedOneLabel {
                let end = NiimbotRequest(0xf3, response: 0xf4, requiresTrue: true)
                try end.validateResponse(try await exchange(end))
                if identity.modelID == 2320 && identity.protocolVersion == 4 {
                    // The reference v4 task follows PrintEnd with a one-way
                    // Advanced1 heartbeat; it does not start another print.
                    _ = try await exchange(NiimbotRequest(0xdc, [1]))
                }
                return
            }
        }
        throw LabelPrinterIssue.responseTimeout
    }

    /// A page is journaled before any of its print bytes and confirmed only by
    /// the physical completed-page counter. Await each confirmation's durable
    /// callback before sending the next page: a disconnect can then leave at
    /// most one uncertain copy, and no future page is silently replayed.
    ///
    /// M profiles keep one declared-count print task open throughout the batch.
    /// Counter gating adds only the status cadence; there is no intermediate
    /// PrintEnd, setup cycle or final-label feed between those pages.
    static func printBatch(_ rasters: [LabelRaster], identity: NiimbotD110Identity,
                           paperMode: NiimbotPaperMode = .gap,
                           exchange: Exchange, pause: @MainActor () async throws -> Void,
                           onPageWillSend: @MainActor (Int) async throws -> Void = { _ in },
                           onPageCompleted: @MainActor (Int) async throws -> Void = { _ in },
                           onMeasurement: Measurement = { _ in }) async throws {
        // Every page and the negotiated profile must validate before touching
        // the radio, including a bad later page in an otherwise valid batch.
        let batch = try measuredPlan(onMeasurement) {
            try NiimbotProtocol.batchRequests(for: rasters, identity: identity, paperMode: paperMode)
        }
        try Task.checkCancellation()
        guard batch.usesCumulativePageCounter else {
            // Legacy D110 has a one-byte PrintStart without a declared count.
            // Preserve the already supported one-label algorithm per copy.
            for (index, requests) in batch.pages.enumerated() {
                try Task.checkCancellation()
                try await onPageWillSend(index)
                try Task.checkCancellation()
                try await printPreparedLabel(requests, index: index, identity: identity,
                                            exchange: exchange, pause: pause, onMeasurement: onMeasurement)
                try await onPageCompleted(index)
            }
            return
        }

        let advanced = identity.protocolVersion >= 3
        let readiness = NiimbotRequest(0xdc, [advanced ? 4 : 1], response: advanced ? 0xd9 : 0xdd,
                                      responseAlternatives: [0xdd, 0xd9])
        guard let reply = try await exchange(readiness) else { throw LabelPrinterIssue.unsupportedResponse }
        try NiimbotProtocol.validateReadiness(reply, identity: identity)
        try Task.checkCancellation()
        // PrintStart itself can actuate the printer. The first write-ahead
        // callback therefore precedes initialization as well as page zero.
        try await onPageWillSend(0)
        for request in batch.initialization {
            try Task.checkCancellation()
            try request.validateResponse(try await exchange(request))
        }

        for (index, requests) in batch.pages.enumerated() {
            if index > 0 {
                try Task.checkCancellation()
                try await onPageWillSend(index)
            }
            try await sendGroup(requests, indices: index..<(index + 1), exchange: exchange, observe: onMeasurement)

            var completed = false
            for _ in 0..<100 {
                try Task.checkCancellation()
                try await pause()
                try Task.checkCancellation()
                guard let packet = try await exchange(NiimbotRequest(0xa3, response: 0xb3)) else {
                    throw LabelPrinterIssue.unsupportedResponse
                }
                let status = try NiimbotProtocol.printStatus(packet, maximumPages: rasters.count)
                // Only one new page has been sent since the last proof. A
                // regressed or advanced counter cannot confirm this queue copy.
                guard (index...(index + 1)).contains(status.completedPages) else {
                    throw LabelPrinterIssue.unsupportedResponse
                }
                if status.completedPages == index + 1 {
                    // Persist known physical completion even if cancellation
                    // arrives just after receiving this counter response.
                    try await onPageCompleted(index)
                    completed = true
                    break
                }
            }
            guard completed else { throw LabelPrinterIssue.responseTimeout }
        }

        try Task.checkCancellation()
        let end = NiimbotRequest(0xf3, response: 0xf4, requiresTrue: true)
        try end.validateResponse(try await exchange(end))
        if identity.protocolVersion == 4 {
            // Same one-way cleanup heartbeat as the pinned M-v4 task.
            _ = try await exchange(NiimbotRequest(0xdc, [1]))
        }
    }

    /// Keep two native-copy groups supplied to supported M printers instead of
    /// pausing for each physical label. Every submitted copy is journaled first;
    /// a stop can leave at most two groups of eight copies awaiting inspection.
    /// Physical counter receipts may cover part of a group or several groups,
    /// and must persist successfully before another group can enter the window.
    static func printContinuously(_ rasters: [LabelRaster], identity: NiimbotD110Identity,
                                  paperMode: NiimbotPaperMode = .gap,
                                  exchange: Exchange, pause: @MainActor () async throws -> Void,
                                  onPagesWillSend: @MainActor ([Int]) async throws -> Void,
                                  onPagesCompleted: @MainActor ([Int]) async throws -> Void,
                                  onMeasurement: Measurement = { _ in }) async throws {
        let plan = try measuredPlan(onMeasurement) {
            try NiimbotProtocol.continuousRequests(for: rasters, identity: identity, paperMode: paperMode)
        }
        try Task.checkCancellation()
        guard plan.usesCumulativePageCounter else {
            // No new legacy-D110 commands or buffering assumptions are added.
            try await printBatch(rasters, identity: identity, paperMode: paperMode, exchange: exchange, pause: pause,
                onPageWillSend: { try await onPagesWillSend([$0]) },
                onPageCompleted: { try await onPagesCompleted([$0]) }, onMeasurement: onMeasurement)
            return
        }

        let advanced = identity.protocolVersion >= 3
        let readiness = NiimbotRequest(0xdc, [advanced ? 4 : 1], response: advanced ? 0xd9 : 0xdd,
                                      responseAlternatives: [0xdd, 0xd9])
        guard let reply = try await exchange(readiness) else { throw LabelPrinterIssue.unsupportedResponse }
        try NiimbotProtocol.validateReadiness(reply, identity: identity)

        var initialized = false
        var nextGroup = 0
        var inFlight: [Range<Int>] = []
        var submittedPages = 0
        var confirmedPages = 0
        var pollsWithoutProgress = 0
        while confirmedPages < rasters.count {
            while nextGroup < plan.groups.count,
                  inFlight.count < NiimbotProtocol.maximumContinuousGroupsInFlight {
                try Task.checkCancellation()
                let group = plan.groups[nextGroup]
                // The first group's complete copy set precedes PrintStart;
                // later groups precede even the v4 one-way status preamble.
                try await onPagesWillSend(Array(group.indices))
                if !initialized {
                    for request in plan.initialization {
                        try Task.checkCancellation()
                        try request.validateResponse(try await exchange(request))
                    }
                    initialized = true
                }
                try await sendGroup(group.requests, indices: group.indices, exchange: exchange, observe: onMeasurement)
                submittedPages = group.indices.upperBound
                inFlight.append(group.indices)
                nextGroup += 1
            }

            try Task.checkCancellation()
            guard let packet = try await exchange(NiimbotRequest(0xa3, response: 0xb3)) else {
                throw LabelPrinterIssue.unsupportedResponse
            }
            let status = try NiimbotProtocol.printStatus(packet, maximumPages: rasters.count)
            guard (confirmedPages...submittedPages).contains(status.completedPages) else {
                throw LabelPrinterIssue.unsupportedResponse
            }
            if status.completedPages > confirmedPages {
                // Do not check cancellation between receiving physical proof
                // and forwarding all newly confirmed copies to durable storage.
                try await onPagesCompleted(Array(confirmedPages..<status.completedPages))
                confirmedPages = status.completedPages
                pollsWithoutProgress = 0
                inFlight.removeAll { $0.upperBound <= confirmedPages }
                // Refill the freed window immediately, before another pause.
            } else {
                pollsWithoutProgress += 1
                guard pollsWithoutProgress < 100 else { throw LabelPrinterIssue.responseTimeout }
                // Uploading the window may already have taken longer than a
                // label needs to print. Poll immediately after a refill and
                // wait only when the physical counter still reports busy.
                try await pause()
                try Task.checkCancellation()
            }
        }

        try Task.checkCancellation()
        let end = NiimbotRequest(0xf3, response: 0xf4, requiresTrue: true)
        try end.validateResponse(try await exchange(end))
        if identity.protocolVersion == 4 { _ = try await exchange(NiimbotRequest(0xdc, [1])) }
    }
}
