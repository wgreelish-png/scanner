import Foundation
import UIKit

/// A temporary label proposal. Editing or rendering it never changes stock,
/// market quotes, asking prices elsewhere, or the show ledger.
struct PriceTagDraft: Identifiable, Equatable, Sendable {
    static let maximumCopies = 20

    let inventoryID: UUID
    let cardName: String
    let cardNumber: String
    let condition: String
    var askingPriceText: String
    var copies: Int = 1
    var id: UUID { inventoryID }

    init(item: ShowInventoryItem) {
        inventoryID = item.id
        cardName = item.card.name
        cardNumber = item.card.number
        condition = Self.shortCondition(item.card.identity.condition)
        // Use one copy even when the stock row contains many physical cards.
        // This is the same per-copy rounding used by a default show sale.
        let line = ShowTransactionCardLine(inventoryID: item.id, card: item.card, quantity: 1)
        askingPriceText = ShowSaleMath.suggestedTotal([line]).map { String($0 / 100) } ?? ""
    }

    var askingPriceCents: Int64? { ShowBudgetMoney.parse(askingPriceText) }

    /// Integer arithmetic preserves manually entered cents without locale
    /// separators or a floating-point conversion.
    var priceText: String? {
        guard let cents = askingPriceCents else { return nil }
        let dollars = String(cents / 100)
        let remainder = cents % 100
        guard remainder != 0 else { return "$" + dollars }
        return "$" + dollars + "." + (remainder < 10 ? "0" : "") + String(remainder)
    }

    var validationMessage: String? {
        guard askingPriceCents != nil else { return "Enter an asking price in USD, with up to two decimal places." }
        guard (1...Self.maximumCopies).contains(copies) else { return "Choose between 1 and \(Self.maximumCopies) labels." }
        return nil
    }

    static func shortCondition(_ condition: String) -> String {
        let clean = singleLine(condition, maximumCharacters: 100)
        let key = clean.uppercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "NM", "NEARMINT", "NEARMINTORMINT", "NEARMINTORBETTER": return "NM"
        case "LP", "LIGHTPLAY", "LIGHTLYPLAYED": return "LP"
        case "MP", "MODERATEPLAY", "MODERATELYPLAYED": return "MP"
        case "HP", "HEAVYPLAY", "HEAVILYPLAYED": return "HP"
        case "DMG", "DAMAGED": return "DMG"
        default:
            // Unknown conditions and grades must not become a false NM claim.
            return clean.isEmpty ? "Unknown" : String(clean.prefix(12))
        }
    }

    fileprivate static func singleLine(_ value: String, maximumCharacters: Int) -> String {
        String(value.prefix(maximumCharacters)).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum PriceTagRenderFailure: LocalizedError, Equatable {
    case invalidPrice, invalidCopies, invalidBitmap, imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPrice: return "Enter an asking price in USD, with up to two decimal places."
        case .invalidCopies: return "Choose between 1 and \(PriceTagDraft.maximumCopies) labels."
        case .invalidBitmap: return "The label image has an unsupported size."
        case .imageCreationFailed: return "The label preview could not be created. Try again."
        }
    }
}

struct PriceTagBitmap {
    let width: Int
    /// Feed columns, each containing four bytes for the 32 print-head rows.
    /// Row y uses byte (3 - y / 8), bit (7 - y % 8); a set bit prints black.
    let packedColumns: Data
    let previewCGImage: CGImage
    var previewImage: UIImage { UIImage(cgImage: previewCGImage, scale: 1, orientation: .up) }
}

/// The LetraTag's 12 mm tape has 32 addressable head rows. Width runs along
/// the tape feed, rather than across the tape. The preview is the exact binary
/// raster that is packed for the printer, at one image point per head dot.
@MainActor enum PriceTagRenderer {
    static let height = 32
    static let minimumWidth = 30
    static let maximumWidth = 600
    static let verticalMargin = 2
    private static let horizontalMargin: CGFloat = 4

