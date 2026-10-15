import Foundation

struct CardIdentity: Codable, Hashable {
    var game: String
    var productID: String
    var skuID: String?
    var printing: String
    var language: String = "English"
    var condition: String = "Near Mint"
}

struct CardPrinting: Codable, Hashable {
    var label: String
    var skuID: String?
    var marketPrice: Decimal?
}

struct CardCandidate: Identifiable, Codable, Hashable {
    var id: String { identity.productID + "|" + identity.printing + "|" + (identity.skuID ?? "") }
    var identity: CardIdentity
    var name: String
    var set: String
    var number: String
    var marketPrice: Decimal?
    var imageURL: URL?
    var confidence: Double
    var printings: [String]
    var printingQuotes: [CardPrinting]? = nil
    var requiresPrintingSelection: Bool? = nil
}

struct ScanResult: Identifiable {
    let id: UUID
    var candidates: [CardCandidate]
    var accepted: Bool
    var same: Bool
    var visible: Bool = true
}

/// Tracks recognition episodes, independently of inventory identity and quantity.
struct RecognitionGate {
    private(set) var episode = UUID()
    private var sourceID: UUID?
    private var consumed = false
    var hasAdded: Bool { consumed }
    mutating func receive(_ result: ScanResult) {
        guard result.visible else { return }
        if result.id != sourceID {
            episode = UUID()
            consumed = false
        }
        sourceID = result.id
    }
    mutating func markAdded() { consumed = true }
    mutating func consumeAutomatic(_ result: ScanResult) -> Bool {
        guard !consumed, result.visible, !result.same, result.accepted,
              let first = result.candidates.first, first.confidence >= 90, first.requiresPrintingSelection != true else { return false }
        consumed = true
        return true
    }
}

struct ExportRow {
    var card: CardCandidate
    var quantity: Int
}

enum CSVExportService {
    static func escape(_ text: String) -> String {
        // Spreadsheet formula protection, followed by RFC 4180 quoting.
        let risky = ["=", "+", "-", "@", "\t", "\r", "\n"].contains { text.hasPrefix($0) }
        let safe = risky ? "'" + text : text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func number(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }
    static func render(_ rows: [ExportRow]) -> String {
        let header = "Game,Name,Set,Number,Product ID,SKU ID,Printing,Language,Condition,Quantity,Market Price,Total Value"
        return ([header] + rows.map { row in
            let c = row.card
            return [c.identity.game, c.name, c.set, c.number, c.identity.productID,
                    c.identity.skuID ?? "", c.identity.printing, c.identity.language,
                    c.identity.condition, String(row.quantity), number(c.marketPrice),
                    number(c.marketPrice.map { $0 * Decimal(row.quantity) })]
                .map(escape).joined(separator: ",")
        }).joined(separator: "\r\n") + "\r\n"
    }
}

extension Decimal {
    var money: String { NSDecimalNumber(decimal: self).doubleValue.formatted(.currency(code: "USD")) }
}
