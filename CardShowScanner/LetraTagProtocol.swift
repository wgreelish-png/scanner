import Foundation

/// The LT-200B wire format, independent of Bluetooth and image rendering.
/// Protocol reference: thermal-label/letratag a8fb41e19ce3a8cb1e51d6aaeb1acc8060d5842b
/// (MIT), docs/protocol/letratag-bt.md. See the repository's attribution notice.
enum LetraTagProtocol {
    static let thirdPartyNotice = """
    MIT License

    Copyright (c) 2026 Mannes Brak

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

    Protocol reference: https://github.com/thermal-label/letratag
    Reference commit: a8fb41e19ce3a8cb1e51d6aaeb1acc8060d5842b
    """
    static let headRows = 32
    static let bytesPerColumn = 4
    static let minimumColumns = 30
    static let maximumColumns = 600
    static let maximumBodyBytesPerWrite = 500

    /// Input is column-major: four bytes per feed column, with head rows
    /// 24...31 in byte 0 and rows 0...7 in byte 3, MSB first within each byte.
    /// The returned header is always a separate first write. All writes fit
    /// the peripheral's maximumWriteValueLength(for: .withoutResponse).
    static func encode(bitmapData: Data, maximumWriteValueLength: Int) throws -> [Data] {
        guard !bitmapData.isEmpty else { throw LetraTagProtocolError.emptyBitmap }
        guard bitmapData.count.isMultiple(of: bytesPerColumn) else {
            throw LetraTagProtocolError.invalidBitmapLength
        }
        let sourceColumns = bitmapData.count / bytesPerColumn
        guard sourceColumns <= maximumColumns else { throw LetraTagProtocolError.labelTooLong }
        guard bitmapData.contains(where: { $0 != 0 }) else { throw LetraTagProtocolError.blankBitmap }
        // The fixed header needs nine bytes even when a body fragment could fit.
        guard maximumWriteValueLength >= 9 else { throw LetraTagProtocolError.writeLengthTooSmall }

        // A minimum number of feed columns avoids the observed alternating
        // silent rejection of repeated tiny jobs. Centre the original columns.
        let columns = max(minimumColumns, sourceColumns)
        let leadingColumns = (columns - sourceColumns) / 2
        let trailingColumns = columns - sourceColumns - leadingColumns
        var image = Data(repeating: 0, count: leadingColumns * bytesPerColumn)
        image.append(bitmapData)
        image.append(Data(repeating: 0, count: trailingColumns * bytesPerColumn))

        var body = Data([0x1B, 0x73, 0x9A, 0x02, 0x00, 0x00, // ESC s, fixed job ID
                         0x1B, 0x23, 0x01,                   // ESC #, one copy
                         0x1B, 0x44, 0x81, 0x02])             // ESC D, format/alignment
        appendLittleEndian(UInt32(columns), to: &body)
        appendLittleEndian(UInt32(headRows), to: &body)
        body.append(image)
        body.append(contentsOf: [0x1B, 0x70, 0x30, // cut at end
                                 0x1B, 0x41,       // request result
                                 0x1B, 0x51])      // close job
        return try frame(body: body, maximumWriteValueLength: maximumWriteValueLength)
    }

    /// Only the exact ESC R frame is a job result. Code zero is the sole
    /// positively observed success; the meanings of other codes are unverified.
    static func parseStatus(_ data: Data) -> LetraTagStatus? {
        guard data.count == 3 else { return nil }
        let bytes = Array(data)
        guard bytes[0] == 0x1B, bytes[1] == 0x52 else { return nil }
        return bytes[2] == 0 ? .success : .unknown(code: bytes[2])
    }

    /// UUID bodies vary between devices. Match the stable role prefix and,
    /// when discovering characteristics, require the discovered service's tail.
    static func matches(uuidString: String, role: LetraTagUUIDRole, serviceUUID: String? = nil) -> Bool {
        guard let uuid = normalizedUUID(uuidString), uuid.hasPrefix(role.prefix + "-") else { return false }
        guard let serviceUUID else { return true }
        guard let service = normalizedUUID(serviceUUID),
              service.hasPrefix(LetraTagUUIDRole.service.prefix + "-") else { return false }
        return uuid.dropFirst(8) == service.dropFirst(8)
    }

    private static func normalizedUUID(_ string: String) -> String? {
        UUID(uuidString: string)?.uuidString.lowercased()
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value),
                                 UInt8(truncatingIfNeeded: value >> 8),
                                 UInt8(truncatingIfNeeded: value >> 16),
                                 UInt8(truncatingIfNeeded: value >> 24)])
    }

    private static func frame(body: Data, maximumWriteValueLength: Int) throws -> [Data] {
        let bodyCapacity = min(maximumBodyBytesPerWrite, maximumWriteValueLength - 1)
        let finalBodyCapacity = min(maximumBodyBytesPerWrite, maximumWriteValueLength - 3)
        // Reserve both the index and magic before calculating the number of
        // chunks. In particular, a final full-size slice cannot overrun the MTU.
        let precedingBytes = max(0, body.count - finalBodyCapacity)
        let precedingChunkCount = precedingBytes / bodyCapacity + (precedingBytes % bodyCapacity == 0 ? 0 : 1)
        let chunkCount = precedingChunkCount + 1
        // 0...26 and 28...255 are the 255 usable indices; index 27 is skipped.
        guard chunkCount <= 255 else { throw LetraTagProtocolError.tooManyChunks }

        var header = Data([0xFF, 0xF0, 0x12, 0x34])
        appendLittleEndian(UInt32(body.count), to: &header)
        header.append(header.reduce(UInt8(0)) { $0 &+ $1 })
        var writes = [header]
        var offset = 0
        for position in 0..<chunkCount {
            let isFinal = position == chunkCount - 1
            let remaining = body.count - offset
            let count = isFinal ? remaining : min(bodyCapacity, remaining - finalBodyCapacity)
            let index = position >= 27 ? position + 1 : position
            var write = Data([UInt8(index)])
            write.append(body.subdata(in: offset..<(offset + count)))
            if isFinal { write.append(contentsOf: [0x12, 0x34]) }
            writes.append(write)
            offset += count
        }
        return writes
    }
}

enum LetraTagUUIDRole: CaseIterable {
    case service
    case printRequest
    case printReply
    case shortCommand

    var prefix: String {
        switch self {
        case .service: return "be3dd650"
        case .printRequest: return "be3dd651"
        case .printReply: return "be3dd652"
        case .shortCommand: return "be3dd653"
        }
    }
}

enum LetraTagStatus: Equatable {
    case success
    case unknown(code: UInt8)
}

enum LetraTagProtocolError: LocalizedError, Equatable {
    case emptyBitmap
    case invalidBitmapLength
    case blankBitmap
    case labelTooLong
    case writeLengthTooSmall
    case tooManyChunks

    var errorDescription: String? {
        switch self {
        case .emptyBitmap: return "The label is empty."
        case .invalidBitmapLength: return "The label bitmap must contain four bytes per column."
        case .blankBitmap: return "The label has no printable pixels."
        case .labelTooLong: return "The label exceeds the maximum length of 600 columns."
        case .writeLengthTooSmall: return "The printer's Bluetooth write limit is too small for a label header."
        case .tooManyChunks: return "The label needs too many Bluetooth packets for this connection."
        }
    }
}
