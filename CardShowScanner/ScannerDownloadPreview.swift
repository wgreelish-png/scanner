import Foundation
import CoreFoundation
import zlib

/// A metadata-only plan. Transfer counts exclude the small index/manifest
/// requests. Compressed metadata is not an installed-size measurement.
struct ScannerDownloadPreview: Equatable, Sendable {
    let gameKey: String
    let downloadBytes: Int64
    let cachedBytes: Int64
    /// Known binary bytes plus native record headers. New decoded metadata,
    /// filesystem allocation and temporary files can require additional space.
    let minimumAdditionalStorageBytes: Int64
    let additionalStorageIsExact: Bool
    let missingFiles: Int
    let totalFiles: Int
    let isUsingCachedMetadata: Bool
    let availableStorageBytes: Int64?
}

enum ScannerDownloadPreviewFailure: Error {
    case unavailable, invalidMetadata, responseTooLarge
}

/// Reads only public pack metadata and a native cache inventory. Previewing
/// never downloads recognition shards, writes a cache record or activates a pack.
actor ScannerDownloadPreviewService {
    typealias Loader = @Sendable (URL, Int) async throws -> Data
    static let shared = ScannerDownloadPreviewService()
    private static let maximumMetadataBytes = 1_048_576
    private static let maximumExpandedBytes = 4 * 1_048_576
    private static let bases = ["https://nsp-static.tcgtracking.com/packs/",
                                "https://tcgtracking.com/newscanplus/packs/"]
    private let cache: ScannerDatabaseCache
    private let loader: Loader

    init(cache: ScannerDatabaseCache = .shared, loader: Loader? = nil) {
        self.cache = cache
        self.loader = loader ?? { try await Self.download($0, maximumBytes: $1) }
    }

    func preview(game: String, preferSaved: Bool = false) async throws -> ScannerDownloadPreview {
        try Task.checkCancellation()
        guard let key = TCGGameRegistry.scannerKey(for: game) else { throw ScannerDownloadPreviewFailure.invalidMetadata }
        let sizes = try await cache.recordSizes()
        let available = try? await cache.availableStorageBytes()
        let saved = try await savedPlan(gameKey: key, sizes: sizes, available: available)
        try Task.checkCancellation()
        if preferSaved, let saved, saved.missingFiles == 0 { return saved }
        do {
            let index = try await metadata("index.json")
            let root = try Self.object(index)
            guard let games = root["games"] as? [String: Any], let entry = games[key] as? [String: Any] else {
                throw ScannerDownloadPreviewFailure.unavailable
            }
            let plan: ScannerDownloadPreview
            if let raw = entry["v2"] {
                guard let v2 = raw as? [String: Any], let path = v2["manifest"] as? String, Self.safePath(path) else {
                    throw ScannerDownloadPreviewFailure.invalidMetadata
                }
                let manifest = try await metadata(path)
                plan = try Self.v2Plan(manifest, path: path, gameKey: key, sizes: sizes,
                                      available: available, cached: false)
            } else {
                plan = try Self.legacyPlan(entry, gameKey: key, sizes: sizes, available: available, cached: false)
            }
            try Task.checkCancellation()
            return plan
        } catch {
            try Task.checkCancellation()
            if let saved { return saved }
            throw error
        }
    }

    private func savedPlan(gameKey: String, sizes: [String: Int], available: Int64?) async throws -> ScannerDownloadPreview? {
        try Task.checkCancellation()
        if (sizes["cur:" + gameKey] ?? 0) <= 4096,
           let marker = try? await cache.read("cur:" + gameKey), marker.first == 0,
           let path = try? JSONSerialization.jsonObject(with: Data(marker.dropFirst()), options: [.fragmentsAllowed]) as? String,
           Self.safePath(path), (sizes["M:" + path] ?? 0) <= Self.maximumExpandedBytes + 516,
           let data = try? await cache.read("M:" + path), data.first == 0,
           let plan = try? Self.v2Plan(Data(data.dropFirst()), path: path, gameKey: gameKey,
                                     sizes: sizes, available: available, cached: true) {
            return plan
        }
        guard (sizes["index"] ?? 0) <= Self.maximumMetadataBytes + 516,
              let data = try? await cache.read("index"), data.first == 0,
              let root = try? Self.object(Data(data.dropFirst())), let games = root["games"] as? [String: Any],
              let entry = games[gameKey] as? [String: Any] else { return nil }
        if let v2 = entry["v2"] as? [String: Any], let path = v2["manifest"] as? String, Self.safePath(path),
           (sizes["M:" + path] ?? 0) <= Self.maximumExpandedBytes + 516,
           let manifest = try? await cache.read("M:" + path), manifest.first == 0 {
            return try? Self.v2Plan(Data(manifest.dropFirst()), path: path, gameKey: gameKey,
                                   sizes: sizes, available: available, cached: true)
        }
        return try? Self.legacyPlan(entry, gameKey: gameKey, sizes: sizes, available: available, cached: true)
    }

    private func metadata(_ path: String) async throws -> Data {
        guard Self.safePath(path) else { throw ScannerDownloadPreviewFailure.invalidMetadata }
        var lastError: Error = ScannerDownloadPreviewFailure.unavailable
        for base in Self.bases {
            do {
                try Task.checkCancellation()
                let bytes = try await loader(URL(string: base + path)!, Self.maximumMetadataBytes)
                try Task.checkCancellation()
                return try Self.decodeMetadata(bytes)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    static func v2Plan(_ data: Data, path: String, gameKey: String, sizes: [String: Int],
                       available: Int64?, cached: Bool) throws -> ScannerDownloadPreview {
        guard safePath(path), ScannerDatabaseCache.validKey("M:" + path) else { throw ScannerDownloadPreviewFailure.invalidMetadata }
        let manifest = try object(data)
        guard integer(manifest["v"], maximum: 2) == 2,
              manifest["game"].map({ $0 as? String == gameKey }) ?? true,
              let shards = manifest["shards"] as? [[String: Any]], !shards.isEmpty, shards.count <= 4094 else {
            throw ScannerDownloadPreviewFailure.invalidMetadata
        }
        let directory = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
        var records: [String: (transfer: Int64, binary: Bool)] = [:]
        for shard in shards {
            try Task.checkCancellation()
            guard let hash = shard["hash"] as? String, let meta = shard["meta"] as? String,
                  safeName(hash), safeName(meta),
                  let bytes = integer(shard["bytes"], maximum: Int64(ScannerDatabaseCache.maximumEntryBytes - 1)),
                  let metaBytes = integer(shard["meta_bytes"], maximum: Int64(ScannerDatabaseCache.maximumEntryBytes)) else {
                throw ScannerDownloadPreviewFailure.invalidMetadata
            }
            for (key, transfer, binary) in [("h:" + directory + hash, bytes, true), ("m:" + directory + meta, metaBytes, false)] {
                guard ScannerDatabaseCache.validKey(key) else { throw ScannerDownloadPreviewFailure.invalidMetadata }
                if let previous = records[key], previous.transfer != transfer { throw ScannerDownloadPreviewFailure.invalidMetadata }
                records[key] = (transfer, binary)
            }
        }
        var transfer: Int64 = 0, stored: Int64 = 0, minimum: Int64 = 0, missing = 0
        for (key, record) in records {
            let overhead = Int64(key.utf8.count + 5)
            let size = Int64(sizes[key] ?? 0)
            let validSize = record.binary ? size == overhead + record.transfer : size > overhead
            if validSize { stored += size }
            else {
                missing += 1; transfer += record.transfer
                minimum += overhead + (record.binary ? record.transfer : 0)
            }
        }
        for key in ["M:" + path, "cur:" + gameKey] { stored += Int64(sizes[key] ?? 0) }
        return ScannerDownloadPreview(gameKey: gameKey, downloadBytes: transfer, cachedBytes: stored,
            minimumAdditionalStorageBytes: minimum, additionalStorageIsExact: missing == 0,
            missingFiles: missing, totalFiles: records.count, isUsingCachedMetadata: cached, availableStorageBytes: available)
    }

    static func legacyPlan(_ entry: [String: Any], gameKey: String, sizes: [String: Int],
                           available: Int64?, cached: Bool) throws -> ScannerDownloadPreview {
        guard let bin = entry["bin"] as? String, let meta = entry["meta"] as? String, safePath(bin), safePath(meta),
              let binaryBytes = integer(entry["bin_bytes"], maximum: Int64(ScannerDatabaseCache.maximumEntryBytes)),
              let metaBytes = integer(entry["meta_bytes"], maximum: Int64(ScannerDatabaseCache.maximumEntryBytes)) else {
            throw ScannerDownloadPreviewFailure.invalidMetadata
        }
        let version: String
        if let value = entry["ver"] as? String { version = value }
        else if let number = entry["ver"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            version = number.stringValue
        } else { throw ScannerDownloadPreviewFailure.invalidMetadata }
        guard version.range(of: #"^[A-Za-z0-9_.:-]{1,100}$"#, options: .regularExpression) != nil else {
            throw ScannerDownloadPreviewFailure.invalidMetadata
        }
        let key = gameKey + "@" + version
        guard ScannerDatabaseCache.validKey(key) else { throw ScannerDownloadPreviewFailure.invalidMetadata }
        let size = Int64(sizes[key] ?? 0), overhead = Int64(key.utf8.count + 9)
        let complete = size > overhead
        return ScannerDownloadPreview(gameKey: gameKey, downloadBytes: complete ? 0 : binaryBytes + metaBytes,
            cachedBytes: complete ? size : 0, minimumAdditionalStorageBytes: complete ? 0 : overhead,
            additionalStorageIsExact: complete, missingFiles: complete ? 0 : 2, totalFiles: 2,
            isUsingCachedMetadata: cached, availableStorageBytes: available)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumExpandedBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScannerDownloadPreviewFailure.invalidMetadata
        }
        return object
    }
    private static func integer(_ value: Any?, maximum: Int64) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(maximum), value.rounded() == value else { return nil }
        return Int64(value)
    }
    private static func safeName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$"#, options: .regularExpression) != nil
    }
    private static func safePath(_ path: String) -> Bool {
        guard path.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./-]{0,449}$"#, options: .regularExpression) != nil else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func decodeMetadata(_ data: Data) throws -> Data {
        guard data.count <= maximumMetadataBytes else { throw ScannerDownloadPreviewFailure.responseTooLarge }
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ScannerDownloadPreviewFailure.invalidMetadata
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: maximumExpandedBytes)
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { buffer in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0 else { throw ScannerDownloadPreviewFailure.invalidMetadata }
        return Data(output.prefix(Int(stream.total_out)))
    }

    nonisolated private static func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ScannerPreviewRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json, application/gzip", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ScannerDownloadPreviewFailure.unavailable }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw ScannerDownloadPreviewFailure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw ScannerDownloadPreviewFailure.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

private final class ScannerPreviewRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
