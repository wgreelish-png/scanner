import Foundation

/// Only connectivity errors can reuse a saved public response. HTTP, decoding,
/// certificate, authentication and cancellation failures always remain failures.
enum OpenAPIConnectivityFailure {
    static func allowsOfflineFallback(_ error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                .internationalRoamingOff, .callIsActive, .dataNotAllowed]
            .contains { $0.rawValue == error.code }
    }
}

/// This cache stores only bounded, validated, credential-free public SKU bodies.
/// It is separate from scanner packs, website storage and saved offer prices.
/// A lock serializes disk access; synchronous calls keep price-cache publication
/// within one actor turn so superseded requests cannot write a late response.
final class OpenAPIPriceDiskCache: @unchecked Sendable {
    static let maximumEntries = 4
    static let maximumEntryBytes = NativeOpenAPIHTTPDataLoader.maximumBytes
    static let maximumTotalBytes = 32 * 1_024 * 1_024
    static var defaultDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("PublicOpenAPIPrices", isDirectory: true)
    }

    struct Entry: Codable, Sendable {
        var data: Data
        var etag: String?
        var fetchedAt: Date
        var validatedAt: Date
    }
    private struct Record: Codable {
        var version = 1
        var url: URL
        var entry: Entry
    }
    private let directory: URL?
    private let files = FileManager.default
    private let lock = NSLock()

    init(directory: URL?) { self.directory = directory }

    func entry(for url: URL, now: Date) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard !Task.isCancelled, let directory, let name = Self.filename(for: url) else { return nil }
        prune(now: now)
        let file = directory.appendingPathComponent(name)
        guard let record = read(file, now: now), record.url == url else { return nil }
        return record.entry
    }

    func store(_ entry: Entry, for url: URL, now: Date) {
        lock.lock(); defer { lock.unlock() }
        guard !Task.isCancelled, let directory, let name = Self.filename(for: url),
              Self.valid(entry, for: url, now: now) else { return }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Record(url: url, entry: entry)),
              data.count <= Self.maximumTotalBytes else { return }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            guard !Task.isCancelled else { return }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            prune(now: now)
        } catch {
            // A disk failure must not prevent a valid network quote.
        }
    }

    private static func filename(for url: URL) -> String? {
        guard NativeOpenAPIHTTPDataLoader.allows(url) else { return nil }
        let parts = url.pathComponents
        guard parts.count == 6 else { return nil }
        return parts[2] + "-" + parts[4] + ".plist"
    }

    private static func valid(_ entry: Entry, for url: URL, now: Date) -> Bool {
        guard filename(for: url) != nil, entry.data.count <= maximumEntryBytes,
              entry.fetchedAt.timeIntervalSince1970.isFinite,
              entry.validatedAt.timeIntervalSince1970.isFinite,
              entry.fetchedAt <= now, entry.validatedAt <= now,
              entry.fetchedAt <= entry.validatedAt,
              entry.etag.map({ $0.utf8.count <= 1_024 && !$0.contains("\r") && !$0.contains("\n") }) ?? true,
              let set = Int(url.pathComponents[4]) else { return false }
        return (try? OpenAPIMarketPricing.validate(entry.data, expectedSetID: set, now: now)) != nil
    }

    private func read(_ file: URL, now: Date) -> Record? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumEntryBytes + 16_384,
              let data = try? Data(contentsOf: file),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.version == 1, Self.filename(for: record.url) == file.lastPathComponent,
              Self.valid(record.entry, for: record.url, now: now) else {
            try? files.removeItem(at: file)
            return nil
        }
        return record
    }

    private func prune(now: Date) {
        guard let directory,
              let contents = try? files.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return }
        var records: [(file: URL, date: Date, bytes: Int)] = []
        for file in contents {
            guard file.pathExtension == "plist", let record = read(file, now: now),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                try? files.removeItem(at: file)
                continue
            }
            records.append((file, record.entry.validatedAt, size))
        }
        records.sort { $0.date > $1.date }
        var bytes = 0
        for (index, record) in records.enumerated() {
            bytes += record.bytes
            if index >= Self.maximumEntries || bytes > Self.maximumTotalBytes {
                try? files.removeItem(at: record.file)
            }
        }
    }
}
