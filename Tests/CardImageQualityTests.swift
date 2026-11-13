import Foundation
import XCTest
@testable import CardShowScanner

final class CardImageQualityTests: XCTestCase {
    private func url(_ value: String) throws -> URL { try XCTUnwrap(URL(string: value)) }

    func testKnownCatalogRenditionsChangeInBothDirectionsWithoutChangingIdentity() throws {
        for path in ["517045", "517045_2"] {
            let small = try url("https://cdn.tcgtracking.com/product/\(path)_200w.jpg")
            let detailed = try url("https://cdn.tcgtracking.com/product/\(path)_400w.jpg")
            for context in CardImageContext.allCases {
                XCTAssertEqual(CardImageQuality.low.imageURL(detailed, context: context), small)
                XCTAssertEqual(CardImageQuality.high.imageURL(small, context: context), detailed)
                XCTAssertEqual(CardImageQuality.low.imageURL(small, context: context), small)
                XCTAssertEqual(CardImageQuality.high.imageURL(detailed, context: context), detailed)
                let automatic = context == .thumbnail ? small : detailed
                XCTAssertEqual(CardImageQuality.automatic.imageURL(small, context: context), automatic)
                XCTAssertEqual(CardImageQuality.automatic.imageURL(detailed, context: context), automatic)
            }
        }
    }

    func testResolutionAndSettingsTitlesForEveryQualityAndContext() {
        XCTAssertEqual(CardImageQuality.automatic.pixelWidth(for: .thumbnail), 200)
        XCTAssertEqual(CardImageQuality.automatic.pixelWidth(for: .detail), 400)
        for context in CardImageContext.allCases {
            XCTAssertEqual(CardImageQuality.low.pixelWidth(for: context), 200)
            XCTAssertEqual(CardImageQuality.high.pixelWidth(for: context), 400)
        }
        XCTAssertEqual(CardImageQuality.automatic.settingTitle, "Automatic")
        XCTAssertEqual(CardImageQuality.low.settingTitle, "Low (200px)")
        XCTAssertEqual(CardImageQuality.high.settingTitle, "High (400px)")
    }

    func testUnrecognizedOrSignedURLsRemainExactlyAsProvided() throws {
        let originals = [
            "https://example.com/product/517045_400w.jpg",
            "https://cdn.tcgtracking.com.example.com/product/517045_400w.jpg",
            "http://cdn.tcgtracking.com/product/517045_400w.jpg",
            "https://cdn.tcgtracking.com:443/product/517045_400w.jpg",
            "https://name@cdn.tcgtracking.com/product/517045_400w.jpg",
            "https://name:password@cdn.tcgtracking.com/product/517045_400w.jpg",
            "https://cdn.tcgtracking.com/product/517045_400w.jpg?signature=fixture",
            "https://cdn.tcgtracking.com/product/517045_400w.jpg#face",
            "https://cdn.tcgtracking.com/product/517045_800w.jpg",
            "https://cdn.tcgtracking.com/product/517045_400w.png",
            "https://cdn.tcgtracking.com/other/517045_400w.jpg",
            "https://cdn.tcgtracking.com/product/0_400w.jpg",
            "https://cdn.tcgtracking.com/product/0517045_400w.jpg",
            "https://cdn.tcgtracking.com/product/517045_0_400w.jpg",
            "https://cdn.tcgtracking.com/product/%35%31%37%30%34%35_400w.jpg"
        ]
        for value in originals {
            let original = try url(value)
            for quality in CardImageQuality.allCases {
                for context in CardImageContext.allCases {
                    XCTAssertEqual(quality.imageURL(original, context: context)?.absoluteString,
                                   original.absoluteString, value)
                }
            }
        }
        for quality in CardImageQuality.allCases {
            for context in CardImageContext.allCases {
                XCTAssertNil(quality.imageURL(nil, context: context))
            }
        }
    }

    func testPreferenceDefaultsToHighAndReadingDoesNotWriteOrChangeOtherSettings() throws {
        let suite = "CardImageQualityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("transparent", forKey: "niimbotPaperMode")
        defaults.set(70.0, forKey: "cashPercentage")
        XCTAssertEqual(CardImageQuality.current(defaults: defaults), .high)
        XCTAssertNil(defaults.object(forKey: CardImageQuality.defaultsKey))
        XCTAssertEqual(defaults.string(forKey: "niimbotPaperMode"), "transparent")
        XCTAssertEqual(defaults.double(forKey: "cashPercentage"), 70)
    }

    func testSelectedQualityPersistsAcrossDefaultsInstances() throws {
        let suite = "CardImageQualityTests." + UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        for quality in CardImageQuality.allCases {
            first.set(quality.rawValue, forKey: CardImageQuality.defaultsKey)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(CardImageQuality.current(defaults: reopened), quality)
        }
    }

    func testStoredRawValuesRemainCompatible() throws {
        let suite = "CardImageQualityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (rawValue, expected) in [("automatic", CardImageQuality.automatic), ("low", .low), ("high", .high)] {
            defaults.set(rawValue, forKey: CardImageQuality.defaultsKey)
            XCTAssertEqual(CardImageQuality.current(defaults: defaults), expected)
            XCTAssertEqual(defaults.string(forKey: CardImageQuality.defaultsKey), rawValue)
        }
    }

    func testUnknownStoredValuesFallBackToHighWithoutMigratingSettings() throws {
        let suite = "CardImageQualityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid: [Any] = ["", "medium", "LOW", "auto", "AUTOMATIC", "400", true, 200, Data([1])]
        for value in invalid {
            defaults.set(value, forKey: CardImageQuality.defaultsKey)
            let before = defaults.persistentDomain(forName: suite) as NSDictionary?
            XCTAssertEqual(CardImageQuality.current(defaults: defaults), .high)
            XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, before)
        }
    }

    func testDisplayResolutionDoesNotMutateTheSavedSourceURL() throws {
        let original = try url("https://cdn.tcgtracking.com/product/517045_400w.jpg")
        let saved = original.absoluteString
        for quality in CardImageQuality.allCases {
            for context in CardImageContext.allCases {
                _ = quality.imageURL(original, context: context)
                XCTAssertEqual(original.absoluteString, saved)
            }
        }
        XCTAssertEqual(CardImageQuality.low.imageURL(original, context: .detail)?.lastPathComponent,
                       "517045_200w.jpg")
        XCTAssertEqual(original.absoluteString, saved)
    }
}
