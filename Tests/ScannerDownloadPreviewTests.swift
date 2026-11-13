import Foundation
import XCTest
@testable import CardShowScanner

final class ScannerDownloadPreviewTests: XCTestCase {
    private let path = "pokemon/manifest.json.gz"
    private let key = "tcgp:3"
    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }
    private func manifest(_ shards: [[String: Any]]? = nil) throws -> Data {
        try json(["v": 2, "game": key, "shards": shards ?? [["hash": "h1", "meta": "m1", "bytes": 100, "meta_bytes": 20]]])
    }
    private func index(_ path: String? = nil) throws -> Data {
        try json(["games": [key: ["v2": ["manifest": path ?? self.path]]]])
    }
    private func tagged(_ data: Data) -> Data { var value = Data([0]); value.append(data); return value }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func stage(_ cache: ScannerDatabaseCache, complete: Bool) async throws {
        try await cache.write("index", data: tagged(index()))
        try await cache.write("cur:" + key, data: tagged(json(path)))
        try await cache.write("M:" + path, data: tagged(manifest()))
        var binary = Data([1]); binary.append(Data(count: 100))
        try await cache.write("h:pokemon/h1", data: binary)
        if complete { try await cache.write("m:pokemon/m1", data: tagged(json(["k": 0, "refs": []]))) }
    }

    func testColdV2PlanSeparatesCompressedTransferFromKnownInstalledMinimum() throws {
        let plan = try ScannerDownloadPreviewService.v2Plan(manifest(), path: path, gameKey: key,
            sizes: [:], available: 1_000_000, cached: false)
        XCTAssertEqual(plan.downloadBytes, 120)
        // Metadata's compressed20B is deliberately not presented as its decoded
        // disk size. Only binary100B and the two native record headers are known.
        let expected = 100 + "h:pokemon/h1".utf8.count + 5 + "m:pokemon/m1".utf8.count + 5
        XCTAssertEqual(plan.minimumAdditionalStorageBytes, Int64(expected))
        XCTAssertFalse(plan.additionalStorageIsExact)
        XCTAssertEqual(plan.missingFiles, 2)
        XCTAssertEqual(plan.totalFiles, 2)
        XCTAssertEqual(plan.cachedBytes, 0)
        XCTAssertEqual(plan.availableStorageBytes, 1_000_000)
    }

    func testPartialCacheDeductsOnlyUsableMatchingRecords() throws {
        let hashSize = 100 + "h:pokemon/h1".utf8.count + 5
        let plan = try ScannerDownloadPreviewService.v2Plan(manifest(), path: path, gameKey: key,
            sizes: ["h:pokemon/h1": hashSize, "M:" + path: 80, "other-game": 99_999], available: nil, cached: false)
        XCTAssertEqual(plan.downloadBytes, 20)
        XCTAssertEqual(plan.cachedBytes, Int64(hashSize + 80))
        XCTAssertEqual(plan.missingFiles, 1)
        XCTAssertFalse(plan.additionalStorageIsExact)
        let corruptHash = try ScannerDownloadPreviewService.v2Plan(manifest(), path: path, gameKey: key,
            sizes: ["h:pokemon/h1": hashSize - 1], available: nil, cached: false)
        XCTAssertEqual(corruptHash.downloadBytes, 120, "A truncated binary cannot reduce the size forecast")
    }

    func testCompleteSavedDatabaseRequiresNoNetworkAndPreviewDoesNotMutateCache() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage(cache, complete: true)
        let original = try await cache.recordSizes()
        let calls = ScannerPreviewCalls()
        let service = ScannerDownloadPreviewService(cache: cache, loader: { url, _ in
            await calls.record(url); throw ScannerDownloadPreviewFailure.unavailable
        })
        let plan = try await service.preview(game: "Pokémon", preferSaved: true)
        XCTAssertEqual(plan.downloadBytes, 0)
        XCTAssertEqual(plan.minimumAdditionalStorageBytes, 0)
        XCTAssertTrue(plan.additionalStorageIsExact)
        XCTAssertEqual(plan.missingFiles, 0)
        XCTAssertTrue(plan.isUsingCachedMetadata)
        let requests = await calls.urls
        XCTAssertTrue(requests.isEmpty)
        let after = try await cache.recordSizes()
        XCTAssertEqual(after, original)
    }

    func testFreshPreviewRequestsOnlyBoundedIndexAndManifestAndDoesNotSaveThem() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        let indexData = try index(), manifestData = try manifest()
        let calls = ScannerPreviewCalls()
        let service = ScannerDownloadPreviewService(cache: cache, loader: { url, cap in
            await calls.record(url)
            XCTAssertEqual(cap, 1_048_576)
            return url.lastPathComponent == "index.json" ? indexData : manifestData
        })
        let plan = try await service.preview(game: "Pokémon")
        XCTAssertEqual(plan.downloadBytes, 120)
        XCTAssertFalse(plan.isUsingCachedMetadata)
        let urls = await calls.urls
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://nsp-static.tcgtracking.com/packs/index.json",
            "https://nsp-static.tcgtracking.com/packs/" + path])
        let keys = try await cache.keys()
        XCTAssertTrue(keys.isEmpty, "Opening a size preview does not stage or activate a download")
    }

    func testOfflinePreviewUsesSavedPartialMetadataWithoutTreatingItAsComplete() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage(cache, complete: false)
        let service = ScannerDownloadPreviewService(cache: cache, loader: { _, _ in throw ScannerDownloadPreviewFailure.unavailable })
        let plan = try await service.preview(game: "Pokémon", preferSaved: true)
        XCTAssertEqual(plan.downloadBytes, 20)
        XCTAssertEqual(plan.missingFiles, 1)
        XCTAssertTrue(plan.isUsingCachedMetadata)
        XCTAssertFalse(plan.additionalStorageIsExact)
    }

    func testCancellationDoesNotFallBackToSavedMetadata() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage(cache, complete: false)
        let calls = ScannerPreviewCalls()
        let service = ScannerDownloadPreviewService(cache: cache, loader: { url, _ in
            await calls.record(url)
            try await Task.sleep(for: .seconds(60))
            throw ScannerDownloadPreviewFailure.unavailable
        })
        let work = Task { try await service.preview(game: "Pokémon") }
        for _ in 0..<200 {
            if !(await calls.urls).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let urls = await calls.urls
        XCTAssertFalse(urls.isEmpty, "Cancel during the active metadata request")
        work.cancel()
        do { _ = try await work.value; XCTFail("A cancelled request returned a stale preview") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMalformedUnboundedAndCrossGameMetadataIsRejected() throws {
        for path in ["../manifest.json", "/manifest.json", "https://example.com/x", "a//x", "a/%2e/x", "a/./x", "a/x?token=1"] {
            XCTAssertThrowsError(try ScannerDownloadPreviewService.v2Plan(manifest(), path: path, gameKey: key,
                sizes: [:], available: nil, cached: false))
        }
        let invalidSizes: [Any] = [true, -1, 1.5, 33_554_433, "100"]
        for bad in invalidSizes {
            let invalid = try manifest([["hash": "h1", "meta": "m1", "bytes": bad, "meta_bytes": 20]])
            XCTAssertThrowsError(try ScannerDownloadPreviewService.v2Plan(invalid, path: path, gameKey: key,
                sizes: [:], available: nil, cached: false))
        }
        let invalids: [[String: Any]] = [
            ["v": 2, "game": "tcgp:1", "shards": [["hash": "h", "meta": "m", "bytes": 10, "meta_bytes": 10]]],
            ["v": true, "shards": []], ["v": 2, "shards": []]
        ]
        for value in invalids {
            XCTAssertThrowsError(try ScannerDownloadPreviewService.v2Plan(json(value), path: path, gameKey: key,
                sizes: [:], available: nil, cached: false))
        }
    }

    func testLegacyPackUsesVersionedCacheAndKeepsMetadataExpansionUnknown() throws {
        let entry: [String: Any] = ["ver": 7, "bin": "legacy.bin", "meta": "legacy.json.gz", "bin_bytes": 100, "meta_bytes": 20]
        let cold = try ScannerDownloadPreviewService.legacyPlan(entry, gameKey: key, sizes: [:], available: nil, cached: false)
        XCTAssertEqual(cold.downloadBytes, 120)
        XCTAssertEqual(cold.missingFiles, 2)
        XCTAssertFalse(cold.additionalStorageIsExact)
        XCTAssertEqual(cold.minimumAdditionalStorageBytes, Int64((key + "@7").utf8.count + 9),
                       "Legacy binaries can be compressed, so their transfer size is not an installed lower bound")
        let complete = try ScannerDownloadPreviewService.legacyPlan(entry, gameKey: key,
            sizes: [key + "@7": 500, key + "@6": 999], available: nil, cached: true)
        XCTAssertEqual(complete.downloadBytes, 0)
        XCTAssertEqual(complete.cachedBytes, 500)
        XCTAssertTrue(complete.additionalStorageIsExact)
    }

    func testGzipMetadataIsDecodedAndTruncatedOrOversizedInputsFail() throws {
        let base64 = "H4sIAAAAAAACA6tWKlOyMtJRSk/MTVWyUipJTi+wMlbSUSrOSCxKKVayiq5WykgszgBKZRgChXNTSxKB7FwQO6myJBWowtDAACIeDxUwMqiNrQUAqC70UFgAAAA="
        let compressed = try XCTUnwrap(Data(base64Encoded: base64))
        let decoded = try ScannerDownloadPreviewService.decodeMetadata(compressed)
        let plan = try ScannerDownloadPreviewService.v2Plan(decoded, path: path, gameKey: key,
            sizes: [:], available: nil, cached: false)
        XCTAssertEqual(plan.downloadBytes, 120)
        XCTAssertThrowsError(try ScannerDownloadPreviewService.decodeMetadata(Data(compressed.dropLast())))
        XCTAssertThrowsError(try ScannerDownloadPreviewService.decodeMetadata(Data(repeating: 0, count: 1_048_577)))
    }
}

private actor ScannerPreviewCalls {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}