    static func render(_ draft: PriceTagDraft) throws -> PriceTagBitmap {
        guard let price = draft.priceText else { throw PriceTagRenderFailure.invalidPrice }
        guard (1...PriceTagDraft.maximumCopies).contains(draft.copies) else { throw PriceTagRenderFailure.invalidCopies }

        // Fixed physical dot sizes keep labels legible regardless of the
        // device's screen scale or preferred Dynamic Type size.
        let titleFont = UIFont.systemFont(ofSize: 9, weight: .semibold)
        let priceFont = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        let conditionFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let name = PriceTagDraft.singleLine(draft.cardName, maximumCharacters: 500)
        let number = PriceTagDraft.singleLine(draft.cardNumber, maximumCharacters: 100)
        let condition = PriceTagDraft.singleLine(draft.condition, maximumCharacters: 12)
        let fullTitle = title(name: name, number: number)
        let priceWidth = measuredWidth(price, font: priceFont)
        let conditionWidth = measuredWidth(condition, font: conditionFont)
        let gap: CGFloat = condition.isEmpty ? 0 : 7
        let contentWidth = max(measuredWidth(fullTitle, font: titleFont), priceWidth + gap + conditionWidth)
        let width = min(maximumWidth, max(minimumWidth, Int(ceil(contentWidth + horizontalMargin * 2))))
        let available = CGFloat(width) - horizontalMargin * 2
        // The entire supported USD amount fits at 14 dots within 600 columns.
        // Do not truncate or reduce the font of an actual asking price.
        guard priceWidth <= available else { throw PriceTagRenderFailure.invalidBitmap }
        let titleText = fittedTitle(name: name, number: number, font: titleFont, width: available)
        let conditionText = truncated(condition, font: conditionFont, width: max(0, available - priceWidth - gap))

        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw PriceTagRenderFailure.imageCreationFailed }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: CGFloat(verticalMargin), width: CGFloat(width), height: CGFloat(height - verticalMargin * 2)))
        UIGraphicsPushContext(context)
        context.saveGState()
        // Fallback glyphs (for example emoji) can have taller font metrics.
        // Keep metadata within its own line so it cannot overprint the price.
        context.clip(to: CGRect(x: 0, y: 2, width: CGFloat(width), height: 11))
        draw(titleText, at: CGPoint(x: horizontalMargin, y: 2), font: titleFont)
        context.restoreGState()
        let priceY: CGFloat = 13
        draw(price, at: CGPoint(x: horizontalMargin, y: priceY), font: priceFont)
        let conditionY = priceY + priceFont.ascender - conditionFont.ascender
        draw(conditionText, at: CGPoint(x: horizontalMargin + priceWidth + gap, y: conditionY), font: conditionFont)
        UIGraphicsPopContext()
        guard let storage = context.data else { throw PriceTagRenderFailure.imageCreationFailed }
        let pixels = Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: UInt8.self), count: width * height))
        return try bitmap(grayscalePixels: pixels, width: width)
    }

    static func testLabel() throws -> PriceTagBitmap {
        let card = CardCandidate(identity: .init(game: "Test", productID: "printer-test", printing: "Test", condition: "Near Mint"),
            name: "TEST LABEL", set: "", number: "1", marketPrice: 10, confidence: 0, printings: [])
        return try render(PriceTagDraft(item: ShowInventoryItem(card: card, quantity: 1)))
    }

    /// Shared conversion for both text rendering and deterministic raster
    /// fixtures. The preview and wire data always use the same threshold.
    static func bitmap(grayscalePixels: [UInt8], width: Int) throws -> PriceTagBitmap {
        guard (minimumWidth...maximumWidth).contains(width), grayscalePixels.count == width * height else {
            throw PriceTagRenderFailure.invalidBitmap
        }
        let monochrome = grayscalePixels.map { $0 < 128 ? UInt8(0) : UInt8(255) }
        var packed = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            for y in 0..<height where monochrome[y * width + x] == 0 {
                packed[x * 4 + 3 - y / 8] |= UInt8(1 << (7 - y % 8))
            }
        }
        guard let provider = CGDataProvider(data: Data(monochrome) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PriceTagRenderFailure.imageCreationFailed
        }
        return PriceTagBitmap(width: width, packedColumns: Data(packed), previewCGImage: image)
    }

    private static func draw(_ text: String, at point: CGPoint, font: UIFont) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: UIColor.black])
    }

    private static func measuredWidth(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func title(name: String, number: String) -> String {
        let cardName = name.isEmpty ? "Card" : name
        return number.isEmpty ? cardName : cardName + " · #" + number.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    private static func fittedTitle(name: String, number: String, font: UIFont, width: CGFloat) -> String {
        let full = title(name: name, number: number)
        guard measuredWidth(full, font: font) > width else { return full }
        guard !number.isEmpty else { return truncated(full, font: font, width: width) }
        // Preserve a useful card number alongside a shortened card name.
        let suffix = truncated("#" + number.trimmingCharacters(in: CharacterSet(charactersIn: "#")), font: font, width: width * 0.4)
        let separator = " · "
        let remaining = width - measuredWidth(suffix + separator, font: font)
        return truncated(name.isEmpty ? "Card" : name, font: font, width: remaining) + separator + suffix
    }

    private static func truncated(_ text: String, font: UIFont, width: CGFloat) -> String {
        guard !text.isEmpty, width > 0 else { return "" }
        guard measuredWidth(text, font: font) > width else { return text }
        let ellipsis = "…"
        guard measuredWidth(ellipsis, font: font) <= width else { return "" }
        let characters = Array(text)
        var lower = 0, upper = characters.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if measuredWidth(String(characters.prefix(middle)) + ellipsis, font: font) <= width { lower = middle }
            else { upper = middle - 1 }
        }
        return String(characters.prefix(lower)) + ellipsis
    }
}
