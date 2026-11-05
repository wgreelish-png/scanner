import Foundation

/// A catalog rectangle retains its source axes and millimetre measurements.
/// A geometry rectangle uses the same value type in landscape printer dots.
struct NiimbotLabelArea: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    private func intersection(_ other: Self) -> Self? {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return Self(x: left, y: top, width: right - left, height: bottom - top)
    }

    fileprivate func clipped(to other: Self) -> Self? { intersection(other) }
}

struct LabelPrintGeometry: Hashable, Sendable {
    let feedDots: Int
    let headDots: Int
    /// Integer dot edges, rounded inward to stay inside the usable region.
    let printableArea: NiimbotLabelArea
    /// The existing landscape-to-head packer supplies the ordinary 90° turn.
    let contentRotation: Int
    let usesFallbackArea: Bool
}

enum NiimbotLabelCatalogFailure: Error, LocalizedError {
    case invalidCatalog, invalidProduct

    var errorDescription: String? {
        "The label measurements could not be read. Choose the paper size manually."
    }
}

/// Only non-unique product metadata is stored in a prepared label snapshot.
/// RFID tag identifiers, roll serials and counters are never part of this type.
struct NiimbotLabelProduct: Codable, Hashable, Sendable {
    let code: String
    let width: Double
    let height: Double
    let rotation: Int
    let paperType: UInt8
    let flags: UInt8
    let inputAreas: [NiimbotLabelArea]
    let geometry: LabelPrintGeometry

    var isCable: Bool { flags & 1 != 0 }
    var isMultiRegion: Bool { flags & 2 != 0 }

    init(code: String, width: Double, height: Double, rotation: Int, paperType: UInt8,
         flags: UInt8 = 0, inputAreas: [NiimbotLabelArea]) throws {
        guard (1...32).contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }),
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100, height <= 100, [0, 90, 180, 270].contains(rotation),
              paperType == 1 || paperType == 5, flags <= 3, inputAreas.count <= 16,
              inputAreas.allSatisfy({ area in
                  [area.x, area.y, area.width, area.height].allSatisfy { $0.isFinite && abs($0) <= 200 }
                      && area.width > 0 && area.height > 0
              }) else { throw NiimbotLabelCatalogFailure.invalidProduct }
        self.code = code; self.width = width; self.height = height
        self.rotation = rotation; self.paperType = paperType; self.flags = flags
        self.inputAreas = inputAreas
        self.geometry = try Self.makeGeometry(width: width, height: height, rotation: rotation, areas: inputAreas)
    }

    private enum CodingKeys: String, CodingKey {
        case code, width, height, rotation, paperType, flags, inputAreas
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(code: values.decode(String.self, forKey: .code),
            width: values.decode(Double.self, forKey: .width), height: values.decode(Double.self, forKey: .height),
            rotation: values.decode(Int.self, forKey: .rotation), paperType: values.decode(UInt8.self, forKey: .paperType),
            flags: values.decode(UInt8.self, forKey: .flags),
            inputAreas: values.decode([NiimbotLabelArea].self, forKey: .inputAreas))
    }

    private static func makeGeometry(width: Double, height: Double, rotation: Int,
                                     areas: [NiimbotLabelArea]) throws -> LabelPrintGeometry {
        let portrait = rotation == 0 || rotation == 180
        let feed = portrait ? height : width, cross = portrait ? width : height
        let feedDots = Int((feed * 8).rounded())
        guard (1...800).contains(feedDots), cross <= 15 else { throw NiimbotLabelCatalogFailure.invalidProduct }
        let sourceBounds = NiimbotLabelArea(x: 0, y: 0, width: width, height: height)
        let headOffset = (cross - 12) / 2
        let landscapeBounds = NiimbotLabelArea(x: 0, y: 0, width: Double(feedDots) / 8, height: 12)
        let candidates = areas.isEmpty ? [sourceBounds] : areas
        let usable: [NiimbotLabelArea] = candidates.compactMap { area in
            guard let clipped = area.clipped(to: sourceBounds) else { return nil }
            let normalized: NiimbotLabelArea
            switch rotation {
            case 0:
                normalized = NiimbotLabelArea(x: clipped.y, y: width - clipped.maxX,
                    width: clipped.height, height: clipped.width)
            case 180:
                normalized = NiimbotLabelArea(x: height - clipped.maxY, y: clipped.x,
                    width: clipped.height, height: clipped.width)
            case 270:
                normalized = NiimbotLabelArea(x: width - clipped.maxX, y: height - clipped.maxY,
                    width: clipped.width, height: clipped.height)
            default:
                normalized = clipped
            }
            let positioned = NiimbotLabelArea(x: normalized.x, y: normalized.y - headOffset,
                width: normalized.width, height: normalized.height)
            guard let bounded = positioned.clipped(to: landscapeBounds) else { return nil }
            let left = ceil(bounded.x * 8), top = ceil(bounded.y * 8)
            let right = floor(bounded.maxX * 8), bottom = floor(bounded.maxY * 8)
            guard right > left, bottom > top else { return nil }
            return NiimbotLabelArea(x: left, y: top, width: right - left, height: bottom - top)
        }
        // A queue copy always draws one design on one physical label, even on
        // cable or multi-region stock. Do not silently multiply printed tags.
        guard let printable = usable.enumerated().max(by: { a, b in
            let first = a.element.width * a.element.height, second = b.element.width * b.element.height
            return first == second ? a.offset > b.offset : first < second
        })?.element else { throw NiimbotLabelCatalogFailure.invalidProduct }
        return LabelPrintGeometry(feedDots: feedDots, headDots: 96, printableArea: printable,
            contentRotation: rotation == 180 || rotation == 270 ? 180 : 0,
            usesFallbackArea: areas.isEmpty)
    }
}

