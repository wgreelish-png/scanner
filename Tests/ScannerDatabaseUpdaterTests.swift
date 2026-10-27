import XCTest
@testable import CardShowScanner

@MainActor final class ScannerDatabaseUpdaterTests: XCTestCase {
    private final class Runner: ScannerDatabaseUpdateRunning {
        var calls: [String] = []
        var cancellations = 0
        var response: ScannerDatabaseUpdateResult?
        var pending: [CheckedContinuation<ScannerDatabaseUpdateResult, Error>] = []
        func run(gameKey: String) async throws -> ScannerDatabaseUpdateResult {
            calls.append(gameKey)
            if let response { return response }
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func cancel() { cancellations += 1 }
        func complete(_ value: ScannerDatabaseUpdateResult) { pending.removeFirst().resume(returning: value) }
    }
    private func preferences() -> (UserDefaults, String) {
        let name = "ScannerDatabaseUpdaterTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func json(_ value: Any) throws -> Data {
        var data = Data([0]); data.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])); return data
    }
    private func stage(_ name: String, in cache: ScannerDatabaseCache, game: String = "tcgp:3", current: Bool = false) async throws {
        let path = "pokemon/" + name + ".json"
        let manifest: [String: Any] = ["v": 2, "shards": [["hash": name + "-hash", "meta": name + "-meta"]]]
        try await cache.write("M:" + path, data: json(manifest))
        var binary = Data([1, 78, 83, 80, 83, 2, 0, 0, 0]); binary.append(Data(count: 16))
        try await cache.write("h:pokemon/" + name + "-hash", data: binary)
        try await cache.write("m:pokemon/" + name + "-meta", data: json(["refs": [], "k": 0]))
        if current { try await cache.write("cur:" + game, data: json(path)) }
    }
    private func result(_ status: ScannerDatabaseUpdateResult.Status = .updated, previous: String = "old", proposed: String = "new") -> ScannerDatabaseUpdateResult {
        ScannerDatabaseUpdateResult(status: status, downloadedBytes: status == .updated ? 123 : 0, cachedShards: 2,
            proposedManifestPath: "pokemon/" + proposed + ".json", previousManifestPath: "pokemon/" + previous + ".json")
    }
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected updater state did not arrive", file: file, line: line)
    }

    func testDailyAndFailureIntervalsAndChangedClock() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: nil, lastFailure: nil, now: date))
        XCTAssertFalse(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: date.addingTimeInterval(-86_399), lastFailure: nil, now: date))
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: date.addingTimeInterval(-86_400), lastFailure: nil, now: date))
        XCTAssertFalse(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: nil, lastFailure: date.addingTimeInterval(-3_599), now: date))
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: nil, lastFailure: date.addingTimeInterval(-3_600), now: date))
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: date.addingTimeInterval(86_400), lastFailure: nil, now: date), "A clock correction must not block checks indefinitely")
    }

    func testWireResultsRejectUnknownStatusInvalidCountsAndUnsafePaths() async throws {
        let valid: [String: Any] = ["status": "updated", "downloadedBytes": 123, "cachedShards": 2,
            "proposedManifestPath": "pokemon/new.json", "previousManifestPath": "pokemon/old.json"]
        XCTAssertEqual(try ScannerDatabaseUpdateResult.decode(valid), result())
        for (key, value) in [("status", "ready" as Any), ("downloadedBytes", -1 as Any),
                             ("downloadedBytes", true as Any), ("cachedShards", 1.5 as Any),
                             ("proposedManifestPath", "../../default.store" as Any),
                             ("previousManifestPath", "/absolute.json" as Any)] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try ScannerDatabaseUpdateResult.decode(invalid))
        }
        var unavailable = valid; unavailable["status"] = "upToDate"
        XCTAssertThrowsError(try ScannerDatabaseUpdateResult.decode(unavailable), "A changed download cannot be reported as no update")
        var missing = valid; missing.removeValue(forKey: "previousManifestPath")
        XCTAssertThrowsError(try ScannerDatabaseUpdateResult.decode(missing))
    }

    func testPublicationChecksCompleteNativeRecordsAndKeepsOldPackAndOtherGame() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        try await cache.write("cur:tcgp:1", data: json("mtg/current.json"))
        try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json")
        let pointer = try await cache.read("cur:tcgp:3"), old = try await cache.read("h:pokemon/old-hash")
        let other = try await cache.read("cur:tcgp:1")
        XCTAssertEqual(pointer, try json("pokemon/new.json")); XCTAssertNotNil(old)
        XCTAssertEqual(other, try json("mtg/current.json"))
        // Publication is idempotent if a completed equivalent check already won.
        try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json")
    }

    func testIncompleteOrChangedCacheCannotReplaceCurrentPointer() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        try await cache.remove("m:pokemon/new-meta")
        do { try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json"); XCTFail("Incomplete pack published") }
        catch { XCTAssertTrue(error is ScannerDatabaseUpdateFailure) }
        let old = try await cache.read("cur:tcgp:3"); XCTAssertEqual(old, try json("pokemon/old.json"))
        try await stage("new", in: cache); try await stage("other", in: cache, current: true)
        do { try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json"); XCTFail("Newer pointer overwritten") }
        catch { XCTAssertTrue(error is ScannerDatabaseUpdateFailure) }
        let changed = try await cache.read("cur:tcgp:3"); XCTAssertEqual(changed, try json("pokemon/other.json"))
    }

    func testCancelledPublicationCannotCommitAndCommittedDataReopens() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        let cancelled = Task {
            try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json")
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled task published") } catch { XCTAssertTrue(error is CancellationError) }
        let unchanged = try await cache.read("cur:tcgp:3"); XCTAssertEqual(unchanged, try json("pokemon/old.json"))
        try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json")
        let reopened = ScannerDatabaseCache(directory: root)
        let saved = try await reopened.read("cur:tcgp:3"); XCTAssertEqual(saved, try json("pokemon/new.json"))
    }

    func testPublicationRejectsMismatchedKeysReferenceCountsAndTruncatedLayout() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        var header = Data([1, 78, 83, 80, 83, 2, 0, 0, 0]); header.append(Data(count: 16))
        for (count, references, key) in [(0, 0, 1), (0, 1, 0), (1, 1, 0)] {
            var binary = header; binary[9] = UInt8(count)
            try await cache.write("h:pokemon/new-hash", data: binary)
            try await cache.write("m:pokemon/new-meta", data: json(["refs": Array(repeating: [String](), count: references), "k": key]))
            do { try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json"); XCTFail("Invalid shard published") }
            catch { XCTAssertTrue(error is ScannerDatabaseUpdateFailure) }
            let pointer = try await cache.read("cur:tcgp:3"); XCTAssertEqual(pointer, try json("pokemon/old.json"))
        }
    }

    func testRetiredDocumentPruneCannotDeleteNewCurrentPackOrAnotherGamesPack() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        try await stage("other-game", in: cache, game: "tcgp:1", current: true)
        try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json")
        for key in ["M:pokemon/new.json", "h:pokemon/new-hash", "m:pokemon/new-meta", "M:pokemon/other-game.json",
                    "h:pokemon/other-game-hash", "m:pokemon/other-game-meta", "cur:tcgp:3"] {
            let deleted = try await cache.removeIfUnreferenced(key)
            let saved = try await cache.read(key)
            XCTAssertFalse(deleted); XCTAssertNotNil(saved, "A stale prune cannot remove \(key)")
        }
        let deleted = try await cache.removeIfUnreferenced("h:pokemon/old-hash")
        let old = try await cache.read("h:pokemon/old-hash")
        XCTAssertTrue(deleted); XCTAssertNil(old)
    }

    func testPruneFailsClosedForInvalidOrMissingCurrentManifest() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("unused", in: cache)
        try await cache.write("cur:tcgp:2", data: Data([0, 255]))
        let malformed = try await cache.removeIfUnreferenced("h:pokemon/unused-hash")
        XCTAssertFalse(malformed)
        try await cache.write("cur:tcgp:2", data: json("missing/manifest.json"))
        let missing = try await cache.removeIfUnreferenced("h:pokemon/unused-hash")
        let retained = try await cache.read("h:pokemon/unused-hash")
        XCTAssertFalse(missing); XCTAssertNotNil(retained)
    }

    func testSuccessfulCheckPersistsDailyPerGameThrottleAcrossCoordinatorRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let runner = Runner(); runner.response = result()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, now: { date }, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon")
        await waitUntil { updater.state == .updated }
        XCTAssertEqual(updater.lastSuccessfulCheck(for: "Pokémon"), date)
        updater.setHomeVisible(false, game: "Pokémon")
        let secondRunner = Runner(); secondRunner.response = result(.upToDate, previous: "new")
        let reopened = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: secondRunner, now: { date }, wait: { _ in })
        reopened.setHomeVisible(true, game: "Pokémon")
        XCTAssertEqual(reopened.state, .upToDate); XCTAssertTrue(secondRunner.calls.isEmpty)
        XCTAssertNil(reopened.lastSuccessfulCheck(for: "Magic: The Gathering"))
        date = date.addingTimeInterval(86_400)
        reopened.setHomeVisible(true, game: "Pokémon")
        await waitUntil { secondRunner.calls.count == 1 && reopened.state == .upToDate }
        XCTAssertEqual(reopened.lastSuccessfulCheck(for: "Pokémon"), date)
        reopened.setHomeVisible(false, game: "Pokémon")
    }

    func testFailedCheckRetainsDatabaseAndRetriesAfterBackoffWithoutSuccessTimestamp() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root); try await stage("old", in: cache, current: true)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let runner = Runner(); runner.response = ScannerDatabaseUpdateResult(status: .failed, downloadedBytes: 0, cachedShards: 0)
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, now: { date }, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .failed }
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
        updater.setHomeVisible(true, game: "Pokémon"); XCTAssertEqual(runner.calls.count, 1)
        date = date.addingTimeInterval(3_600)
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { runner.calls.count == 2 && updater.state == .failed }
        let pointer = try await cache.read("cur:tcgp:3"); XCTAssertEqual(pointer, try json("pokemon/old.json"))
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testScannerLeasesCancelLateResultAndPreventPublicationUntilAllReleased() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { runner.pending.count == 1 }
        let first = updater.beginScannerUse(), second = updater.beginScannerUse()
        runner.complete(result()); await Task.yield()
        let pointer = try await cache.read("cur:tcgp:3"); XCTAssertEqual(pointer, try json("pokemon/old.json"))
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
        updater.endScannerUse(first); await Task.yield(); XCTAssertEqual(runner.calls.count, 1)
        updater.endScannerUse(second); await waitUntil { runner.pending.count == 1 && runner.calls.count == 2 }
        runner.complete(result()); await waitUntil { updater.state == .updated }
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testHiddenBackgroundDisabledAndUnsupportedGamesDoNotRun() async {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner()
        let updater = ScannerDatabaseUpdater(defaults: defaults, runner: runner, wait: { _ in })
        updater.setHomeVisible(false, game: "Pokémon"); updater.setForeground(false)
        updater.setHomeVisible(true, game: "Pokémon"); await Task.yield(); XCTAssertTrue(runner.calls.isEmpty)
        updater.setEnabled(false); updater.setForeground(true); await Task.yield(); XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(updater.state, .disabled)
        updater.setHomeVisible(false, game: "Unsupported"); updater.setEnabled(true)
        updater.setHomeVisible(true, game: "Unsupported"); await Task.yield(); XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNoCachedPackSkipDoesNotDownloadOrRecordSuccessfulCheck() async {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner(); runner.response = ScannerDatabaseUpdateResult(status: .skipped, downloadedBytes: 0, cachedShards: 0)
        let updater = ScannerDatabaseUpdater(defaults: defaults, runner: runner, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .unavailable }
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon")); XCTAssertEqual(runner.calls, ["tcgp:3"])
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testBackgroundCancellationIgnoresLateResultAndRetriesWithoutFailureBackoff() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { runner.pending.count == 1 }
        updater.setForeground(false); runner.complete(result()); await Task.yield()
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
        let old = try await cache.read("cur:tcgp:3"); XCTAssertEqual(old, try json("pokemon/old.json"))
        updater.setForeground(true); await waitUntil { runner.calls.count == 2 && runner.pending.count == 1 }
        runner.complete(result()); await waitUntil { updater.state == .updated }
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testLeavingHomeDuringDebounceNeverStartsNetworkRunner() async {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner()
        var release: CheckedContinuation<Void, Never>?
        let updater = ScannerDatabaseUpdater(defaults: defaults, runner: runner, wait: { _ in
            await withCheckedContinuation { release = $0 }
        })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { release != nil }
        updater.setHomeVisible(false, game: "Pokémon"); release?.resume(); release = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(runner.calls.isEmpty); XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
    }

    func testPreparedResultCannotRecordSuccessWhenPublicationFails() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root); try await stage("old", in: cache, current: true)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner(); runner.response = result()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .failed }
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
        let pointer = try await cache.read("cur:tcgp:3"); XCTAssertEqual(pointer, try json("pokemon/old.json"))
        updater.setHomeVisible(false, game: "Pokémon")
    }
}
