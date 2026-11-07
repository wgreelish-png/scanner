import Foundation
import XCTest
import UIKit
@testable import CardShowScanner

@MainActor final class NiimbotLabelProductResolverTests: XCTestCase {
    private let code = "03032380"

    private func metadata() -> [String: Any] {
        ["id": 80000001, "barcode": code,
         "names": [["languageCode": "en", "name": "Vendor display text is not cached"]],
         "width": 30, "height": 12, "rotate": 90, "paperType": 1, "isCable": false,
         "margin": [0, 0, 0, 0], "profile": ["isMultiRegionLabel": false],
         "inputAreas": [["type": "text", "x": 1.0985915499, "y": 0.5034965034,
                          "w": 27.887323959, "h": 10.9930069909]]]
    }

    private func body(_ product: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": 1, "status_code": 1, "data": product])
    }

    private func resolver(_ loader: ProductResolverLoader, _ cache: ProductResolverCache) -> NiimbotLabelProductResolver {
        NiimbotLabelProductResolver(cacheURL: cache.url, load: { try await loader.data(for: $0) },
            read: { try cache.read($0) }, write: { try cache.write($0, to: $1) })
    }

    func testBundledProductsResolveOfflineWithoutMakingAnHTTPCallOrWritingACache() async throws {
        let loader = ProductResolverLoader(body: Data()), cache = ProductResolverCache()
        loader.failure = URLError(.notConnectedToInternet)
        let resolver = resolver(loader, cache)
        for bundled in ["010424790", "120425109"] {
            let expected = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: bundled))
            XCTAssertEqual(resolver.product(code: bundled), expected)
            let resolved = try await resolver.resolve(code: bundled)
            XCTAssertEqual(resolved, expected)
        }
        for invalid in ["PRIVATE_ROLL_SERIAL", "03032380\nPRIVATE", "", String(repeating: "7", count: 33)] {
            do { _ = try await resolver.resolve(code: invalid); XCTFail("Invalid RFID product data cannot enter an HTTP request") }
            catch { XCTAssertEqual(error as? NiimbotLabelProductResolverFailure, .invalidCode) }
        }
        XCTAssertTrue(loader.requests.isEmpty)
        XCTAssertEqual(cache.writes, 0)
    }

    func testUnknownProductUsesOnlyThePublicProductCodeAndPersistsValidatedGeometryForOfflineReopen() async throws {
        let loader = ProductResolverLoader(body: try body(metadata())), cache = ProductResolverCache()
        let resolver = resolver(loader, cache)
        XCTAssertNil(resolver.product(code: code))
        let resolved = try await resolver.resolve(code: code)
        let product = try XCTUnwrap(resolved)
        XCTAssertEqual(product.code, code)
        XCTAssertEqual(product.width, 30); XCTAssertEqual(product.height, 12)
        XCTAssertEqual(product.geometry.feedDots, 240); XCTAssertEqual(product.geometry.headDots, 96)
        XCTAssertEqual(product.geometry.printableArea, .init(x: 9, y: 5, width: 222, height: 86))
        XCTAssertFalse(product.geometry.usesFallbackArea)
        XCTAssertEqual(product.inputAreas[0].width, 27.887323959)
        let info = NiimbotRollInfo(productCode: code, totalLabels: 195, usedLabels: 0, labelType: 1)
        XCTAssertEqual(NiimbotRollDetection.diagnosticFields(info, product: product), [
            "roll_detection_result": "matched", "roll_product_code": code,
            "label_width_mm": "30.0", "label_height_mm": "12.0",
            "label_feed_dots": "240", "label_head_dots": "96"
        ], "API-resolved stock must use the same size detection as bundled stock")
        let paper = try InventoryLabelSize(product: product)
        for position in LabelPricePosition.allCases {
            let draft = CustomPriceTagDraft(priceCents: 400, copies: 1, paperSize: paper, pricePosition: position)
            let bitmap = try InventoryLabelRenderer.render(draft)
            XCTAssertEqual(bitmap.raster.width, 96); XCTAssertEqual(bitmap.raster.height, 240)
            XCTAssertTrue(bitmap.raster.data.contains { $0 != 0 })
            XCTAssertEqual(bitmap.raster, try InventoryLabelRenderer.renderRaster(draft))
            XCTAssertEqual(bitmap.previewImage.cgImage?.width, 240)
            XCTAssertEqual(bitmap.previewImage.cgImage?.height, 96)
        }
        XCTAssertEqual(loader.requests.count, 1)
        let request = try XCTUnwrap(loader.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://print.niimbot.com/api/template/getCloudTemplateByOneCode")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query); XCTAssertNil(request.url?.user); XCTAssertNil(request.url?.fragment)
        let sent = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(sent, ["oneCode": code], "No roll UID, serial or remaining-label counters enter the request")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(cache.writes, 1)
        let cachedText = String(decoding: try XCTUnwrap(cache.bytes), as: UTF8.self)
        XCTAssertFalse(cachedText.contains("Vendor display text"))
        XCTAssertFalse(cachedText.contains("status_code"))
        XCTAssertEqual(resolver.product(code: code), product)
        let again = try await resolver.resolve(code: code)
        XCTAssertEqual(again, product)
        XCTAssertEqual(loader.requests.count, 1)
        let offline = ProductResolverLoader(body: Data())
        offline.failure = URLError(.notConnectedToInternet)
        let reopened = self.resolver(offline, cache)
        let restored = try await reopened.resolve(code: code)
        XCTAssertEqual(restored, product)
        XCTAssertTrue(offline.requests.isEmpty)
        XCTAssertEqual(cache.writes, 1)
    }

    func testConcurrentResolutionOfOneCodeSharesOneRequestAndOneCacheWrite() async throws {
        let loader = ProductResolverLoader(body: try body(metadata())), cache = ProductResolverCache()
        loader.held = true
        let resolver = resolver(loader, cache)
        let first = Task { try await resolver.resolve(code: code) }
        let second = Task { try await resolver.resolve(code: code) }
        defer { first.cancel(); second.cancel(); loader.finish(throwing: CancellationError()) }
        try await loader.waitForRequest()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(loader.requests.count, 1)
        loader.finish()
        let left = try await first.value
        let right = try await second.value
        XCTAssertNotNil(left)
        XCTAssertEqual(left, right)
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertEqual(cache.writes, 1)
    }

    func testMismatchedMalformedOrUnsupportedMetadataCannotBecomeDetectedOrCachedStock() async throws {
        var mismatch = metadata(); mismatch["barcode"] = "03032382"
        var margins = metadata(); margins["margin"] = [1, 0, 0, 0]
        var media = metadata(); media["paperType"] = 2
        var axes = metadata(); axes["rotate"] = 0
        var malformed = metadata(); malformed["width"] = true
        var noArea = metadata(); noArea["inputAreas"] = []
        var tooNarrow = metadata()
        tooNarrow["inputAreas"] = [["type": "text", "x": 1, "y": 1, "w": 1, "h": 2]]
        for product in [mismatch, margins, media, axes, malformed, noArea, tooNarrow] {
            let loader = ProductResolverLoader(body: try body(product)), cache = ProductResolverCache()
            let resolver = resolver(loader, cache)
            do { _ = try await resolver.resolve(code: code); XCTFail("Untrusted geometry must be rejected") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertNil(resolver.product(code: code))
            XCTAssertNil(cache.bytes)
            XCTAssertEqual(cache.writes, 0)
        }
    }

    func testMalformedOversizedAndRejectedResponsesAreNotCached() async throws {
        let valid = try body(metadata())
        let cases: [(Data, Int)] = [
            (Data("{".utf8), 200),
            (Data(repeating: 0x20, count: NiimbotLabelProductResolver.maximumResponseBytes + 1), 200),
            (valid, 503)
        ]
        for (data, status) in cases {
            let loader = ProductResolverLoader(body: data), cache = ProductResolverCache()
            loader.status = status
            let resolver = resolver(loader, cache)
            do { _ = try await resolver.resolve(code: code); XCTFail("The response cannot supply trusted geometry") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertNil(resolver.product(code: code))
            XCTAssertEqual(cache.writes, 0)
        }
    }

    func testMissingAndNullProductDataAreHandledAsNotFoundWithoutInventingMeasurements() async throws {
        let missing: [String: Any] = ["code": 1, "status_code": 1]
        let null: [String: Any] = ["code": 1, "status_code": 1, "data": NSNull()]
        for document in [missing, null] {
            let loader = ProductResolverLoader(body: try JSONSerialization.data(withJSONObject: document))
            let cache = ProductResolverCache(), resolver = resolver(loader, cache)
            let result = try await resolver.resolve(code: code)
            XCTAssertNil(result)
            XCTAssertNil(resolver.product(code: code))
            XCTAssertEqual(cache.writes, 0)
        }
    }

    func testInvalidPersistedProductIsIgnoredWhileBundledStockStillWorksOffline() async throws {
        let loader = ProductResolverLoader(body: try body(metadata())), cache = ProductResolverCache()
        _ = try await resolver(loader, cache).resolve(code: code)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(cache.bytes)) as? [String: Any])
        var products = try XCTUnwrap(document["products"] as? [[String: Any]])
        products[0]["width"] = 200
        document["products"] = products
        cache.bytes = try JSONSerialization.data(withJSONObject: document)
        let corrupted = cache.bytes
        let offline = ProductResolverLoader(body: Data())
        offline.failure = URLError(.notConnectedToInternet)
        let reopened = resolver(offline, cache)
        XCTAssertNil(reopened.product(code: code))
        let bundled = try await reopened.resolve(code: "120425109")
        XCTAssertEqual(bundled, NiimbotLabelCatalog.shared.product(code: "120425109"))
        XCTAssertTrue(offline.requests.isEmpty)
        XCTAssertEqual(cache.bytes, corrupted, "An invalid cache is ignored without rewriting stored bytes")
        XCTAssertEqual(cache.writes, 1)
    }

    func testFailedLookupLeavesRememberedManualPaperAndPricePositionAvailable() async throws {
        let suite = "NiimbotProductResolverManualTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LabelPaperPreferences(defaults: defaults)
        preferences.select(.large50x14); preferences.selectPricePosition(.left)
        let loader = ProductResolverLoader(body: Data()), cache = ProductResolverCache()
        loader.failure = URLError(.notConnectedToInternet)
        let resolver = resolver(loader, cache)
        do { _ = try await resolver.resolve(code: code); XCTFail("The injected network is unavailable") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertNil(resolver.product(code: code))
        XCTAssertEqual(preferences.size, .large50x14)
        XCTAssertEqual(preferences.manualSize, .large50x14)
        XCTAssertEqual(preferences.pricePosition, .left)
        XCTAssertNil(preferences.detectedProduct)
        XCTAssertEqual(cache.writes, 0)
    }
}

@MainActor private final class ProductResolverCache {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    var bytes: Data?
    private(set) var writes = 0
    func read(_ url: URL) throws -> Data? { bytes }
    func write(_ data: Data, to url: URL) throws { bytes = data; writes += 1 }
}

@MainActor private final class ProductResolverLoader {
    var body: Data
    var status = 200
    var failure: Error?
    var held = false
    private(set) var requests: [URLRequest] = []
    private var pending: [(URLRequest, CheckedContinuation<(Data, HTTPURLResponse), Error>)] = []

    init(body: Data) { self.body = body }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        if held { return try await withCheckedThrowingContinuation { pending.append((request, $0)) } }
        return response(for: request)
    }

    private func response(for request: URLRequest) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                              headerFields: ["Content-Type": "application/json"])!)
    }

    func finish(throwing error: Error? = nil) {
        let current = pending; pending.removeAll()
        for (request, continuation) in current {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: response(for: request)) }
        }
    }

    func waitForRequest() async throws {
        for _ in 0..<1_000 {
            if !pending.isEmpty { return }
            await Task.yield()
        }
        XCTFail("The resolver did not reach its injected transport")
        throw URLError(.timedOut)
    }
}
