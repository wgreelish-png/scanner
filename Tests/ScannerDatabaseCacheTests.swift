import XCTest
@testable import CardShowScanner

@MainActor final class ScannerDatabaseCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testNativeDatabaseSurvivesReopeningAndAtomicReplacement() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ScannerDatabaseCache(directory: directory)
        let binary = Data([1, 0, 1, 2, 255])
        try await writer.write("h:pokemon/hash-a", data: binary)
        try await writer.write("M:pokemon/manifest-a.json", data: Data("manifest".utf8))
        try await writer.write("cur:tcgp:3", data: Data("complete".utf8))
        let reopened = ScannerDatabaseCache(directory: directory)
        let saved = try await reopened.read("h:pokemon/hash-a")
        XCTAssertEqual(saved, binary)
        let keys = try await reopened.keys()
        XCTAssertEqual(Set(keys), Set(["h:pokemon/hash-a", "M:pokemon/manifest-a.json", "cur:tcgp:3"]))
        try await reopened.write("h:pokemon/hash-a", data: Data([1, 9]))
        let updated = ScannerDatabaseCache(directory: directory)
        let replacement = try await updated.read("h:pokemon/hash-a")
        XCTAssertEqual(replacement, Data([1, 9]))
        let attributes = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(attributes.isExcludedFromBackup, true)
    }
    func testClearOnlyRemovesDedicatedDatabaseStorage() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("saved-user-data")
        try Data("keep lists".utf8).write(to: sentinel)
        let root = parent.appendingPathComponent("ScannerDatabase-v1", isDirectory: true)
        let cache = ScannerDatabaseCache(directory: root)
        try await cache.write("index", data: Data([0, 1]))
        try await cache.clear()
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep lists".utf8))
        let reopened = ScannerDatabaseCache(directory: root)
        let keys = try await reopened.keys()
        XCTAssertTrue(keys.isEmpty)
    }
    func testKeysCannotEscapeStorageAndEntrySizeIsBounded() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ScannerDatabaseCache(directory: directory)
        for key in ["../default.store", "/etc/passwd", "h:../../outside", "index\0tail", "https://example.com", String(repeating: "h", count: 600)] {
            XCTAssertFalse(ScannerDatabaseCache.validKey(key))
            do { try await cache.write(key, data: Data([1])); XCTFail("Unsafe key accepted") }
            catch { XCTAssertTrue(error is ScannerCacheFailure) }
        }
        do {
            try await cache.write("index", data: Data(count: ScannerDatabaseCache.maximumEntryBytes + 1))
            XCTFail("Oversized entry accepted")
        } catch { XCTAssertTrue(error is ScannerCacheFailure) }
        let keys = try await cache.keys()
        XCTAssertTrue(keys.isEmpty)
    }
    func testCorruptFilesAndSymlinksCannotReturnUnrelatedData() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("cache", isDirectory: true)
        let cache = ScannerDatabaseCache(directory: root)
        try await cache.write("index", data: Data([0, 1]))
        let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data([255, 255]).write(to: record)
        do { _ = try await cache.read("index"); XCTFail("Corruption was returned") }
        catch { XCTAssertTrue(error is ScannerCacheFailure) }
        try FileManager.default.removeItem(at: record)
        let secret = parent.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: secret)
        do { _ = try await cache.read("index"); XCTFail("Symlink was followed") }
        catch { XCTAssertTrue(error is ScannerCacheFailure) }
        let reopened = ScannerDatabaseCache(directory: root)
        let keys = try await reopened.keys()
        XCTAssertTrue(keys.isEmpty)
    }
    func testLoopbackCacheRequiresSecretAndRejectsForeignOrigins() {
        let origin = "http://127.0.0.1:18764", token = "test-cache-token"
        let allowed = ["host": "127.0.0.1:18764", "x-scanner-cache": token, "origin": origin]
        XCTAssertTrue(ScannerCacheRequestPolicy.permits(headers: allowed, origin: origin, token: token))
        var missing = allowed; missing.removeValue(forKey: "x-scanner-cache")
        XCTAssertFalse(ScannerCacheRequestPolicy.permits(headers: missing, origin: origin, token: token))
        var foreign = allowed; foreign["origin"] = "https://example.com"
        XCTAssertFalse(ScannerCacheRequestPolicy.permits(headers: foreign, origin: origin, token: token))
        var wrongHost = allowed; wrongHost["host"] = "localhost:18764"
        XCTAssertFalse(ScannerCacheRequestPolicy.permits(headers: wrongHost, origin: origin, token: token))
        var sameOriginGET = allowed; sameOriginGET.removeValue(forKey: "origin")
        XCTAssertTrue(ScannerCacheRequestPolicy.permits(headers: sameOriginGET, origin: origin, token: token))
    }
}