/// The small bundled catalog is decoded once. Missing or invalid resources
/// preserve the existing manual paper path; lookup never starts a network call.
struct NiimbotLabelCatalog: Sendable {
    static let shared: Self = {
        guard let url = Bundle.main.url(forResource: "NiimbotProducts", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? Self(data: data) else { return .empty }
        return catalog
    }()
    private static let empty = Self(products: [:])
    private let products: [String: NiimbotLabelProduct]
    var count: Int { products.count }
    var allProducts: [NiimbotLabelProduct] { products.values.sorted { $0.code < $1.code } }
    func product(code: String) -> NiimbotLabelProduct? { products[code] }

    private init(products: [String: NiimbotLabelProduct]) { self.products = products }

    init(data: Data) throws {
        guard data.count <= 1_000_000 else { throw NiimbotLabelCatalogFailure.invalidCatalog }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.units == "mm",
              document.fields == ["width", "height", "rotate", "paperType", "flags", "inputAreas"],
              document.areaFields == ["x", "y", "w", "h"],
              document.flagBits == ["cable": 1, "multiRegion": 2],
              document.defaults.margin == [0, 0, 0, 0], document.defaults.areaType == "text",
              (1...5_000).contains(document.products.count) else { throw NiimbotLabelCatalogFailure.invalidCatalog }
        var products: [String: NiimbotLabelProduct] = [:]
        for (code, row) in document.products {
            products[code] = try NiimbotLabelProduct(code: code, width: row.width, height: row.height,
                rotation: row.rotation, paperType: row.paperType, flags: row.flags, inputAreas: row.areas)
        }
        self.products = products
    }

    private struct Document: Decodable {
        let version: Int
        let units: String
        let fields: [String]
        let areaFields: [String]
        let flagBits: [String: Int]
        let defaults: Defaults
        let products: [String: Row]
    }
    private struct Defaults: Decodable { let margin: [Double]; let areaType: String }
    private struct Row: Decodable {
        let width: Double
        let height: Double
        let rotation: Int
        let paperType: UInt8
        let flags: UInt8
        let areas: [NiimbotLabelArea]

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            width = try row.decode(Double.self); height = try row.decode(Double.self)
            rotation = try row.decode(Int.self); paperType = try row.decode(UInt8.self); flags = try row.decode(UInt8.self)
            let rectangles = try row.decode([[Double]].self)
            guard row.isAtEnd, rectangles.count <= 16,
                  rectangles.allSatisfy({ $0.count == 4 }) else { throw NiimbotLabelCatalogFailure.invalidCatalog }
            areas = rectangles.map { NiimbotLabelArea(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }
    }
}
