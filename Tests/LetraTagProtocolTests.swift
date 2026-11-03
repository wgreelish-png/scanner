import XCTest
@testable import CardShowScanner

final class LetraTagProtocolTests: XCTestCase {
    private func bitmap(columns: Int, firstColumn: [UInt8] = [0, 0, 0, 0x80]) -> Data {
        var data = Data(firstColumn)
        data.append(Data(repeating: 0, count: (columns - 1) * 4))
        return data
    }

    private func body(from writes: [Data]) -> Data {
        var result = Data()
        for (index, write) in writes.dropFirst().enumerated() {
            let isFinal = index == writes.count - 2
            result.append(contentsOf: write.dropFirst().dropLast(isFinal ? 2 : 0))
        }
        return result
    }

    private func littleEndian(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = Array(data)
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    func testGoldenSingleWriteBodyHasExactHeaderCommandsDimensionsAndMagic() throws {
        let image = bitmap(columns: 30)
        let writes = try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: 244)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0], Data([0xFF, 0xF0, 0x12, 0x34, 0x94, 0, 0, 0, 0xC9]))
        var expected = Data([0, 0x1B, 0x73, 0x9A, 2, 0, 0, 0x1B, 0x23, 1,
                             0x1B, 0x44, 0x81, 2, 30, 0, 0, 0, 32, 0, 0, 0])
        expected.append(image)
        expected.append(contentsOf: [0x1B, 0x70, 0x30, 0x1B, 0x41, 0x1B, 0x51, 0x12, 0x34])
        XCTAssertEqual(writes[1], expected)
    }

    func testRawColumnPackingPreservesAll32HeadRows() throws {
        // One pixel at row 0, 7, 24, then 31, followed by a full black column.
        let columns: [UInt8] = [0, 0, 0, 0x80, 0, 0, 0, 1, 0x80, 0, 0, 0,
                                1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]
        var image = Data(columns)
        image.append(Data(repeating: 0, count: 25 * 4))
        let payload = body(from: try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: 244))
        XCTAssertEqual(littleEndian(payload, at: 13), 30)
        XCTAssertEqual(littleEndian(payload, at: 17), 32)
        XCTAssertEqual(Data(payload.dropFirst(21).prefix(image.count)), image)
    }

    func testTinyLabelIsDeterministicallyCentredWithinThirtyFeedColumns() throws {
        let image = Data([0, 0, 0, 0x80])
        let first = try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: 244)
        let second = try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: 244)
        XCTAssertEqual(first, second)
        let payload = body(from: first)
        XCTAssertEqual(littleEndian(payload, at: 13), 30)
        let pixels = Data(payload.dropFirst(21).prefix(120))
        XCTAssertEqual(pixels.prefix(14 * 4), Data(repeating: 0, count: 14 * 4))
        XCTAssertEqual(Data(pixels.dropFirst(14 * 4).prefix(4)), image)
        XCTAssertEqual(pixels.suffix(15 * 4), Data(repeating: 0, count: 15 * 4))
    }

    func testChunkingReservesFinalMagicAtLinkBoundaryAndRoundTripsBody() throws {
        // 53 columns produce a 240-byte body: with a 241-byte write limit,
        // the body alone fits but its final index and magic do not.
        let image = bitmap(columns: 53)
        let reference = body(from: try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: 503))
        for limit in [9, 20, 23, 148, 149, 150, 241, 244, 500, 501, 502, 503, 1_000, Int.max] {
            let writes = try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: limit)
            XCTAssertEqual(writes.first?.count, 9)
            XCTAssertTrue(writes.allSatisfy { $0.count <= limit }, "Limit \(limit)")
            XCTAssertEqual(body(from: writes), reference)
            XCTAssertEqual(writes.last?.suffix(2), Data([0x12, 0x34]))
            for (position, write) in writes.dropFirst().enumerated() {
                let isFinal = position == writes.count - 2
                XCTAssertLessThanOrEqual(write.count - 1 - (isFinal ? 2 : 0), 500)
            }
        }
        XCTAssertEqual(try LetraTagProtocol.encode(bitmapData: image, maximumWriteValueLength: 241).count, 3)
    }

    func testProtocolCeilingRemains500BodyBytesWhenLinkAllowsLargerWrites() throws {
        let writes = try LetraTagProtocol.encode(bitmapData: bitmap(columns: 600), maximumWriteValueLength: 2_000)
        XCTAssertEqual(writes.count, 6)
        XCTAssertEqual(writes[1].count, 501)
        XCTAssertTrue(writes.dropFirst().allSatisfy { $0.count <= 503 })
        XCTAssertEqual(littleEndian(writes[0], at: 4), UInt32(body(from: writes).count))
        XCTAssertEqual(writes[0].last, writes[0].dropLast().reduce(UInt8(0)) { $0 &+ $1 })
    }

    func testChunkIndexSkips27AndStopsBeforeWrapping() throws {
        // At a nine-byte write limit, 600 columns would overflow the index.
        let writes = try LetraTagProtocol.encode(bitmapData: bitmap(columns: 60), maximumWriteValueLength: 9)
        XCTAssertGreaterThan(writes.count, 29)
        XCTAssertEqual(writes[27].first, 26)
        XCTAssertEqual(writes[28].first, 28)
        XCTAssertFalse(writes.dropFirst().contains { $0.first == 27 })
        // 502 columns: body = 2036 bytes -> 255 chunks of <=8 bytes,
        // reserving the final two magic bytes within a nine-byte write.
        let maximum = try LetraTagProtocol.encode(bitmapData: bitmap(columns: 502), maximumWriteValueLength: 9)
        XCTAssertEqual(maximum.count, 256)
        XCTAssertEqual(maximum.last?.first, 255)
        XCTAssertThrowsError(try LetraTagProtocol.encode(bitmapData: bitmap(columns: 503), maximumWriteValueLength: 9)) {
            XCTAssertEqual($0 as? LetraTagProtocolError, .tooManyChunks)
        }
        XCTAssertThrowsError(try LetraTagProtocol.encode(bitmapData: bitmap(columns: 600), maximumWriteValueLength: 9)) {
            XCTAssertEqual($0 as? LetraTagProtocolError, .tooManyChunks)
        }
    }

    func testEmptyBlankMalformedTooLongAndTinyWriteLimitsAreRejected() throws {
        let invalid: [(Data, Int, LetraTagProtocolError)] = [
            (Data(), 244, .emptyBitmap),
            (Data([1]), 244, .invalidBitmapLength),
            (Data(repeating: 0, count: 120), 244, .blankBitmap),
            (bitmap(columns: 601), 244, .labelTooLong),
            (bitmap(columns: 30), 8, .writeLengthTooSmall),
            (bitmap(columns: 30), 0, .writeLengthTooSmall),
            (bitmap(columns: 30), Int.min, .writeLengthTooSmall)
        ]
        for (data, limit, failure) in invalid {
            XCTAssertThrowsError(try LetraTagProtocol.encode(bitmapData: data, maximumWriteValueLength: limit)) {
                XCTAssertEqual($0 as? LetraTagProtocolError, failure)
            }
        }
    }

    func testStatusRequiresExactThreeByteESCReplyAndOnlyCodeZeroSucceeds() {
        XCTAssertEqual(LetraTagProtocol.parseStatus(Data([0x1B, 0x52, 0])), .success)
        for code in UInt8(1)...UInt8(255) {
            XCTAssertEqual(LetraTagProtocol.parseStatus(Data([0x1B, 0x52, code])), .unknown(code: code))
        }
        for data in [Data(), Data([0x1B]), Data([0x1B, 0x52]), Data([0x1B, 0x52, 0, 0]),
                     Data([0, 0x52, 0]), Data([0x1B, 0x41, 0]), Data([1, 2, 3])] {
            XCTAssertNil(LetraTagProtocol.parseStatus(data))
        }
    }

    func testUUIDRolesAcceptVariableTailsAndRequireServiceTailWhenProvided() {
        for tail in ["1111-2222-3333-444444444444", "ABCD-1234-5678-0123456789AB"] {
            let service = "BE3DD650-" + tail
            for role in LetraTagUUIDRole.allCases {
                let uuid = role.prefix + "-" + tail
                XCTAssertTrue(LetraTagProtocol.matches(uuidString: uuid, role: role, serviceUUID: service))
                XCTAssertTrue(LetraTagProtocol.matches(uuidString: uuid.uppercased(), role: role))
            }
            XCTAssertFalse(LetraTagProtocol.matches(uuidString: "be3dd652-" + tail, role: .printRequest, serviceUUID: service))
        }
        XCTAssertFalse(LetraTagProtocol.matches(uuidString: "be3dd651-1111-2222-3333-444444444444", role: .printRequest,
                                              serviceUUID: "be3dd650-1111-2222-3333-555555555555"))
        XCTAssertFalse(LetraTagProtocol.matches(uuidString: "be3dd651-1111-2222-3333-444444444444", role: .printRequest,
                                              serviceUUID: "be3dd652-1111-2222-3333-444444444444"))
        for invalid in ["", "be3dd650", "be3dd650-", "be3dd650-invalid", " be3dd650-1111-2222-3333-444444444444"] {
            XCTAssertFalse(LetraTagProtocol.matches(uuidString: invalid, role: .service))
        }
    }
}
