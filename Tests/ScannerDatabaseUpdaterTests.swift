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

    func testWeeklyAttemptAndSuccessIntervalsAndChangedClock() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: nil, lastAttempt: nil, now: date))
        for recent in [date, date.addingTimeInterval(-86_400), date.addingTimeInterval(-604_799)] {
            XCTAssertFalse(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: recent, lastAttempt: nil, now: date))
            XCTAssertFalse(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: nil, lastAttempt: recent, now: date))
        }
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: date.addingTimeInterval(-604_800), lastAttempt: nil, now: date))
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: nil, lastAttempt: date.addingTimeInterval(-604_800), now: date))
        XCTAssertTrue(ScannerDatabaseUpdatePolicy.isDue(lastSuccess: date.addingTimeInterval(604_800), lastAttempt: nil, now: date), "A clock correction must not block checks indefinitely")
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

    func testConditionalManifestReplacementSupportsInitialAndCurrentPointerCommits() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        let initial = try await cache.replaceManifestIfCurrent(key: "cur:tcgp:3", expected: nil, data: json("pokemon/old.json"))
        XCTAssertTrue(initial)
        let replaced = try await cache.replaceManifestIfCurrent(key: "cur:tcgp:3", expected: "pokemon/old.json", data: json("pokemon/new.json"))
        XCTAssertTrue(replaced)
        let cancelled = Task {
            try await cache.replaceManifestIfCurrent(key: "cur:tcgp:3", expected: "pokemon/new.json", data: json("pokemon/old.json"))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled replacement published") }
        catch { XCTAssertTrue(error is CancellationError) }
        let reopened = ScannerDatabaseCache(directory: root)
        let saved = try await reopened.read("cur:tcgp:3")
        XCTAssertEqual(saved, try json("pokemon/new.json"))
    }

    func testRetiredDocumentManifestReplacementCannotRevertNativePublication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        try await stage("other-game", in: cache, game: "tcgp:1", current: true)
        try await cache.commitPreparedManifest(gameKey: "tcgp:3", previous: "pokemon/old.json", proposed: "pokemon/new.json")
        let keys = try await cache.keys()
        var before: [String: Data] = [:]
        for key in keys { before[key] = try await cache.read(key) }
        let stale = try await cache.replaceManifestIfCurrent(key: "cur:tcgp:3", expected: "pokemon/old.json", data: json("pokemon/old.json"))
        let absent = try await cache.replaceManifestIfCurrent(key: "cur:tcgp:3", expected: nil, data: json("pokemon/old.json"))
        XCTAssertFalse(stale); XCTAssertFalse(absent)
        let afterKeys = try await cache.keys(); XCTAssertEqual(afterKeys, keys)
        for key in keys {
            let saved = try await cache.read(key)
            XCTAssertEqual(saved, before[key], "A stale pointer replacement changed \(key)")
        }
    }

    func testConditionalManifestReplacementFailsClosedForCorruptMarkersAndInvalidRequests() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("other-game", in: cache, game: "tcgp:1", current: true)
        let unrelated = try await cache.read("cur:tcgp:1")
        let corrupt = [Data([0, 255]), Data([1, 0]), try json(NSNull()), try json("/absolute.json"), try json("../unsafe.json")]
        for marker in corrupt {
            try await cache.write("cur:tcgp:3", data: marker)
            for expected in [nil, "pokemon/old.json"] as [String?] {
                let replaced = try await cache.replaceManifestIfCurrent(key: "cur:tcgp:3", expected: expected, data: json("pokemon/new.json"))
                let saved = try await cache.read("cur:tcgp:3")
                XCTAssertFalse(replaced); XCTAssertEqual(saved, marker)
            }
        }
        let unchanged = try await cache.read("cur:tcgp:3"), keys = try await cache.keys()
        let invalid: [(String, String?, Data)] = [("cur:tcgp:4", nil, try json("pokemon/new.json")),
                                                ("M:pokemon/new.json", nil, try json("pokemon/new.json")),
                                                ("cur:tcgp:3", "/absolute.json", try json("pokemon/new.json")),
                                                ("cur:tcgp:3", nil, try json("/absolute.json")),
                                                ("cur:tcgp:3", nil, try json(NSNull())),
                                                ("cur:tcgp:3", nil, Data([0, 255]))]
        for (key, expected, data) in invalid {
            do { _ = try await cache.replaceManifestIfCurrent(key: key, expected: expected, data: data); XCTFail("Invalid replacement accepted") }
            catch { XCTAssertTrue(error is ScannerDatabaseUpdateFailure) }
        }
        let afterKeys = try await cache.keys(), saved = try await cache.read("cur:tcgp:3")
        let other = try await cache.read("cur:tcgp:1")
        XCTAssertEqual(afterKeys, keys); XCTAssertEqual(saved, unchanged); XCTAssertEqual(other, unrelated)
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

    func testSuccessfulCheckPersistsWeeklyPerGameThrottleAcrossCoordinatorRelaunch() async throws {
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
        date = date.addingTimeInterval(604_800)
        reopened.setHomeVisible(true, game: "Pokémon")
        await waitUntil { secondRunner.calls.count == 1 && reopened.state == .upToDate }
        XCTAssertEqual(reopened.lastSuccessfulCheck(for: "Pokémon"), date)
        reopened.setHomeVisible(false, game: "Pokémon")
    }

    func testFailedAttemptPersistsWeeklyThrottleAcrossRelaunchAndKeepsDatabase() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root); try await stage("old", in: cache, current: true)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let runner = Runner(); runner.response = ScannerDatabaseUpdateResult(status: .failed, downloadedBytes: 0, cachedShards: 0)
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, now: { date }, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .failed }
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon")); XCTAssertEqual(updater.lastAttempt(for: "Pokémon"), date)
        updater.setHomeVisible(false, game: "Pokémon")
        let reopenedRunner = Runner(); reopenedRunner.response = runner.response
        let reopened = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: reopenedRunner, now: { date }, wait: { _ in })
        date = date.addingTimeInterval(604_799)
        reopened.setHomeVisible(true, game: "Pokémon")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(reopenedRunner.calls.isEmpty)
        date = date.addingTimeInterval(1)
        reopened.setHomeVisible(true, game: "Pokémon"); await waitUntil { reopenedRunner.calls.count == 1 && reopened.state == .failed }
        let pointer = try await cache.read("cur:tcgp:3"); XCTAssertEqual(pointer, try json("pokemon/old.json"))
        reopened.setHomeVisible(false, game: "Pokémon")
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
        updater.endScannerUse(second)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner.calls.count, 1, "A canceled automatic attempt still consumes its weekly check")
        XCTAssertNotNil(updater.lastAttempt(for: "Pokémon"))
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

    func testNoCachedPackSkipDoesNotDownloadOrRecordSuccessfulCheck() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner(); runner.response = ScannerDatabaseUpdateResult(status: .skipped, downloadedBytes: 0, cachedShards: 0)
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .unavailable }
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon")); XCTAssertNil(updater.lastAttempt(for: "Pokémon")); XCTAssertTrue(runner.calls.isEmpty)
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testNativePreflightSkipsLegacyMissingAndInvalidCurrentManifests() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        let invalid: [Data?] = [nil, try json(["v": 1, "shards": [["hash": "old-hash", "meta": "old-meta"]]]),
                                try json(["v": 2, "shards": []]), Data([0, 255]),
                                try json(["v": 2, "shards": [["hash": "../unsafe", "meta": "old-meta"]]])]
        try await stage("other-game", in: cache, game: "tcgp:1", current: true)
        try await cache.write("cur:tcgp:3", data: json("pokemon/old.json"))
        for manifest in invalid {
            if let manifest { try await cache.write("M:pokemon/old.json", data: manifest) }
            else { try await cache.remove("M:pokemon/old.json") }
            updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .unavailable }
            XCTAssertTrue(runner.calls.isEmpty); XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
            updater.setHomeVisible(false, game: "Pokémon")
        }
        try await cache.write("cur:tcgp:3", data: Data([0, 255]))
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .unavailable }
        XCTAssertTrue(runner.calls.isEmpty); XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testEligiblePackCanStillBeSkippedByRunnerWithoutSuccessTimestamp() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root); try await stage("old", in: cache, current: true)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner(); runner.response = ScannerDatabaseUpdateResult(status: .skipped, downloadedBytes: 0, cachedShards: 0)
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { updater.state == .unavailable }
        XCTAssertEqual(runner.calls, ["tcgp:3"]); XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon"))
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testBackgroundCancellationIgnoresLateResultAndPersistsWeeklyAttemptAcrossRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let runner = Runner()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, now: { date }, wait: { _ in })
        updater.setHomeVisible(true, game: "Pokémon"); await waitUntil { runner.pending.count == 1 }
        updater.setForeground(false); runner.complete(result()); await Task.yield()
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon")); XCTAssertEqual(updater.lastAttempt(for: "Pokémon"), date)
        let old = try await cache.read("cur:tcgp:3"); XCTAssertEqual(old, try json("pokemon/old.json"))
        updater.setForeground(true)
        let secondRunner = Runner()
        let reopened = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: secondRunner, now: { date }, wait: { _ in })
        reopened.setHomeVisible(true, game: "Pokémon")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner.calls.count, 1); XCTAssertTrue(secondRunner.calls.isEmpty)
        updater.setHomeVisible(false, game: "Pokémon"); reopened.setHomeVisible(false, game: "Pokémon")
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

    func testLegacySuccessSkipsNativeCacheOpeningUntilAWeekHasPassed() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let unopened = root.appendingPathComponent("unopened-cache")
        let cache = ScannerDatabaseCache(directory: unopened)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(date.addingTimeInterval(-86_400).timeIntervalSince1970, forKey: "scanner.databaseUpdate.lastSuccess.tcgp:3")
        let runner = Runner()
        var waits = 0
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, now: { date }, wait: { _ in waits += 1 })
        updater.setHomeVisible(true, game: "Pokémon")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(updater.state, .upToDate); XCTAssertFalse(updater.isRefreshing)
        XCTAssertEqual(waits, 0); XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unopened.path), "A recent check must be rejected before opening the native database")
        XCTAssertNil(updater.lastAttempt(for: "Pokémon"))
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testManualRefreshBypassesDisabledAutomaticUpdatesAndWeeklyThrottleWithoutDebounce() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        try await stage("old", in: cache, current: true); try await stage("new", in: cache)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(false, forKey: ScannerDatabaseUpdater.enabledKey)
        defaults.set(date.timeIntervalSince1970, forKey: "scanner.databaseUpdate.lastSuccess.tcgp:3")
        let runner = Runner()
        var waits = 0
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, now: { date }, wait: { _ in waits += 1 })
        updater.setSettingsVisible(true, game: "Pokémon")
        date = date.addingTimeInterval(60)
        updater.refreshNow(game: "Pokémon")
        XCTAssertTrue(updater.isRefreshing)
        await waitUntil { runner.pending.count == 1 }
        XCTAssertEqual(waits, 0); XCTAssertEqual(runner.calls, ["tcgp:3"])
        updater.setEnabled(false)
        XCTAssertTrue(updater.isRefreshing, "The automatic preference must not cancel an explicit manual check")
        date = date.addingTimeInterval(60)
        runner.complete(result()); await waitUntil { updater.state == .updated }
        XCTAssertEqual(updater.lastSuccessfulCheck(for: "Pokémon"), date)
        XCTAssertEqual(updater.lastAttempt(for: "Pokémon"), date)
        updater.setSettingsVisible(false, game: "Pokémon"); updater.setEnabled(true)
        updater.setHomeVisible(true, game: "Pokémon")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner.calls.count, 1, "A successful manual refresh restarts the weekly automatic cadence")
        updater.setHomeVisible(false, game: "Pokémon")
    }

    func testManualRefreshRequiresVisibleSettingsForegroundAndNoScannerLease() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root); try await stage("old", in: cache, current: true)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner(); runner.response = result(.upToDate, proposed: "old")
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
        updater.refreshNow(game: "Pokémon")
        updater.setSettingsVisible(true, game: "Pokémon"); updater.setForeground(false)
        updater.refreshNow(game: "Pokémon")
        updater.setForeground(true)
        let lease = updater.beginScannerUse()
        updater.refreshNow(game: "Pokémon")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(runner.calls.isEmpty); XCTAssertNil(updater.lastAttempt(for: "Pokémon"))
        updater.endScannerUse(lease)
        updater.refreshNow(game: "Pokémon"); await waitUntil { updater.state == .upToDate }
        XCTAssertEqual(runner.calls, ["tcgp:3"])
        updater.setSettingsVisible(false, game: "Pokémon")
    }

    func testManualRefreshCancellationOnLeavingSettingsBackgroundGameChangeAndScannerUse() async throws {
        for reason in ["settings", "background", "game", "scanner"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let cache = ScannerDatabaseCache(directory: root)
            try await stage("old", in: cache, current: true); try await stage("new", in: cache)
            let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
            let runner = Runner()
            let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in })
            updater.setSettingsVisible(true, game: "Pokémon"); updater.refreshNow(game: "Pokémon")
            await waitUntil { runner.pending.count == 1 }
            switch reason {
            case "settings": updater.setSettingsVisible(false, game: "Pokémon")
            case "background": updater.setForeground(false)
            case "game": updater.setSettingsVisible(true, game: "Magic: The Gathering")
            default: _ = updater.beginScannerUse()
            }
            runner.complete(result())
            for _ in 0..<10 { await Task.yield() }
            let pointer = try await cache.read("cur:tcgp:3")
            XCTAssertEqual(pointer, try json("pokemon/old.json"), "A manual refresh canceled by \(reason) cannot publish")
            XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon")); XCTAssertFalse(updater.isRefreshing)
            updater.setSettingsVisible(false, game: "Pokémon")
        }
    }

    func testManualRefreshWithoutNativePackKeepsFirstDownloadInScanner() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ScannerDatabaseCache(directory: root)
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let runner = Runner()
        let updater = ScannerDatabaseUpdater(defaults: defaults, cache: cache, runner: runner, wait: { _ in XCTFail("A manual refresh must not debounce") })
        updater.setSettingsVisible(true, game: "Pokémon"); updater.refreshNow(game: "Pokémon")
        await waitUntil { updater.state == .unavailable }
        XCTAssertTrue(runner.calls.isEmpty); XCTAssertNil(updater.lastAttempt(for: "Pokémon"))
        XCTAssertNil(updater.lastSuccessfulCheck(for: "Pokémon")); XCTAssertFalse(updater.isRefreshing)
        updater.setSettingsVisible(false, game: "Pokémon")
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
