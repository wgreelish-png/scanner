import Foundation
import CoreFoundation

protocol OpenAPISetResolving: Sendable {
    func setID(for card: CardCandidate) async throws -> Int?
}

/// The native v2 recognition manifest supplies group IDs; the card's display
/// name, set and collector number do not establish an OpenAPI product identity.
/// This reader never opens the scanner, accesses website storage or downloads data.
actor NativeOpenAPISetResolver: OpenAPISetResolving {
    static let shared = NativeOpenAPISetResolver()

    private struct Shard: Sendable {
        var key: String
        var groupID: Int
        var names: Set<String>
    }
    private struct Source: Sendable {
        var path: String
        var manifest: Data
        var shards: [Shard]
    }
    private struct Index: Sendable {
        var path: String
        var manifest: Data
        // Zero marks a product occurring under conflicting group IDs.
        var groups: [String: Int]
    }
    private let cache: ScannerDatabaseCache
    private var indexes: [String: Index] = [:]
    private static let maximumProducts = 500_000
    private static let maximumManifestBytes = 4 * 1024 * 1024

    init(cache: ScannerDatabaseCache = .shared) { self.cache = cache }

    /// Nil means no trustworthy native v2 mapping is available. In particular,
    /// legacy v1 packs have no group IDs and must not be inferred from set names.
    func setID(for card: CardCandidate) async throws -> Int? {
        try Task.checkCancellation()
        guard let game = Self.gameKey(card.identity.game), Self.validProduct(card.identity.productID) else { return nil }
        do {
            let available = try await source(for: game)
            try Task.checkCancellation()
            guard let source = available else { indexes[game] = nil; return nil }
            let index: Index
            if let saved = indexes[game], saved.path == source.path, saved.manifest == source.manifest {
                index = saved
            } else {
                let loaded = try await load(source, preferredSet: card.set)
                try Task.checkCancellation()
                guard let groups = loaded else { indexes[game] = nil; return nil }
                // An update or clear during the suspended reads retires this load.
                guard let current = try await self.source(for: game), current.path == source.path,
                      current.manifest == source.manifest else { indexes[game] = nil; return nil }
                index = Index(path: source.path, manifest: source.manifest, groups: groups)
                indexes[game] = index
            }
            let current = try await cache.read("cur:" + game)
            try Task.checkCancellation()
            guard let current, current.count <= 1024,
                  (try Self.json(current) as? String) == source.path else { indexes[game] = nil; return nil }
            return index.groups[card.identity.productID].flatMap { $0 > 0 ? $0 : nil }
        } catch {
            indexes[game] = nil
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return nil
        }
    }

    private func source(for game: String) async throws -> Source? {
        try Task.checkCancellation()
        // cur is published only after the native v2 pack is complete. An index
        // entry alone can describe a remote pack which has not been downloaded.
        guard let marker = try await cache.read("cur:" + game), marker.count <= 1024,
              let path = try Self.json(marker) as? String, Self.validPath(path),
              ScannerDatabaseCache.validKey("M:" + path),
              let data = try await cache.read("M:" + path), data.count <= Self.maximumManifestBytes,
              let manifest = try Self.json(data) as? [String: Any], Self.integer(manifest["v"]) == 2,
              let rows = manifest["shards"] as? [[String: Any]], !rows.isEmpty,
              rows.count <= ScannerDatabaseCache.maximumKeys / 2 else { return nil }
        try Task.checkCancellation()
        let directory = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
        var shards: [Shard] = []
        for row in rows {
            try Task.checkCancellation()
            guard let group = Self.integer(row["group_id"]), group > 0,
                  let file = row["meta"] as? String,
                  file.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$"#, options: .regularExpression) != nil,
                  !file.contains(".."), ScannerDatabaseCache.validKey("m:" + directory + file) else { return nil }
            var names: Set<String> = []
            for field in ["name", "abbr"] {
                if let value = row[field] {
                    guard let value = value as? String, value.count <= 1000 else { return nil }
                    let name = Self.normalize(value)
                    if !name.isEmpty { names.insert(name) }
                }
            }
            shards.append(Shard(key: "m:" + directory + file, groupID: group, names: names))
        }
        return Source(path: path, manifest: data, shards: shards)
    }

    private func load(_ source: Source, preferredSet: String) async throws -> [String: Int]? {
        let preferred = Self.normalize(String(preferredSet.prefix(1000)))
        let ordered = source.shards.filter { $0.names.contains(preferred) }
            + source.shards.filter { !$0.names.contains(preferred) }
        var groups: [String: Int] = [:]
        var totalBytes = 0, totalRows = 0
        // Read the named set first, but verify every other shard as well: the
        // same exact product under a different group must fail closed.
        for shard in ordered {
            try Task.checkCancellation()
            guard let data = try await cache.read(shard.key) else { return nil }
            totalBytes += data.count
            guard totalBytes <= ScannerDatabaseCache.maximumTotalBytes,
                  let metadata = try Self.json(data) as? [String: Any],
                  let refs = metadata["refs"] as? [Any], refs.count <= Self.maximumProducts else { return nil }
            totalRows += refs.count
            guard totalRows <= Self.maximumProducts else { return nil }
            for (offset, row) in refs.enumerated() {
                if offset % 256 == 0 { try Task.checkCancellation() }
                guard let tuple = row as? [Any], tuple.count >= 5, let ref = tuple[0] as? String,
                      ref.utf8.count <= 20 else { return nil }
                guard Self.validProduct(ref) else { continue }
                if let old = groups[ref], old != shard.groupID { groups[ref] = 0 }
                else { groups[ref] = shard.groupID }
            }
        }
        return groups
    }

    private static func json(_ data: Data) throws -> Any? {
        guard data.count <= ScannerDatabaseCache.maximumEntryBytes, data.first == 0 else { return nil }
        return try JSONSerialization.jsonObject(with: Data(data.dropFirst()), options: [.fragmentsAllowed])
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let value = Int(number.stringValue) else { return nil }
        return value
    }
    private static func validProduct(_ value: String) -> Bool {
        value.range(of: #"^p:[0-9]{1,12}$"#, options: .regularExpression) != nil
            && Int(value.dropFirst(2)).map { $0 > 0 } == true
    }
    private static func validPath(_ value: String) -> Bool {
        value.utf8.count <= 450 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
    private static func gameKey(_ game: String) -> String? {
        switch game {
        case "Pokémon": return "tcgp:3"
        case "Magic: The Gathering": return "tcgp:1"
        case "Yu-Gi-Oh!": return "tcgp:2"
        default: return nil
        }
    }
}
