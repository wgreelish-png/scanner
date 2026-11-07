import Foundation
import XCTest
@testable import CardShowScanner

@MainActor final class NiimbotImageTransferPreferencesTests: XCTestCase {
    private func fixture() throws -> (defaults: UserDefaults, suite: String, prefix: String) {
        let suite = "NiimbotImageTransferPreferencesTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite, "transfer." + UUID().uuidString)
    }

    func testConfigurationDefaultsPreserveTheExistingAcknowledgedTransferAndClampBounds() {
        let original = NiimbotImageTransferConfiguration()
        XCTAssertEqual(original.framesPerWrite, 2)
        XCTAssertEqual(original.byteLimit, 64)
        XCTAssertEqual(original.pacingMilliseconds, 10)
        XCTAssertEqual(NiimbotImageTransferConfiguration.maximumFrames, 16)
        XCTAssertEqual(NiimbotImageTransferConfiguration.maximumBytes, 256)
        XCTAssertEqual(NiimbotImageTransferConfiguration.maximumPacingMilliseconds, 50)
        let low = NiimbotImageTransferConfiguration(framesPerWrite: Int.min, byteLimit: Int.min, pacingMilliseconds: Int.min)
        XCTAssertEqual(low.framesPerWrite, 1)
        XCTAssertEqual(low.byteLimit, 20)
        XCTAssertEqual(low.pacingMilliseconds, 0)
        let high = NiimbotImageTransferConfiguration(framesPerWrite: Int.max, byteLimit: Int.max, pacingMilliseconds: Int.max)
        XCTAssertEqual(high.framesPerWrite, 16)
        XCTAssertEqual(high.byteLimit, 256)
        XCTAssertEqual(high.pacingMilliseconds, 50)
    }

