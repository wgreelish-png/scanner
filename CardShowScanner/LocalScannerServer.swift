import Foundation
import Network

enum LocalScannerListenerState: Sendable {
    case ready, waiting, failed(NWError), cancelled
}

@MainActor protocol LocalScannerListening: AnyObject {
    func start(onState: @escaping @MainActor (LocalScannerListenerState) -> Void,
               onConnection: @escaping @MainActor (NWConnection) -> Void)
    /// Waits for cancellation, with a bounded fallback if no terminal callback arrives.
    func cancel() async
}

@MainActor private final class NetworkScannerListener: LocalScannerListening {
    private let listener: NWListener
    private var terminal = false
    private var cancellationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LocalScannerServer.port)!)
        listener = try NWListener(using: parameters)
    }
    func start(onState: @escaping @MainActor (LocalScannerListenerState) -> Void,
               onConnection: @escaping @MainActor (NWConnection) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: onState(.ready)
                case .waiting: onState(.waiting)
                case .failed(let error): self.finishCancellation(); onState(.failed(error))
                case .cancelled: self.finishCancellation(); onState(.cancelled)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { connection in Task { @MainActor in onConnection(connection) } }
        listener.start(queue: .main)
    }
    func cancel() async {
        listener.cancel()
        guard !terminal else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            cancellationWaiters[id] = continuation
            // Cancellation is normally immediate. Do not strand future starts
            // if the networking subsystem never delivers its terminal callback.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.cancellationWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }
    private func finishCancellation() {
        terminal = true
        let waiters = Array(cancellationWaiters.values); cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// A loopback HTTP origin gives WebKit a trustworthy local camera/worker context.
/// Serves bundled assets and authenticated game-cache records; never a general file or network proxy.
@MainActor final class LocalScannerServer {
    static let shared = LocalScannerServer()
    static let port: UInt16 = 18764 // Stable origin preserves the game's IndexedDB downloads.
    static let origin = "http://127.0.0.1:\(port)"
    static let pageURL = URL(string: origin + "/index.html")!
    let cacheToken = UUID().uuidString
    private var connections: [UUID: (connection: NWConnection, buffer: RequestBuffer)] = [:]
    private var listener: (any LocalScannerListening)?
    private var generation = UUID()
    private var ready = false
    private var starting = false
    private var restarting = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var launchTask: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let listenerFactory: @MainActor () throws -> any LocalScannerListening
    private let resourcesAvailable: @MainActor () -> Bool
    private let startupTimeout: Duration

    init(listenerFactory: (@MainActor () throws -> any LocalScannerListening)? = nil,
         startupTimeout: Duration = .seconds(5), resourcesAvailable: (@MainActor () -> Bool)? = nil) {
        self.listenerFactory = listenerFactory ?? { try NetworkScannerListener() }
        self.resourcesAvailable = resourcesAvailable ?? { Bundle.main.url(forResource: "ScannerRuntime", withExtension: nil) != nil }
        self.startupTimeout = startupTimeout
    }

    func start() async throws {
        try Task.checkCancellation()
        if ready, listener != nil { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[id] = continuation
                if !starting { beginStart() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
        try Task.checkCancellation()
    }
    /// Overlapping recovery requests share one replacement listener.
    func restart() async throws {
        try Task.checkCancellation()
        if !restarting {
            DiagnosticLog.shared.record("local_server.restarting", ["phase": "recovery"])
            invalidate(CancellationError()); restarting = true
        }
        try await start()
    }
    func stop() {
        DiagnosticLog.shared.record("local_server.stopped", ["phase": "lifecycle"])
        invalidate(CancellationError())
    }
    private func beginStart() {
        starting = true; ready = false
        let id = UUID(); generation = id
        DiagnosticLog.shared.record("local_server.starting", ["phase": "startup"])
        guard resourcesAvailable() else { fail(LocalScannerFailure.missingResources, reason: "resources"); return }
        let timeout = startupTimeout
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == id, self.starting else { return }
            self.fail(LocalScannerFailure.startupTimedOut, reason: "timeout")
        }
        let closing = closingTask
        launchTask = Task { @MainActor [weak self] in
            await closing?.value
            guard let self, self.generation == id, self.starting, !Task.isCancelled else { return }
            do {
                let listener = try self.listenerFactory()
                self.listener = listener
                listener.start(onState: { [weak self] state in self?.receive(state, generation: id) }, onConnection: { [weak self] connection in
                    guard let self, self.generation == id, self.ready else { connection.cancel(); return }
                    self.serve(connection)
                })
            } catch { self.fail(error, reason: "creation") }
        }
    }
    private func receive(_ state: LocalScannerListenerState, generation id: UUID) {
        guard generation == id, listener != nil else { return }
        switch state {
        case .ready:
            guard starting else { return }
            ready = true; starting = false; restarting = false
            timeoutTask?.cancel(); timeoutTask = nil; launchTask = nil
            DiagnosticLog.shared.record("local_server.ready", ["phase": "startup"])
            let pending = Array(waiters.values); waiters.removeAll()
            for waiter in pending { waiter.resume() }
        case .waiting:
            DiagnosticLog.shared.record("local_server.waiting", ["phase": ready ? "ready" : "startup"])
            if ready { fail(LocalScannerFailure.listenerUnavailable, reason: "waiting") }
        case .failed(let error): fail(error, reason: "listener")
        case .cancelled: fail(CancellationError(), reason: "cancelled")
        }
    }
    private func fail(_ error: Error, reason: String) {
        DiagnosticLog.shared.record("local_server.failed", ["phase": ready ? "ready" : "startup", "reason": reason, "code": String((error as NSError).code)])
        invalidate(error)
    }
    private func invalidate(_ error: Error) {
        generation = UUID(); ready = false; starting = false; restarting = false
        launchTask?.cancel(); launchTask = nil; timeoutTask?.cancel(); timeoutTask = nil
        let previous = listener; listener = nil
        if let previous {
            let closing = closingTask
            closingTask = Task { @MainActor in await closing?.value; await previous.cancel() }
        }
        for entry in Array(connections.values) { close(entry.connection, buffer: entry.buffer) }
        let pending = Array(waiters.values); waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }
    private final class RequestBuffer {
        let id = UUID()
        var data = Data()
        var closed = false
        var deadline: Task<Void, Never>?
    }
    private func serve(_ connection: NWConnection) {
        guard connections.count < 24 else { connection.cancel(); return }
        let buffer = RequestBuffer()
        connections[buffer.id] = (connection, buffer)
        buffer.deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self.close(connection, buffer: buffer)
        }
        connection.start(queue: .main)
        receive(connection, buffer: buffer)
    }
    private func close(_ connection: NWConnection, buffer: RequestBuffer) {
        guard !buffer.closed else { return }
        buffer.closed = true; buffer.deadline?.cancel(); buffer.deadline = nil
        connections[buffer.id] = nil; connection.cancel()
    }
    private func receive(_ connection: NWConnection, buffer: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            Task { @MainActor in
                guard !buffer.closed else { return }
                if let data { buffer.data.append(data) }
                guard error == nil, buffer.data.count <= ScannerDatabaseCache.maximumEntryBytes + 16384 else { self.close(connection, buffer: buffer); return }
                guard let separator = buffer.data.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete || buffer.data.count > 16384 { self.close(connection, buffer: buffer) }
                    else { self.receive(connection, buffer: buffer) }
                    return
                }
                guard separator.lowerBound <= 16384,
                      let text = String(data: buffer.data.prefix(separator.lowerBound), encoding: .utf8) else { self.close(connection, buffer: buffer); return }
                let lines = text.components(separatedBy: "\r\n")
                let first = (lines.first ?? "").split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.close(connection, buffer: buffer); return }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else { self.close(connection, buffer: buffer); return }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard first.count == 3, headers["host"] == "127.0.0.1:\(Self.port)", headers["transfer-encoding"] == nil,
                      let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= ScannerDatabaseCache.maximumEntryBytes else {
                    self.send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return
                }
                let expected = separator.upperBound + length
                if buffer.data.count < expected {
                    if complete { self.close(connection, buffer: buffer) }
                    else { self.receive(connection, buffer: buffer) }
                    return
                }
                guard buffer.data.count == expected else { self.send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return }
                let body = buffer.data.subdata(in: separator.upperBound..<expected)
                buffer.deadline?.cancel()
                await self.respond(connection, buffer: buffer, method: String(first[0]), target: String(first[1]), headers: headers, body: body)
            }
        }
    }
    private func respond(_ connection: NWConnection, buffer: RequestBuffer, method: String, target: String, headers: [String: String], body: Data) async {
        guard target.hasPrefix("/"), let components = URLComponents(string: Self.origin + target), components.host == "127.0.0.1" else {
            send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return
        }
        if components.path.hasPrefix("/scanner-cache/") {
            guard ScannerCacheRequestPolicy.permits(headers: headers, origin: Self.origin, token: cacheToken) else {
                send(connection, buffer: buffer, status: "403 Forbidden", data: Data()); return
            }
            do {
                if components.path == "/scanner-cache/keys", method == "GET", components.query == nil, body.isEmpty {
                    let keys = try await ScannerDatabaseCache.shared.keys()
                    send(connection, buffer: buffer, status: "200 OK", data: try JSONEncoder().encode(keys), mime: "application/json"); return
                }
                guard components.path == "/scanner-cache/entry", let items = components.queryItems, items.count == 1,
                      items[0].name == "key", let key = items[0].value, ScannerDatabaseCache.validKey(key) else {
                    send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return
                }
                switch method {
                case "GET" where body.isEmpty:
                    guard let value = try await ScannerDatabaseCache.shared.read(key) else { send(connection, buffer: buffer, status: "404 Not Found", data: Data()); return }
                    send(connection, buffer: buffer, status: "200 OK", data: value)
                case "PUT" where !body.isEmpty:
                    if let encoded = headers["x-scanner-previous-manifest"] {
                        guard encoded.utf8.count <= 2048,
                              let decoded = encoded.removingPercentEncoding,
                              let value = try? JSONSerialization.jsonObject(with: Data(decoded.utf8), options: [.fragmentsAllowed]),
                              value is NSNull || value is String else {
                            send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return
                        }
                        let committed = try await ScannerDatabaseCache.shared.replaceManifestIfCurrent(
                            key: key, expected: value as? String, data: body)
                        send(connection, buffer: buffer, status: committed ? "204 No Content" : "409 Conflict", data: Data())
                    } else {
                        try await ScannerDatabaseCache.shared.write(key, data: body)
                        send(connection, buffer: buffer, status: "204 No Content", data: Data())
                    }
                case "DELETE" where body.isEmpty:
                    if headers["x-scanner-prune"] == "1" {
                        // A retired scanner document can have cleanup requests
                        // in flight. Never prune the database now selected by a
                        // completed automatic update.
                        _ = try await ScannerDatabaseCache.shared.removeIfUnreferenced(key)
                    } else {
                        try await ScannerDatabaseCache.shared.remove(key)
                    }
                    send(connection, buffer: buffer, status: "204 No Content", data: Data())
                default: send(connection, buffer: buffer, status: "405 Method Not Allowed", data: Data())
                }
            } catch ScannerDatabaseUpdateFailure.invalidResult { send(connection, buffer: buffer, status: "400 Bad Request", data: Data()) }
            catch ScannerCacheFailure.invalidKey { send(connection, buffer: buffer, status: "400 Bad Request", data: Data()) }
            catch ScannerCacheFailure.capacity {
                DiagnosticLog.shared.record("cache.native_failed", ["reason": "capacity", "code": "507"])
                send(connection, buffer: buffer, status: "507 Insufficient Storage", data: Data())
            } catch ScannerCacheFailure.corruptEntry {
                DiagnosticLog.shared.record("cache.native_failed", ["reason": "corrupt", "code": "500"])
                send(connection, buffer: buffer, status: "500 Internal Server Error", data: Data())
            } catch {
                DiagnosticLog.shared.failure("cache.native_failed", error)
                send(connection, buffer: buffer, status: "500 Internal Server Error", data: Data())
            }
            return
        }
        guard method == "GET", body.isEmpty, let root = Bundle.main.url(forResource: "ScannerRuntime", withExtension: nil) else {
            send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return
        }
        let path = components.path
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"), !path.contains("\0") else {
            send(connection, buffer: buffer, status: "404 Not Found", data: Data()); return
        }
        let url = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: url) else {
            send(connection, buffer: buffer, status: "404 Not Found", data: Data()); return
        }
        let mime: String
        switch url.pathExtension {
        case "js": mime = "text/javascript; charset=utf-8"
        case "html": mime = "text/html; charset=utf-8"
        case "json": mime = "application/json"
        case "wasm": mime = "application/wasm"
        default: mime = "application/octet-stream"
        }
        send(connection, buffer: buffer, status: "200 OK", data: data, mime: mime)
    }
    private func send(_ connection: NWConnection, buffer: RequestBuffer, status: String, data: Data, mime: String = "application/octet-stream") {
        guard !buffer.closed else { return }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var body = Data(header.utf8); body.append(data)
        connection.send(content: body, completion: .contentProcessed { _ in Task { @MainActor in self.close(connection, buffer: buffer) } })
    }
}

enum LocalScannerFailure: LocalizedError, Equatable {
    case missingResources, startupTimedOut, listenerUnavailable
    var errorDescription: String? {
        switch self {
        case .missingResources: return "Bundled scanner resources are missing. Rebuild the app with ScannerRuntime in Copy Bundle Resources."
        case .startupTimedOut: return "The local scanner took too long to start. Tap Retry Live Scanner."
        case .listenerUnavailable: return "The local scanner connection was interrupted. Tap Retry Live Scanner."
        }
    }
}
