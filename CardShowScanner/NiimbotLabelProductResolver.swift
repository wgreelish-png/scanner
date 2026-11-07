import Foundation

enum NiimbotLabelProductResolverFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidCode, invalidResponse, responseTooLarge, serverRejected, invalidProduct, tooManyRequests

    var errorDescription: String? {
        "The roll measurements could not be retrieved. Choose the paper size manually."
    }
}

/// Resolve only non-unique stock codes. The cache retains validated geometry,
/// never RFID identifiers, roll serials, counters, images or server responses.
@MainActor final class NiimbotLabelProductResolver {
    typealias Load = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void

    static let shared = NiimbotLabelProductResolver()
    static let maximumResponseBytes = 256 * 1_024
    static let maximumCachedProducts = 256
    static let maximumCacheBytes = 512 * 1_024
    static let maximumConcurrentLookups = 4
    private static let endpoint = URL(string: "https://print.niimbot.com/api/template/getCloudTemplateByOneCode")!

    private let catalog: NiimbotLabelCatalog
    private let cacheURL: URL
    private let load: Load
    private let write: Writer
    private var cached: [NiimbotLabelProduct] = []
    private var inFlight: [String: Task<NiimbotLabelProduct?, Error>] = [:]

    init(catalog: NiimbotLabelCatalog = .shared, cacheURL: URL? = nil,
         load: Load? = nil, read: Reader? = nil, write: Writer? = nil) {
        self.catalog = catalog
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.load = load ?? Self.loadResponse
        self.write = write ?? Self.writeCache
        do {
            if let data = try (read ?? Self.readCache)(self.cacheURL) {
                guard data.count <= Self.maximumCacheBytes else { return }
                let document = try JSONDecoder().decode(CacheDocument.self, from: data)
                guard document.version == 1, document.products.count <= Self.maximumCachedProducts,
                      Set(document.products.map(\.code)).count == document.products.count,
                      document.products.allSatisfy(Self.hasPrintableGeometry) else { return }
                cached = document.products.filter { catalog.product(code: $0.code) == nil }
            }
        } catch { /* A corrupt optional cache never changes the bundled catalog. */ }
    }

    func product(code: String) -> NiimbotLabelProduct? {
        guard Self.validCode(code) else { return nil }
        return catalog.product(code: code) ?? cached.first { $0.code == code }
    }

    func resolve(code: String) async throws -> NiimbotLabelProduct? {
        guard Self.validCode(code) else { throw NiimbotLabelProductResolverFailure.invalidCode }
        if let known = product(code: code) { return known }
        if let task = inFlight[code] { return try await task.value }
        guard inFlight.count < Self.maximumConcurrentLookups else { throw NiimbotLabelProductResolverFailure.tooManyRequests }
        // Shared metadata may finish caching after one caller disconnects. Its
        // caller must fence publication to the active printer connection.
        let task = Task<NiimbotLabelProduct?, Error> { [self] in
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("AppVersionName/999.0.0", forHTTPHeaderField: "niimbot-user-agent")
            request.httpBody = try JSONEncoder().encode(["oneCode": code])
            let (data, response) = try await load(request)
            try Self.validate(response)
            guard data.count <= Self.maximumResponseBytes else { throw NiimbotLabelProductResolverFailure.responseTooLarge }
            let envelope: Response
            do { envelope = try JSONDecoder().decode(Response.self, from: data) }
            catch let failure as NiimbotLabelProductResolverFailure { throw failure }
            catch { throw NiimbotLabelProductResolverFailure.invalidResponse }
            guard let remote = envelope.data else { return nil }
            let product = try remote.product(requestedCode: code)
            remember(product)
            return product
        }
        inFlight[code] = task
        defer { inFlight[code] = nil }
        return try await task.value
    }