    func testOpeningPreferencesDoesNotWriteDefaultsOrTouchExistingSettings() throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.defaults.set("transparent", forKey: "niimbotPaperMode")
        let preferences = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
        XCTAssertEqual(preferences.snapshot, NiimbotImageTransferConfiguration())
        for suffix in ["framesPerWrite", "byteLimit", "pacingMilliseconds"] {
            XCTAssertNil(f.defaults.object(forKey: f.prefix + "." + suffix))
        }
        XCTAssertEqual(f.defaults.string(forKey: "niimbotPaperMode"), "transparent")
    }

    func testChoicesPersistAcrossInstancesAndSnapshotsCannotChangeWithLaterSelections() throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let preferences = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
        preferences.framesPerWrite = 8
        preferences.byteLimit = 192
        preferences.pacingMilliseconds = 0
        let job = preferences.snapshot
        let reopened = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
        XCTAssertEqual(reopened.snapshot, job)
        preferences.framesPerWrite = 16
        preferences.byteLimit = 256
        preferences.pacingMilliseconds = 50
        XCTAssertEqual(job, NiimbotImageTransferConfiguration(framesPerWrite: 8, byteLimit: 192, pacingMilliseconds: 0))
        let nextJob = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix).snapshot
        XCTAssertEqual(nextJob, NiimbotImageTransferConfiguration(framesPerWrite: 16, byteLimit: 256, pacingMilliseconds: 50))
    }

    func testBooleanFractionalStringAndMalformedStoredValuesUseDefaultsWithoutRewriting() throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let invalid: [Any] = [true, false, 2.5, "8", "invalid", Data([1]), [1, 2]]
        for value in invalid {
            for suffix in ["framesPerWrite", "byteLimit", "pacingMilliseconds"] {
                f.defaults.set(value, forKey: f.prefix + "." + suffix)
            }
            let before = f.defaults.persistentDomain(forName: f.suite) as NSDictionary?
            let preferences = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
            XCTAssertEqual(preferences.snapshot, NiimbotImageTransferConfiguration(), "Reject invalid stored type: \(type(of: value))")
            XCTAssertEqual(f.defaults.persistentDomain(forName: f.suite) as NSDictionary?, before,
                           "Reading invalid values must not migrate or rewrite the persistent domain")
        }
    }

    func testCanonicalWholeNumbersLoadAndOutOfRangeStoredValuesClampWithoutRewriting() throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.defaults.set(NSNumber(value: 8), forKey: f.prefix + ".framesPerWrite")
        f.defaults.set(NSNumber(value: 128), forKey: f.prefix + ".byteLimit")
        f.defaults.set(NSNumber(value: 0), forKey: f.prefix + ".pacingMilliseconds")
        let whole = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
        XCTAssertEqual(whole.snapshot, NiimbotImageTransferConfiguration(framesPerWrite: 8, byteLimit: 128, pacingMilliseconds: 0))
        for raw in [-99, 999] {
            for suffix in ["framesPerWrite", "byteLimit", "pacingMilliseconds"] {
                f.defaults.set(raw, forKey: f.prefix + "." + suffix)
            }
            let preferences = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
            let expected = NiimbotImageTransferConfiguration(framesPerWrite: raw, byteLimit: raw, pacingMilliseconds: raw)
            XCTAssertEqual(preferences.snapshot, expected)
            XCTAssertEqual(f.defaults.integer(forKey: f.prefix + ".framesPerWrite"), raw)
            XCTAssertEqual(f.defaults.integer(forKey: f.prefix + ".byteLimit"), raw)
            XCTAssertEqual(f.defaults.integer(forKey: f.prefix + ".pacingMilliseconds"), raw)
        }
    }

    func testSettersPersistOnlyClampedValues() throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let preferences = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
        for raw in [-99, 999] {
            preferences.framesPerWrite = raw
            preferences.byteLimit = raw
            preferences.pacingMilliseconds = raw
            let expected = NiimbotImageTransferConfiguration(framesPerWrite: raw, byteLimit: raw, pacingMilliseconds: raw)
            XCTAssertEqual(preferences.snapshot, expected)
            XCTAssertEqual(f.defaults.integer(forKey: f.prefix + ".framesPerWrite"), expected.framesPerWrite)
            XCTAssertEqual(f.defaults.integer(forKey: f.prefix + ".byteLimit"), expected.byteLimit)
            XCTAssertEqual(f.defaults.integer(forKey: f.prefix + ".pacingMilliseconds"), expected.pacingMilliseconds)
            XCTAssertEqual(NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix).snapshot, expected)
        }
    }

    func testResetRemovesOnlyItsOwnKeysAndPreservesPaperInventoryAndOtherFixtures() throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let preferences = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix)
        let other = NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix + ".other")
        preferences.framesPerWrite = 8
        preferences.byteLimit = 192
        preferences.pacingMilliseconds = 0
        other.framesPerWrite = 4
        other.byteLimit = 96
        other.pacingMilliseconds = 20
        let otherSnapshot = other.snapshot
        let inventory = Data([0, 1, 2, 3])
        f.defaults.set("40x12", forKey: "niimbotLabelSize")
        f.defaults.set("transparent", forKey: "niimbotPaperMode")
        f.defaults.set(inventory, forKey: "inventory.fixture")
        f.defaults.set("preserve", forKey: f.prefix + ".unrelated")
        preferences.reset()
        XCTAssertEqual(preferences.snapshot, NiimbotImageTransferConfiguration())
        XCTAssertEqual(NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix).snapshot, preferences.snapshot)
        for suffix in ["framesPerWrite", "byteLimit", "pacingMilliseconds"] {
            XCTAssertNil(f.defaults.object(forKey: f.prefix + "." + suffix))
        }
        XCTAssertEqual(f.defaults.string(forKey: "niimbotLabelSize"), "40x12")
        XCTAssertEqual(f.defaults.string(forKey: "niimbotPaperMode"), "transparent")
        XCTAssertEqual(f.defaults.data(forKey: "inventory.fixture"), inventory)
        XCTAssertEqual(f.defaults.string(forKey: f.prefix + ".unrelated"), "preserve")
        XCTAssertEqual(NiimbotImageTransferPreferences(defaults: f.defaults, keyPrefix: f.prefix + ".other").snapshot, otherSnapshot)
    }
}
