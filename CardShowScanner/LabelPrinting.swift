import Foundation

enum InventoryLabelStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case priceOnly, cardDetails
    var id: Self { self }
    var title: String { self == .priceOnly ? "Price only" : "Card details" }
}

/// The printable head is 12 mm wide. Larger stock leaves its factory margins;
/// the long dimension runs along the paper feed, at eight dots per millimetre.
enum InventoryLabelSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small30x14, medium40x12, large50x14
    var id: Self { self }
    var title: String {
        switch self {
        case .small30x14: return "30 × 14 mm"
        case .medium40x12: return "40 × 12 mm"
        case .large50x14: return "50 × 14 mm"
        }
    }
    var feedDots: Int {
        switch self { case .small30x14: return 240; case .medium40x12: return 320; case .large50x14: return 400 }
    }
    var headDots: Int { 96 }
}

/// A local label draft is independent of quotes, inventory and financial data.
/// Its identity points to an inventory lot; editing it never edits that lot.
struct InventoryLabelDraft: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let cardName: String
    let cardNumber: String
    let condition: String
    var askingPriceText: String
    var copies: Int = 1
    var style: InventoryLabelStyle = .cardDetails
    var paperSize: InventoryLabelSize = .small30x14
    static let maximumCopies = 100

    init(item: ShowInventoryItem) {
        id = item.id
        cardName = Self.singleLine(item.card.name, maximumCharacters: 500)
        cardNumber = Self.singleLine(item.card.number, maximumCharacters: 100)
        condition = Self.shortCondition(item.card.identity.condition)
        askingPriceText = ""
        if let price = item.card.marketPrice, !price.isNaN, price >= 0 {
            var value = price, rounded = Decimal.zero
            NSDecimalRound(&rounded, &value, 0, .plain)
            let cents = rounded * 100
            if !cents.isNaN, cents <= Decimal(ShowBudgetMoney.maximumCents) {
                askingPriceText = Self.inputText(NSDecimalNumber(decimal: cents).int64Value)
            }
        }
    }

    var priceCents: Int64? { ShowBudgetMoney.parse(askingPriceText) }
    var priceText: String? { priceCents.map { ShowBudgetMoney.decimal($0).money } }

    func validate() throws {
        guard !cardName.isEmpty, cardName.count <= 500, cardNumber.count <= 100,
              condition.count <= 100, askingPriceText.count <= 40 else { throw InventoryLabelFailure.invalidText }
        guard priceCents != nil else { throw InventoryLabelFailure.invalidPrice }
        guard (1...Self.maximumCopies).contains(copies) else { throw InventoryLabelFailure.invalidCopies }
    }

    static func inputText(_ cents: Int64) -> String {
        "\(cents / 100)." + String(format: "%02lld", cents % 100)
    }
    static func singleLine(_ text: String, maximumCharacters: Int) -> String {
        String(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(maximumCharacters))
    }
    static func shortCondition(_ text: String) -> String {
        let value = singleLine(text, maximumCharacters: 100)
        switch value.lowercased() {
        case "near mint", "nm": return "NM"
        case "lightly played", "lp": return "LP"
        case "moderately played", "mp": return "MP"
        case "heavily played", "hp": return "HP"
        case "damaged", "dmg": return "DMG"
        default: return value.isEmpty ? "Unknown" : value
        }
    }
}

/// One-bit rows in printer orientation: MSB first, black=1. This same raster
/// supplies the preview and the wire encoder, so the two cannot drift apart.
struct LabelRaster: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let data: Data

    func validate() throws {
        guard width == 96, (1...800).contains(height), data.count == 12 * height,
              data.contains(where: { $0 != 0 }) else { throw InventoryLabelFailure.invalidRaster }
    }
}

enum InventoryLabelFailure: Error, LocalizedError, Equatable {
    case invalidPrice, invalidCopies, invalidRaster, invalidText
    var errorDescription: String? {
        switch self {
        case .invalidPrice: return "Enter a valid asking price before preparing this label."
        case .invalidCopies: return "Choose between 1 and \(InventoryLabelDraft.maximumCopies) labels per card."
        case .invalidRaster: return "This label could not be prepared for the selected paper."
        case .invalidText: return "Review the card information before preparing its label."
        }
    }
}

enum LabelPrinterIssue: String, Error, Codable, LocalizedError, Equatable, Sendable {
    case notConnected, bluetoothUnavailable, permissionDenied, notActive, unsupportedPrinter
    case invalidLabel, printerNotReady, printerBusy, writeFailed, responseTimeout
    case connectionLost, unsupportedResponse, cancelled, paperMismatch

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect your printer before printing."
        case .bluetoothUnavailable: return "Turn on Bluetooth to find your printer."
        case .permissionDenied: return "Allow Bluetooth access for this app in iPhone Settings."
        case .notActive: return "Keep the app open while printing. Review the queue before continuing."
        case .unsupportedPrinter: return "This printer or firmware has not been identified as a supported D110."
        case .invalidLabel: return "Review this label and its paper size before printing."
        case .printerNotReady: return "Check that the printer is on, closed and loaded with labels."
        case .printerBusy: return "The printer is busy. Wait for its current job to finish."
        case .writeFailed: return "The printer connection could not send this label."
        case .responseTimeout: return "The printer did not confirm completion. Check its output before retrying."
        case .connectionLost: return "The printer disconnected. Check its output before retrying."
        case .unsupportedResponse: return "The printer returned an unsupported reply. Check its output before retrying."
        case .cancelled: return "Printing stopped. Check the current label before retrying."
        case .paperMismatch: return "Check that the selected label size matches the paper in your printer."
        }
    }
}

enum LabelSendOutcome: Equatable, Sendable {
    case completed
    case notSent(LabelPrinterIssue)
    case uncertain(LabelPrinterIssue)
}

@MainActor protocol LabelPrinterSending: AnyObject {
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome
    func cancelPrinting()
}
