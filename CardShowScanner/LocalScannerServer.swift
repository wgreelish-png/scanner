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
    typealias ReachabilityProbe = @MainActor (_ token: String, _ generation: UUID) async throws -> Bool
    static let shared = LocalScannerServer()
    static let port: UInt16 = 18764 // Stable origin preserves the game's IndexedDB downloads.
    static let origin = "http://127.0.0.1:\(port)"
    static let pageURL = URL(string: origin + "/index.html")!
    private static let healthURL = URL(string: origin + "/scanner-health")!
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
    private let reachabilityProbe: ReachabilityProbe
    private let probeTimeout: Duration
    private var healthID: UUID?
    private var healthTask: Task<Void, Never>?
    private var healthWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var probeID: UUID?
    private var probeTask: Task<Void, Never>?
    private var probeDeadline: Task<Void, Never>?
    private var probeContinuation: CheckedContinuation<Bool, Error>?

    init(listenerFactory: (@MainActor () throws -> any LocalScannerListening)? = nil,
         startupTimeout: Duration = .seconds(5), resourcesAvailable: (@MainActor () -> Bool)? = nil,
         probeTimeout: Duration = .seconds(1), reachabilityProbe: ReachabilityProbe? = nil) {
        self.listenerFactory = listenerFactory ?? { try NetworkScannerListener() }
        self.resourcesAvailable = resourcesAvailable ?? { Bundle.main.url(forResource: "ScannerRuntime", withExtension: nil) != nil }
        self.startupTimeout = startupTimeout
        self.probeTimeout = probeTimeout
        self.reachabilityProbe = reachabilityProbe ?? Self.probeLoopback
    }

    /// A cached NWListener.ready is not proof that its loopback socket survived
    /// suspension. One foreground check is shared by all current callers. A
    /// failed probe gets one replacement and verification, never a retry loop.
    func ensureReachable() async throws {
        try Task.checkCancellation()
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                healthWaiters[waiter] = continuation
                guard healthTask == nil else { return }
                let id = UUID(); healthID = id
                healthTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.verifyReachability(id); self.finishHealth(id, result: .success(Void())) }
                    catch { self.finishHealth(id, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelHealthWaiter(waiter) }
        }
        try Task.checkCancellation()
    }

    private func verifyReachability(_ id: UUID) async throws {
        for attempt in 0..<2 {
            try requireCurrentHealth(id)
            try await start()
            let checkedGeneration = generation
            let reachable = try await boundedProbe(health: id, generation: checkedGeneration)
            try requireCurrentHealth(id)
            // Another client may already have replaced the listener while this
            // operation awaited I/O. An old failure cannot restart that socket.
            guard generation == checkedGeneration else {
                if attempt == 0 { continue }
                throw LocalScannerFailure.listenerUnavailable
            }
            if reachable { return }
            guard attempt == 0 else { throw LocalScannerFailure.listenerUnavailable }
            DiagnosticLog.shared.record("local_server.health_recovery", ["phase": "foreground"])
            try await restart()
        }
        throw LocalScannerFailure.listenerUnavailable
    }

    private func requireCurrentHealth(_ id: UUID) throws {
        try Task.checkCancellation()
        guard healthID == id, !healthWaiters.isEmpty else { throw CancellationError() }
    }

    private func boundedProbe(health: UUID, generation: UUID) async throws -> Bool {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                guard healthID == health, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                probeID = id; probeContinuation = continuation
                let timeout = probeTimeout
                probeDeadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finishProbe(id, result: .success(false))
                }
                probeTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let reachable = try await self.reachabilityProbe(self.cacheToken, generation)
                        self.finishProbe(id, result: .success(reachable))
                    } catch {
                        self.finishProbe(id, result: .success(false))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishProbe(id, result: .failure(CancellationError())) }
        }
    }

    private func finishProbe(_ id: UUID, result: Result<Bool, Error>) {
        guard probeID == id else { return }
        probeID = nil
        let continuation = probeContinuation; probeContinuation = nil
        probeTask?.cancel(); probeTask = nil; probeDeadline?.cancel(); probeDeadline = nil
        continuation?.resume(with: result)
    }

    private func finishHealth(_ id: UUID, result: Result<Void, Error>) {
        guard healthID == id else { return }
        healthID = nil; healthTask = nil
        let pending = Array(healthWaiters.values); healthWaiters.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }

    private func cancelHealthWaiter(_ id: UUID) {
        healthWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        guard healthWaiters.isEmpty else { return }
        cancelHealth()
    }

    private func cancelHealth() {
        healthID = nil
        healthTask?.cancel(); healthTask = nil
        if let probeID { finishProbe(probeID, result: .failure(CancellationError())) }
        let pending = Array(healthWaiters.values); healthWaiters.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    private static func healthBody(token: String, generation: UUID) -> Data {
        Data((token + ":" + generation.uuidString).utf8)
    }

    private static func probeLoopback(token: String, generation: UUID) async throws -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 1; configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration, delegate: LocalScannerHealthRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: healthURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 1)
        request.setValue(token, forHTTPHeaderField: "X-Scanner-Cache")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == healthURL, response.expectedContentLength <= 128 else { return false }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 128 else { return false }
            body.append(byte)
        }
        return body == healthBody(token: token, generation: generation)
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
        cancelHealth()
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
        if components.path == "/scanner-health" {
            guard method == "GET", components.query == nil, body.isEmpty else {
                send(connection, buffer: buffer, status: "400 Bad Request", data: Data()); return
            }
            guard ScannerCacheRequestPolicy.permits(headers: headers, origin: Self.origin, token: cacheToken) else {
                send(connection, buffer: buffer, status: "403 Forbidden", data: Data()); return
            }
            send(connection, buffer: buffer, status: "200 OK", data: Self.healthBody(token: cacheToken, generation: generation)); return
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

/// Health requests never follow redirects, so the instance token remains on
/// the exact loopback origin even if an unrelated process owns the old port.
private final class LocalScannerHealthRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
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
