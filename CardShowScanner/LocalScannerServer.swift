import Foundation
import Network

/// A loopback HTTP origin gives WebKit a trustworthy local camera/worker context.
/// Serves bundled assets and authenticated game-cache records; never a general file or network proxy.
@MainActor final class LocalScannerServer {
    static let shared = LocalScannerServer()
    static let port: UInt16 = 18764 // Stable origin preserves the game's IndexedDB downloads.
    static let origin = "http://127.0.0.1:\(port)"
    static let pageURL = URL(string: origin + "/index.html")!
    let cacheToken = UUID().uuidString
    private var connections = 0
    private var listener: NWListener?
    private var startup: Task<Void, Error>?
    private init() {}

    func start() async throws {
        if let startup { return try await startup.value }
        let task = Task { @MainActor in
            guard Bundle.main.url(forResource: "ScannerRuntime", withExtension: nil) != nil else {
                throw LocalScannerFailure.missingResources
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var completed = false
                listener.stateUpdateHandler = { state in
                    Task { @MainActor in
                        guard !completed else { return }
                        switch state {
                        case .ready: completed = true; continuation.resume()
                        case .failed(let error): completed = true; continuation.resume(throwing: error)
                        case .cancelled: completed = true; continuation.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { connection in
                    Task { @MainActor in self.serve(connection) }
                }
                listener.start(queue: .main)
            }
        }
        startup = task
        do { try await task.value }
        catch { listener?.cancel(); listener = nil; startup = nil; throw error }
    }
    private final class RequestBuffer {
        var data = Data()
        var closed = false
        var deadline: Task<Void, Never>?
    }
    private func serve(_ connection: NWConnection) {
        guard connections < 24 else { connection.cancel(); return }
        connections += 1
        let buffer = RequestBuffer()
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
        connections -= 1; connection.cancel()
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
                    try await ScannerDatabaseCache.shared.write(key, data: body)
                    send(connection, buffer: buffer, status: "204 No Content", data: Data())
                case "DELETE" where body.isEmpty:
                    try await ScannerDatabaseCache.shared.remove(key)
                    send(connection, buffer: buffer, status: "204 No Content", data: Data())
                default: send(connection, buffer: buffer, status: "405 Method Not Allowed", data: Data())
                }
            } catch ScannerCacheFailure.invalidKey { send(connection, buffer: buffer, status: "400 Bad Request", data: Data()) }
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
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var body = Data(header.utf8); body.append(data)
        connection.send(content: body, completion: .contentProcessed { _ in Task { @MainActor in self.close(connection, buffer: buffer) } })
    }
}

enum LocalScannerFailure: LocalizedError {
    case missingResources
    var errorDescription: String? { "Bundled scanner resources are missing. Rebuild the app with ScannerRuntime in Copy Bundle Resources." }
}
