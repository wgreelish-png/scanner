import Foundation
import CryptoKit

/// Downloaded recognition data belongs to the app, rather than WebKit's evictable website storage.
/// Keys never become paths; a record commits atomically and includes its key for collision/corruption checks.
actor ScannerDatabaseCache {
    static let shared = ScannerDatabaseCache()
    static let maximumEntryBytes = 32 * 1024 * 1024
    static let maximumTotalBytes = 512 * 1024 * 1024
    static let maximumKeys = 8192
    private let root: URL
    private var sizes: [String: Int]?

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScannerDatabase-v1", isDirectory: true)
    }
    static func validKey(_ key: String) -> Bool {
        guard key.utf8.count <= 512, !key.contains(".."), !key.contains("\\"), !key.contains("\0") else { return false }
        return key.range(of: #"^(index|cur:tcgp:[0-9]{1,6}|[hMm]:[A-Za-z0-9_./:-]{1,450}|tcgp:[0-9]{1,6}@[A-Za-z0-9_.:-]{1,100})$"#, options: .regularExpression) != nil
    }
    private func location(_ key: String) throws -> URL {
        guard Self.validKey(key) else { throw ScannerCacheFailure.invalidKey }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".entry", isDirectory: false)
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if sizes == nil {
            var loaded: [String: Int] = [:]
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) where url.pathExtension == "entry" {
                let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      let size = properties.fileSize, size <= Self.maximumEntryBytes + 516,
                      let key = try? storedKey(at: url), Self.validKey(key), (try? location(key)) == url else { continue }
                loaded[key] = size
            }
            sizes = loaded
        }
    }
    private func storedKey(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 4), prefix.count == 4 else { throw ScannerCacheFailure.corruptEntry }
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...512).contains(length), let data = try handle.read(upToCount: length), data.count == length,
              let key = String(data: data, encoding: .utf8) else { throw ScannerCacheFailure.corruptEntry }
        return key
    }
    func keys() throws -> [String] { try prepare(); return (sizes ?? [:]).keys.sorted() }
    func read(_ key: String) throws -> Data? {
        let url = try location(key); try prepare()
        guard sizes?[key] != nil else { return nil }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let count = properties.fileSize, count <= Self.maximumEntryBytes + 516 else { throw ScannerCacheFailure.corruptEntry }
        let record = try Data(contentsOf: url)
        guard try storedKey(at: url) == key, record.count >= key.utf8.count + 4 else { throw ScannerCacheFailure.corruptEntry }
        return record.subdata(in: (key.utf8.count + 4)..<record.count)
    }
    func write(_ key: String, data: Data) throws {
        let url = try location(key)
        guard data.count <= Self.maximumEntryBytes else { throw ScannerCacheFailure.capacity }
        try prepare()
        let keyData = Data(key.utf8), count = keyData.count
        var record = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        record.append(keyData); record.append(data)
        let previous = sizes?[key] ?? 0
        guard (sizes?.count ?? 0) < Self.maximumKeys || previous > 0,
              (sizes ?? [:]).values.reduce(0, +) - previous + record.count <= Self.maximumTotalBytes else { throw ScannerCacheFailure.capacity }
        try record.write(to: url, options: .atomic)
        sizes?[key] = record.count
    }
    func remove(_ key: String) throws {
        let url = try location(key); try prepare()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        sizes?.removeValue(forKey: key)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        sizes = nil
    }
}

enum ScannerCacheFailure: Error { case invalidKey, corruptEntry, capacity }

enum ScannerCacheRequestPolicy {
    static func permits(headers: [String: String], origin: String, token: String) -> Bool {
        guard !token.isEmpty, let url = URL(string: origin), let host = url.host,
              headers["host"] == host + ":" + String(url.port ?? 80), headers["x-scanner-cache"] == token else { return false }
        return headers["origin"].map { $0 == origin } ?? true
    }
}
