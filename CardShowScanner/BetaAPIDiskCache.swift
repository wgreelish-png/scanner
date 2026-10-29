import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Private, account-separated Beta snapshots. Only callers that have validated
/// the response's schema and exact catalog identity may store or use a body.
/// Cache reads never change checkedAt or claim that old data was revalidated.
actor BetaAPIDiskCache {
    static let shared = BetaAPIDiskCache()
    static let maximumEntryBytes = 8 * 1_024 * 1_024
    static let maximumShardEntries = 4
    static let maximumShardBytes = 32 * 1_024 * 1_024
    static let maximumIndexBytes = 8 * 1_024 * 1_024

    enum Kind: String, Codable, Sendable { case index, opportunities, research }
    struct Entry: Codable, Sendable {
        let data: Data
        let httpETag: String?
        let dataETag: String?
        let checkedAt: Date
    }

    private struct Record: Codable {
        let version: Int
        let digest: String
        let kind: Kind
        let entry: Entry
        var accessedAt: Date
    }
    private struct Saved {
        let name: String
        let record: Record
    }
    private let directory: URL?
    private let files = FileManager.default
    private static let maximumRecordBytes = maximumEntryBytes + 16_384

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BetaAPICache", isDirectory: true)
    }

    func entry(for key: String, kind: Kind) -> Entry? {
        guard !Task.isCancelled, let digest = Self.digest(key: key, kind: kind),
              let descriptor = openDirectory(create: false) else { return nil }
        defer { close(descriptor) }
        prune(directoryFD: descriptor)
        let name = digest + ".plist"
        guard var record = read(name: name, directoryFD: descriptor), record.digest == digest, record.kind == kind,
              !Task.isCancelled else { return nil }
        // Separate access time makes eviction LRU without altering source time.
        record.accessedAt = Date()
        write(record, name: name, directoryFD: descriptor)
        return record.entry
    }

    func store(_ entry: Entry, for key: String, kind: Kind) {
        guard !Task.isCancelled, Self.valid(entry), let digest = Self.digest(key: key, kind: kind),
              let descriptor = openDirectory(create: true) else { return }
        defer { close(descriptor) }
        let record = Record(version: 1, digest: digest, kind: kind, entry: entry, accessedAt: Date())
        write(record, name: digest + ".plist", directoryFD: descriptor)
        prune(directoryFD: descriptor)
    }

    func remove(for key: String, kind: Kind) {
        guard let digest = Self.digest(key: key, kind: kind), let descriptor = openDirectory(create: false) else { return }
        defer { close(descriptor) }
        _ = unlinkat(descriptor, digest + ".plist", 0)
    }

    /// Removes only this cache's hash-named records, preserving unrelated files.
    func clear() {
        guard let descriptor = openDirectory(create: false) else { return }
        defer { close(descriptor) }
        for name in ownNames() { _ = unlinkat(descriptor, name, 0) }
        removeTemporaryFiles(directoryFD: descriptor)
    }

    private static func digest(key: String, kind: Kind) -> String? {
        guard !key.isEmpty, key.utf8.count <= 1_024,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return SHA256.hash(data: Data((kind.rawValue + "\0" + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func valid(_ entry: Entry) -> Bool {
        entry.data.count <= maximumEntryBytes && entry.checkedAt.timeIntervalSince1970.isFinite &&
            validTag(entry.httpETag) && validTag(entry.dataETag)
    }

    private static func validTag(_ value: String?) -> Bool {
        value.map { $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true
    }

    private func openDirectory(create: Bool) -> Int32? {
        guard let directory, directory.isFileURL else { return nil }
        // Do not follow a replaced cache-directory symlink. openat below binds
        // every body operation to this descriptor even if its path changes.
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return nil }
        } else {
            guard create else { return nil }
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var mutableDirectory = directory; try? mutableDirectory.setResourceValues(values)
                #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                try? files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
                #endif
            } catch { return nil }
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, mode_t(0))
        return descriptor >= 0 ? descriptor : nil
    }

    private func ownNames() -> [String] {
        guard let directory, let contents = try? files.contentsOfDirectory(atPath: directory.path) else { return [] }
        return contents.filter { $0.range(of: #"^[0-9a-f]{64}\.plist$"#, options: .regularExpression) != nil }
    }

    private func removeTemporaryFiles(directoryFD: Int32) {
        guard let directory, let contents = try? files.contentsOfDirectory(atPath: directory.path) else { return }
        for name in contents where name.range(of: #"^\.beta-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.tmp$"#, options: .regularExpression) != nil {
            _ = unlinkat(directoryFD, name, 0)
        }
    }

    private func read(name: String, directoryFD: Int32) -> Record? {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0))
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size >= 0, status.st_size <= off_t(Self.maximumRecordBytes) else { return nil }
        do {
            var data = Data()
            while true {
                guard let chunk = try handle.read(upToCount: min(65_536, Self.maximumRecordBytes - data.count + 1)), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= Self.maximumRecordBytes else { return nil }
            }
            guard let record = try? PropertyListDecoder().decode(Record.self, from: data), record.version == 1,
                  record.digest + ".plist" == name, record.digest.count == 64,
                  record.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  record.accessedAt.timeIntervalSince1970.isFinite, Self.valid(record.entry) else { return nil }
            return record
        } catch { return nil }
    }

    private func write(_ record: Record, name: String, directoryFD: Int32) {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        guard !Task.isCancelled, let data = try? encoder.encode(record), data.count <= Self.maximumRecordBytes else { return }
        let temporary = ".beta-" + UUID().uuidString + ".tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { return }
        defer { _ = unlinkat(directoryFD, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            if let directory {
                try? files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                         ofItemAtPath: directory.appendingPathComponent(temporary).path)
            }
            #endif
            try handle.write(contentsOf: data)
            guard !Task.isCancelled, fsync(descriptor) == 0, !Task.isCancelled else { return }
            _ = renameat(directoryFD, temporary, directoryFD, name)
        } catch {
            // Persistence is best effort and never blocks a valid API response.
        }
    }

    private func prune(directoryFD: Int32) {
        removeTemporaryFiles(directoryFD: directoryFD)
        var saved: [Saved] = []
        for name in ownNames() {
            if let record = read(name: name, directoryFD: directoryFD) { saved.append(Saved(name: name, record: record)) }
            else { _ = unlinkat(directoryFD, name, 0) }
        }
        saved.sort { $0.record.accessedAt > $1.record.accessedAt }
        var shards = 0, shardBytes = 0, indices = 0, indexBytes = 0
        for item in saved {
            let keep: Bool
            if item.record.kind == .index {
                keep = indices < 4 && indexBytes + item.record.entry.data.count <= Self.maximumIndexBytes
                if keep { indices += 1; indexBytes += item.record.entry.data.count }
            } else {
                keep = shards < Self.maximumShardEntries && shardBytes + item.record.entry.data.count <= Self.maximumShardBytes
                if keep { shards += 1; shardBytes += item.record.entry.data.count }
            }
            if !keep { _ = unlinkat(directoryFD, item.name, 0) }
        }
    }
}
