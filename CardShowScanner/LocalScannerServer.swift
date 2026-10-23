import Foundation
import Network

/// A loopback HTTP origin gives WebKit a trustworthy local camera/worker context.
/// Serves bundled scanner assets only; it is never a general file or network proxy.
@MainActor final class LocalScannerServer {
    static let shared = LocalScannerServer()
    static let port: UInt16 = 18764 // Stable origin preserves the game's IndexedDB downloads.
    static let origin = "http://127.0.0.1:\(port)"
    static let pageURL = URL(string: origin + "/index.html")!
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
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            Task { @MainActor in
                var buffer = accumulated
                if let data { buffer.append(data) }
                guard buffer.count <= 16384, error == nil else { connection.cancel(); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(connection, request: buffer)
                } else if complete { connection.cancel() }
                else { self.receive(connection, accumulated: buffer) }
            }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { connection.cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET",
              lines.contains(where: { $0.lowercased() == "host: 127.0.0.1:\(Self.port)" }),
              let root = Bundle.main.url(forResource: "ScannerRuntime", withExtension: nil) else {
            send(connection, status: "400 Bad Request", data: Data()); return
        }
        let path = String(first[1]).components(separatedBy: "?")[0].removingPercentEncoding ?? ""
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"), !path.contains("\0") else {
            send(connection, status: "404 Not Found", data: Data()); return
        }
        let url = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: url) else {
            send(connection, status: "404 Not Found", data: Data()); return
        }
        let mime: String
        switch url.pathExtension {
        case "js": mime = "text/javascript; charset=utf-8"
        case "html": mime = "text/html; charset=utf-8"
        case "json": mime = "application/json"
        case "wasm": mime = "application/wasm"
        default: mime = "application/octet-stream"
        }
        send(connection, status: "200 OK", data: data, mime: mime)
    }
    private func send(_ connection: NWConnection, status: String, data: Data, mime: String = "text/plain") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var body = Data(header.utf8); body.append(data)
        connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

enum LocalScannerFailure: LocalizedError {
    case missingResources
    var errorDescription: String? { "Bundled scanner resources are missing. Rebuild the app with ScannerRuntime in Copy Bundle Resources." }
}