    private func remember(_ product: NiimbotLabelProduct) {
        var next = cached.filter { $0.code != product.code }
        next.append(product)
        if next.count > Self.maximumCachedProducts { next.removeFirst(next.count - Self.maximumCachedProducts) }
        guard var data = try? JSONEncoder().encode(CacheDocument(products: next)) else { return }
        while data.count > Self.maximumCacheBytes, next.count > 1 {
            next.removeFirst()
            guard let reduced = try? JSONEncoder().encode(CacheDocument(products: next)) else { return }
            data = reduced
        }
        guard data.count <= Self.maximumCacheBytes else { return }
        // Geometry remains usable for this session if optional cache storage is
        // unavailable. Atomic writing preserves the previous offline cache.
        try? write(data, cacheURL)
        cached = next
    }

    private static func validCode(_ code: String) -> Bool {
        (1...32).contains(code.utf8.count) && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    private nonisolated static func hasPrintableGeometry(_ product: NiimbotLabelProduct) -> Bool {
        !product.inputAreas.isEmpty && !product.geometry.usesFallbackArea
            && product.geometry.printableArea.width >= 24 && product.geometry.printableArea.height >= 16
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        guard response.statusCode == 200, let url = response.url,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == Self.endpoint.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.path == Self.endpoint.path, url.query == nil, url.fragment == nil else {
            throw NiimbotLabelProductResolverFailure.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw NiimbotLabelProductResolverFailure.responseTooLarge
        }
    }

    private static func loadResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NiimbotLabelProductResolverFailure.invalidResponse }
        try validate(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw NiimbotLabelProductResolverFailure.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private struct Response: Decodable {
        let data: CloudProduct?
        private enum CodingKeys: String, CodingKey { case code, statusCode = "status_code", data }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard try values.decode(Int.self, forKey: .code) == 1,
                  try values.decode(Int.self, forKey: .statusCode) == 1 else {
                throw NiimbotLabelProductResolverFailure.serverRejected
            }
            do { data = try values.decodeIfPresent(CloudProduct.self, forKey: .data) }
            catch { throw NiimbotLabelProductResolverFailure.invalidProduct }
        }
    }

    private struct CloudProduct: Decodable {
        let barcode: String
        let width: Double
        let height: Double
        let rotate: Int
        let paperType: UInt8
        let isCable: Bool
        let margin: [Double]?
        let profile: Profile
        let inputAreas: [Area]

        struct Profile: Decodable { let isMultiRegionLabel: Bool }
        struct Area: Decodable { let type: String; let x: Double; let y: Double; let w: Double; let h: Double }

        func product(requestedCode: String) throws -> NiimbotLabelProduct {
            guard barcode == requestedCode, margin == nil || margin == [0, 0, 0, 0],
                  (1...16).contains(inputAreas.count), inputAreas.allSatisfy({ $0.type == "text" }) else {
                throw NiimbotLabelProductResolverFailure.invalidProduct
            }
            do {
                let product = try NiimbotLabelProduct(code: barcode, width: width, height: height, rotation: rotate,
                    paperType: paperType, flags: (isCable ? 1 : 0) | (profile.isMultiRegionLabel ? 2 : 0),
                    inputAreas: inputAreas.map { NiimbotLabelArea(x: $0.x, y: $0.y, width: $0.w, height: $0.h) })
                guard NiimbotLabelProductResolver.hasPrintableGeometry(product) else {
                    throw NiimbotLabelProductResolverFailure.invalidProduct
                }
                return product
            } catch { throw NiimbotLabelProductResolverFailure.invalidProduct }
        }
    }

    private struct CacheDocument: Codable {
        var version = 1
        let products: [NiimbotLabelProduct]
    }

    private static var defaultCacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("CardShowScanner", isDirectory: true)
            .appendingPathComponent("NiimbotLabelProducts.json")
    }

    private static func readCache(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.int64Value <= Int64(maximumCacheBytes) else { throw NiimbotLabelProductResolverFailure.responseTooLarge }
        return try Data(contentsOf: url)
    }

    private static func writeCache(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
