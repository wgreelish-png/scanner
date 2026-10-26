import Foundation

protocol CardCatalogSearching: Sendable {
    func search(_ query: String, game: String, limit: Int) async throws -> [CardCandidate]
}

enum CardCatalogFailure: LocalizedError {
    case unavailable, incomplete, invalid, unsupportedGame
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The saved catalog for this game is not available yet. Open the scanner once to download it, then return here."
        case .incomplete, .invalid: return "The saved catalog could not be read completely. Use Check Database Updates in the scanner, then retry search."
        case .unsupportedGame: return "Choose a supported game to search."
        }
    }
}

/// Reads the same native metadata cache used by recognition. It never starts a
/// camera, downloads another pack, or treats embedded snapshot prices as quotes.
actor CachedCardCatalog: CardCatalogSearching {
    static let shared = CachedCardCatalog()
    private struct Entry: Sendable {
        var card: CardCandidate
        var name: String
        var number: String
        var text: String
    }
    private struct Index: Sendable { var signature: String; var entries: [Entry] }
    private struct Source: Sendable { var signature: String; var metadataKeys: [String]; var legacy: Bool }
    private let cache: ScannerDatabaseCache
    private var indexes: [String: Index] = [:]
    private var loading: [String: Task<[Entry], Error>] = [:]
    init(cache: ScannerDatabaseCache = .shared) { self.cache = cache }

    func search(_ query: String, game: String, limit: Int = 5) async throws -> [CardCandidate] {
        let key: String
        switch game {
        case "Pokémon": key = "tcgp:3"
        case "Magic: The Gathering": key = "tcgp:1"
        case "Yu-Gi-Oh!": key = "tcgp:2"
        default: throw CardCatalogFailure.unsupportedGame
        }
        let source = try await source(for: key)
        let entries: [Entry]
        if let index = indexes[key], index.signature == source.signature { entries = index.entries }
        else {
            let loadKey = key + "|" + source.signature
            let task: Task<[Entry], Error>
            if let pending = loading[loadKey] { task = pending }
            else {
                let cache = cache
                task = Task { try await Self.load(source, cache: cache, game: game) }
                loading[loadKey] = task
            }
            do {
                entries = try await task.value
                loading[loadKey] = nil
                // Bound resident metadata to the selected game. A changed
                // manifest automatically replaces the old search index.
                indexes = [key: Index(signature: source.signature, entries: entries)]
                try Task.checkCancellation()
            } catch { loading[loadKey] = nil; throw error }
        }
        let tokens = Self.normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let cap = min(5, max(1, limit))
        var best: [(entry: Entry, score: Int)] = []
        for (offset, entry) in entries.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            guard let score = Self.score(entry, tokens: tokens) else { continue }
            best.append((entry, score))
            best.sort {
                if $0.score != $1.score { return $0.score < $1.score }
                let a = $0.entry, b = $1.entry
                if a.name != b.name { return a.name < b.name }
                if a.card.set != b.card.set { return a.card.set < b.card.set }
                if a.number != b.number { return a.number.compare(b.number, options: .numeric) == .orderedAscending }
                return a.card.identity.productID < b.card.identity.productID
            }
            if best.count > cap { best.removeLast() }
        }
        return best.map { $0.entry.card }
    }

    private func source(for game: String) async throws -> Source {
        var path: String?
        if let current = try await cache.read("cur:" + game) { path = try Self.json(current) as? String }
        var entry: [String: Any]?
        if path == nil, let data = try await cache.read("index"),
           let index = try Self.json(data) as? [String: Any], let games = index["games"] as? [String: Any] {
            entry = games[game] as? [String: Any]
            path = (entry?["v2"] as? [String: Any])?["manifest"] as? String
        }
        if let path {
            guard ScannerDatabaseCache.validKey("M:" + path),
                  let data = try await cache.read("M:" + path), let manifest = try Self.json(data) as? [String: Any],
                  manifest["v"] as? Int == 2, let shards = manifest["shards"] as? [[String: Any]],
                  !shards.isEmpty, shards.count <= ScannerDatabaseCache.maximumKeys else { throw CardCatalogFailure.incomplete }
            let directory = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
            let keys = try shards.map { shard -> String in
                guard let file = shard["meta"] as? String else { throw CardCatalogFailure.invalid }
                let key = "m:" + directory + file
                guard ScannerDatabaseCache.validKey(key) else { throw CardCatalogFailure.invalid }
                return key
            }
            return Source(signature: path, metadataKeys: keys, legacy: false)
        }
        if let version = entry?["ver"] {
            let value = (version as? String) ?? (version as? NSNumber)?.stringValue ?? ""
            let key = game + "@" + value
            guard ScannerDatabaseCache.validKey(key) else { throw CardCatalogFailure.invalid }
            return Source(signature: key, metadataKeys: [key], legacy: true)
        }
        indexes[game] = nil
        throw CardCatalogFailure.unavailable
    }

    private static func json(_ data: Data) throws -> Any {
        guard data.first == 0 else { throw CardCatalogFailure.invalid }
        return try JSONSerialization.jsonObject(with: Data(data.dropFirst()), options: [.fragmentsAllowed])
    }
    private static func load(_ source: Source, cache: ScannerDatabaseCache, game: String) async throws -> [Entry] {
        var cards: [String: Entry] = [:]
        for key in source.metadataKeys {
            guard let data = try await cache.read(key) else { throw CardCatalogFailure.incomplete }
            let refs: [Any]
            if source.legacy {
                guard data.count >= 5, data.first == 2 else { throw CardCatalogFailure.invalid }
                let count = data[1..<5].reduce(0) { ($0 << 8) | Int($1) }
                guard count <= data.count - 5,
                      let rows = try JSONSerialization.jsonObject(with: data.subdata(in: 5..<(5 + count))) as? [Any] else { throw CardCatalogFailure.invalid }
                refs = rows
            } else {
                guard let meta = try json(data) as? [String: Any], let rows = meta["refs"] as? [Any] else { throw CardCatalogFailure.invalid }
                refs = rows
            }
            guard refs.count <= 500_000 else { throw CardCatalogFailure.invalid }
            for row in refs {
                guard let tuple = row as? [Any], tuple.count >= 5, let ref = tuple[0] as? String,
                      ref.range(of: #"^(p|t|ts|u):[0-9]{1,12}$"#, options: .regularExpression) != nil,
                      let name = tuple[1] as? String, !name.isEmpty, name.count <= 1000 else { continue }
                func text(_ index: Int) -> String { tuple.indices.contains(index) ? String((tuple[index] as? String ?? "").prefix(1000)) : "" }
                let number = text(2), abbreviation = text(3), set = text(4).isEmpty ? abbreviation : text(4)
                let variants = tuple.indices.contains(7) ? (tuple[7] as? [[String: Any]] ?? []) : []
                let printings = Array(Set(variants.prefix(30).compactMap { $0["label"] as? String }.filter { !$0.isEmpty && $0.count <= 1000 })).sorted()
                let primary = variants.first { $0["primary"] as? Bool == true }?["label"] as? String
                let printing = primary.flatMap { printings.contains($0) ? $0 : nil } ?? printings.first ?? "Normal"
                var image = URL(string: text(6))
                if image?.scheme != "https" || image?.host == nil || image?.user != nil || image?.password != nil { image = nil }
                if image == nil, ref.hasPrefix("p:") { image = URL(string: "https://cdn.tcgtracking.com/product/" + String(ref.dropFirst(2)) + "_400w.jpg") }
                if var old = cards[ref] {
                    old.card.printings = Array(Set(old.card.printings + printings)).sorted()
                    cards[ref] = old
                } else {
                    let card = CardCandidate(identity: CardIdentity(game: game, productID: ref, printing: printing),
                        name: name, set: set, number: number, marketPrice: nil, imageURL: image, confidence: 0, printings: printings)
                    cards[ref] = Entry(card: card, name: normalize(name), number: canonicalNumber(number),
                        text: normalize(name + " " + set + " " + abbreviation + " " + number))
                    guard cards.count <= 500_000 else { throw CardCatalogFailure.invalid }
                }
            }
        }
        guard !cards.isEmpty else { throw CardCatalogFailure.unavailable }
        return Array(cards.values)
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}/]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
    private static func canonicalNumber(_ value: String) -> String {
        normalize(value).replacingOccurrences(of: " ", with: "").split(separator: "/", omittingEmptySubsequences: false)
            .map { Int($0).map(String.init) ?? String($0).replacingOccurrences(of: #"^([a-z]+)0+([0-9]+)$"#, with: "$1$2", options: .regularExpression) }.joined(separator: "/")
    }
    private static func score(_ entry: Entry, tokens: [String]) -> Int? {
        var score = 0
        for token in tokens {
            if token.allSatisfy({ $0.isNumber || $0 == "/" }) {
                let number = canonicalNumber(token)
                guard entry.number.hasPrefix(number) else { return nil }
                score += entry.number.split(separator: "/").first.map(String.init) == number ? 0 : 5
            } else if entry.number.hasPrefix(canonicalNumber(token)) { continue }
            else if entry.name == token { continue }
            else if entry.name.hasPrefix(token) { score += 1 }
            else if entry.name.contains(token) { score += 3 }
            else if entry.text.contains(token) { score += 10 }
            else { return nil }
        }
        return score
    }
}
