import Foundation

struct OpenAPIProductMetadata: Codable, Equatable, Sendable {
    var productID: Int
    var categoryID: Int
    var groupID: Int
    var name: String
    var setName: String
    var number: String?
    var imageURL: URL?
}

protocol OpenAPIProductLookingUp: Sendable {
    func product(for productID: String, categoryID: Int) async throws -> OpenAPIProductMetadata
}

/// The product endpoint recovers metadata only. Aggregate and product-level
/// prices in its response never become a condition-specific market quote.
actor OpenAPIProductLookup: OpenAPIProductLookingUp {
    static let shared = OpenAPIProductLookup()
    static let maximumEntries = 128
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static var defaultDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("PublicOpenAPIProducts", isDirectory: true)
    }
    private struct Entry: Codable {
        var metadata: OpenAPIProductMetadata
        var fetchedAt: Date
    }
    private let loader: any OpenAPIHTTPDataLoading
    private let now: @Sendable () -> Date
    private let directory: URL?
    private var entries: [String: Entry] = [:]
    private let files = FileManager.default
    private static let maximumEntryBytes = 16 * 1_024
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    init(loader: any OpenAPIHTTPDataLoading = NativeOpenAPIHTTPDataLoader(),
         now: @escaping @Sendable () -> Date = { Date() },
         cacheDirectory: URL? = OpenAPIProductLookup.defaultDirectory) {
        self.loader = loader; self.now = now; self.directory = cacheDirectory
    }

    func product(for productID: String, categoryID: Int) async throws -> OpenAPIProductMetadata {
        try Task.checkCancellation()
        guard let id = Self.productID(productID), [1, 2, 3].contains(categoryID) else { throw OpenAPIPricingFailure.unsupportedCard }
        let key = Self.key(id, categoryID), current = now()
        let saved = entries[key] ?? read(key: key, now: current)
        if let saved, saved.fetchedAt <= current, current < saved.fetchedAt.addingTimeInterval(Self.lifetime) {
            retain(saved, key: key)
            return saved.metadata
        }
        let url = URL(string: "https://openapi.tcgtracking.com/v1/products/\(id)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await loader.data(for: request)
            try Task.checkCancellation()
            guard response.url == url else { throw OpenAPIPricingFailure.invalidResponse }
            guard response.statusCode == 200 else { throw OpenAPIPricingFailure.httpStatus(response.statusCode) }
            let metadata = try Self.parse(data, productID: productID, categoryID: categoryID)
            let entry = Entry(metadata: metadata, fetchedAt: now())
            retain(entry, key: key)
            store(entry, key: key)
            return metadata
        } catch {
            try Task.checkCancellation()
            if OpenAPIConnectivityFailure.allowsOfflineFallback(error), let saved,
               saved.fetchedAt <= now(), Self.valid(saved.metadata, productID: id, categoryID: categoryID) {
                return saved.metadata
            }
            throw error
        }
    }

    static func parse(_ data: Data, productID: String, categoryID: Int) throws -> OpenAPIProductMetadata {
        guard data.count <= maximumResponseBytes else { throw OpenAPIPricingFailure.responseTooLarge }
        guard let id = Self.productID(productID), [1, 2, 3].contains(categoryID),
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.success,
              reply.product_id == id, reply.product.product_id == id,
              reply.product.category_id == categoryID else { throw OpenAPIPricingFailure.invalidResponse }
        let product = reply.product
        let metadata = OpenAPIProductMetadata(productID: id, categoryID: categoryID, groupID: product.group_id,
            name: product.name, setName: product.set_name, number: product.ext_number,
            imageURL: product.image_url.flatMap(Self.imageURL))
        guard valid(metadata, productID: id, categoryID: categoryID) else { throw OpenAPIPricingFailure.invalidResponse }
        return metadata
    }

    private struct Reply: Decodable {
        var success: Bool
        var product_id: Int
        var product: Product
    }
    private struct Product: Decodable {
        var product_id: Int; var category_id: Int; var group_id: Int
        var name: String; var set_name: String
        var ext_number: String?; var image_url: String?
    }
    private static func productID(_ text: String) -> Int? {
        guard (1...12).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), value > 0 else { return nil }
        return value
    }
    private static func key(_ product: Int, _ category: Int) -> String { "\(category)-\(product)" }
    private static func valid(_ metadata: OpenAPIProductMetadata, productID: Int, categoryID: Int) -> Bool {
        metadata.productID == productID && metadata.categoryID == categoryID && metadata.groupID > 0 &&
            !metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && metadata.name.count <= 1_000 &&
            !metadata.setName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && metadata.setName.count <= 1_000 &&
            (metadata.number.map { $0.count <= 100 } ?? true) &&
            (metadata.imageURL.map { imageURL($0.absoluteString) != nil } ?? true)
    }
    private static func imageURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["tcgplayer-cdn.tcgplayer.com", "product-images.tcgplayer.com", "cdn.tcgtracking.com"].contains(url.host ?? "") else { return nil }
        return url
    }
    private func retain(_ entry: Entry, key: String) {
        if entries[key] == nil, entries.count >= Self.maximumEntries,
           let oldest = entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key { entries[oldest] = nil }
        entries[key] = entry
    }
    private func read(key: String, now: Date) -> Entry? {
        guard let directory else { return nil }
        let file = directory.appendingPathComponent(key + ".json")
        return read(file: file, now: now)
    }
    private func read(file: URL, now: Date) -> Entry? {
        let components = file.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard components.count == 2, let category = Int(components[0]), [1, 2, 3].contains(category),
              let product = Self.productID(String(components[1])),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumEntryBytes,
              let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.fetchedAt.timeIntervalSince1970.isFinite, entry.fetchedAt <= now,
              Self.valid(entry.metadata, productID: product, categoryID: category) else {
            try? files.removeItem(at: file)
            return nil
        }
        return entry
    }
    private func store(_ entry: Entry, key: String) {
        guard !Task.isCancelled, let directory, let data = try? JSONEncoder().encode(entry), data.count <= Self.maximumEntryBytes else { return }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
            let contents = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let saved = contents.compactMap { file -> (URL, Entry)? in
                guard file.pathExtension == "json", let record = read(file: file, now: entry.fetchedAt) else {
                    try? files.removeItem(at: file); return nil
                }
                return (file, record)
            }.sorted { $0.1.fetchedAt > $1.1.fetchedAt }
            for record in saved.dropFirst(Self.maximumEntries) { try? files.removeItem(at: record.0) }
        } catch { /* Metadata storage failures do not invalidate a verified response. */ }
    }
}

/// The native catalog stays the preferred, offline-only authority. Only a
/// missing mapping triggers an exact public product-ID metadata lookup.
struct CatalogOpenAPISetResolver: OpenAPISetResolving {
    static let shared = CatalogOpenAPISetResolver()
    private let local: any OpenAPISetResolving
    private let lookup: any OpenAPIProductLookingUp
    init(local: any OpenAPISetResolving = NativeOpenAPISetResolver.shared,
         lookup: any OpenAPIProductLookingUp = OpenAPIProductLookup.shared) {
        self.local = local; self.lookup = lookup
    }
    func setID(for card: CardCandidate) async throws -> Int? {
        try Task.checkCancellation()
        guard let product = OpenAPIMarketPricing.productID(card.identity.productID),
              let id = Int(product), id > 0,
              let category = OpenAPIMarketPricing.categoryID(card.identity.game) else { return nil }
        if let set = try await local.setID(for: card) {
            try Task.checkCancellation()
            return set > 0 ? set : nil
        }
        let metadata = try await lookup.product(for: product, categoryID: category)
        try Task.checkCancellation()
        guard metadata.productID == id, metadata.categoryID == category, metadata.groupID > 0 else {
            throw OpenAPIPricingFailure.invalidResponse
        }
        return metadata.groupID
    }
}
