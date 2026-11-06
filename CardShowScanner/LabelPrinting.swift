import Foundation
import Observation

enum InventoryLabelStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case priceOnly, cardDetails
    var id: Self { self }
    var title: String { self == .priceOnly ? "PokéDen price" : "Card details" }
}

enum LabelPricePosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right
    var id: Self { self }
    var title: String { self == .left ? "Price Left" : "Price Right" }
}

/// Manual presets retain their original JSON strings. Detected stock carries
/// its own immutable measurements so saved queues never depend on a later
/// catalog lookup or the currently connected roll.
struct InventoryLabelSize: Codable, CaseIterable, Hashable, Identifiable, Sendable {
    private let preset: String?
    let product: NiimbotLabelProduct?
    static let small30x14 = Self(preset: "small30x14")
    static let medium40x12 = Self(preset: "medium40x12")
    static let small30x15 = Self(preset: "small30x15")
    static let large50x14 = Self(preset: "large50x14")
    static let allCases: [Self] = [.small30x14, .medium40x12, .small30x15, .large50x14]

    private init(preset: String) { self.preset = preset; product = nil }
    init(product: NiimbotLabelProduct) throws {
        guard (1...800).contains(product.geometry.feedDots), product.geometry.headDots == 96 else {
            throw NiimbotLabelCatalogFailure.invalidProduct
        }
        preset = nil; self.product = product
    }
    init?(rawValue: String) {
        guard let value = Self.allCases.first(where: { $0.preset == rawValue }) else { return nil }
        self = value
    }

    var id: Self { self }
    var rawValue: String {
        if let preset { return preset }
        guard let product else { return "" }
        // Existing preparation caches use this identity. Include the complete
        // profile, not just its barcode, so changed geometry cannot reuse art.
        let values = [product.width, product.height, Double(product.rotation), Double(product.paperType), Double(product.flags)]
            + product.inputAreas.flatMap { [$0.x, $0.y, $0.width, $0.height] }
        return "stock:" + product.code + ":" + values.map { String($0) }.joined(separator: ":")
    }
    var geometry: LabelPrintGeometry? { product?.geometry }
    var title: String {
        if let product {
            func value(_ number: Double) -> String {
                number.rounded() == number ? String(Int(number)) : String(number)
            }
            return "\(value(product.width)) × \(value(product.height)) mm"
        }
        switch preset {
        case "medium40x12": return "40 × 12 mm"
        case "small30x15": return "30 × 15 mm"
        case "large50x14": return "50 × 14 mm"
        default: return "30 × 14 mm"
        }
    }
    var feedDots: Int {
        if let geometry { return geometry.feedDots }
        switch preset {
        case "medium40x12": return 320
        case "large50x14": return 400
        default: return 240
        }
    }
    var headDots: Int { 96 }

    private enum CodingKeys: String, CodingKey { case product }
    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            guard let preset = Self(rawValue: value) else { throw NiimbotLabelCatalogFailure.invalidProduct }
            self = preset
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(product: values.decode(NiimbotLabelProduct.self, forKey: .product))
        }
    }
    func encode(to encoder: Encoder) throws {
        if let preset {
            var value = encoder.singleValueContainer(); try value.encode(preset)
        } else {
            var value = encoder.container(keyedBy: CodingKeys.self); try value.encode(product, forKey: .product)
        }
    }
}

/// RFID detection applies to this connection only. It never overwrites the
/// remembered manual paper choice or the independently saved price position.
@MainActor @Observable final class LabelPaperPreferences {
    static let shared: LabelPaperPreferences = {
        let fixture = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--show-transactions-fixture-id=")
        }).map { String($0.dropFirst("--show-transactions-fixture-id=".count)) }
        let key = fixture.map { "niimbotLabelSize.fixture." + $0 } ?? "niimbotLabelSize"
        let positionKey = fixture.map { "niimbotLabelPricePosition.fixture." + $0 } ?? "niimbotLabelPricePosition"
        return LabelPaperPreferences(defaults: .standard, key: key, pricePositionKey: positionKey)
    }()

    private(set) var manualSize: InventoryLabelSize
    private(set) var detectedProduct: NiimbotLabelProduct?
    private(set) var pricePosition: LabelPricePosition
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let pricePositionKey: String

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, key: "niimbotLabelSize", pricePositionKey: "niimbotLabelPricePosition")
    }

    private init(defaults: UserDefaults, key: String, pricePositionKey: String) {
        self.defaults = defaults
        self.key = key
        self.pricePositionKey = pricePositionKey
        manualSize = defaults.string(forKey: key).flatMap(InventoryLabelSize.init(rawValue:)) ?? .small30x14
        pricePosition = defaults.string(forKey: pricePositionKey).flatMap(LabelPricePosition.init(rawValue:)) ?? .right
    }

    var size: InventoryLabelSize {
        if let detectedProduct, let size = try? InventoryLabelSize(product: detectedProduct) { return size }
        return manualSize
    }

    var availableSizes: [InventoryLabelSize] {
        if size.product != nil { return InventoryLabelSize.allCases + [size] }
        return InventoryLabelSize.allCases
    }

    func updateDetectedProduct(_ product: NiimbotLabelProduct?) {
        detectedProduct = product
    }

    func select(_ size: InventoryLabelSize) {
        guard detectedProduct == nil, Self.isManual(size) else { return }
        manualSize = size
        defaults.set(size.rawValue, forKey: key)
    }

    private static func isManual(_ size: InventoryLabelSize) -> Bool { InventoryLabelSize.allCases.contains(size) }

    func selectPricePosition(_ position: LabelPricePosition) {
        pricePosition = position
        defaults.set(position.rawValue, forKey: pricePositionKey)
    }
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
    var style: InventoryLabelStyle = .priceOnly
    var paperSize: InventoryLabelSize = .small30x14
    var pricePosition: LabelPricePosition = .right
    var marketValue: Decimal?
    var profitInputs: TagProfitInputs
    var isBulk = false
    var isManualOverride = false
    static let maximumCopies = 100

    init(item: ShowInventoryItem, preferences: TagPricingPreferences = .init(), approval: TagApprovalRecord? = nil) {
        id = item.id
        cardName = Self.singleLine(item.card.name, maximumCharacters: 500)
        cardNumber = Self.singleLine(item.card.number, maximumCharacters: 100)
        condition = Self.shortCondition(item.card.identity.condition)
        marketValue = item.card.marketPrice
        profitInputs = preferences.profitInputs(for: item)
        // Printing uses the stored final tag and category, including an
        // individual $0 price. Market rounding is only a fallback for new lots.
        let tag = approval?.approvedTag ?? TagPricing.evaluate(market: marketValue, inputs: profitInputs).tag
        isBulk = tag == .twoForOne
        isManualOverride = approval?.isManualOverride ?? false
        askingPriceText = tag?.integerPriceCents.map(Self.inputText) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, cardName, cardNumber, condition, askingPriceText, copies, style, paperSize, pricePosition
        case marketValue, profitInputs, isBulk, isManualOverride
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        cardName = try values.decode(String.self, forKey: .cardName)
        cardNumber = try values.decode(String.self, forKey: .cardNumber)
        condition = try values.decode(String.self, forKey: .condition)
        askingPriceText = try values.decode(String.self, forKey: .askingPriceText)
        copies = try values.decode(Int.self, forKey: .copies)
        style = try values.decode(InventoryLabelStyle.self, forKey: .style)
        paperSize = try values.decode(InventoryLabelSize.self, forKey: .paperSize)
        if values.contains(.pricePosition) {
            pricePosition = try values.decode(LabelPricePosition.self, forKey: .pricePosition)
        } else { pricePosition = .right }
        marketValue = try values.decodeIfPresent(Decimal.self, forKey: .marketValue)
        profitInputs = try values.decode(TagProfitInputs.self, forKey: .profitInputs)
        isBulk = try values.decode(Bool.self, forKey: .isBulk)
        isManualOverride = try values.decode(Bool.self, forKey: .isManualOverride)
    }

    var priceCents: Int64? { isBulk ? nil : ShowBudgetMoney.parse(askingPriceText) }
    var tag: StickerPrice? {
        if isBulk { return .twoForOne }
        guard let cents = priceCents, cents % 100 == 0 else { return nil }
        return .individual(cents)
    }
    var priceText: String? { tag?.displayText }
    var pricing: TagPriceEvaluation { TagPricing.evaluate(market: marketValue, inputs: profitInputs) }
    var pricingWarnings: [String] {
        if isBulk { return pricing.reasons.map(\.message) }
        guard let cents = priceCents else { return [InventoryLabelFailure.invalidPrice.localizedDescription] }
        var reasons = TagPricing.validateActualPriceCents(cents, inputs: profitInputs)
        for reason in pricing.reasons where reason == .missingMarket || reason == .invalidMarket {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        if cents % 100 != 0 { return [InventoryLabelFailure.wholeDollarRequired.localizedDescription] + reasons.map(\.message) }
        return reasons.map(\.message)
    }
    var suggestedOfferCents: Int64? {
        guard !isBulk, pricingWarnings.isEmpty, let priceCents, let floor = pricing.preferredFloorCents else { return nil }
        return TagPricing.suggestedOfferCents(stickerCents: priceCents, preferredFloorCents: floor)
    }

    mutating func useSuggestedPrice() {
        let suggestion = pricing.tag
        isBulk = suggestion == .twoForOne
        askingPriceText = suggestion?.integerPriceCents.map(Self.inputText) ?? ""
        isManualOverride = false
    }

    func validate() throws {
        guard !cardName.isEmpty, cardName.count <= 500, cardNumber.count <= 100,
              condition.count <= 100, askingPriceText.count <= 40 else { throw InventoryLabelFailure.invalidText }
        if !isBulk {
            guard let priceCents else { throw InventoryLabelFailure.invalidPrice }
            guard priceCents % 100 == 0 else { throw InventoryLabelFailure.wholeDollarRequired }
        }
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
    case invalidPrice, invalidCopies, invalidRaster, invalidText, wholeDollarRequired
    var errorDescription: String? {
        switch self {
        case .invalidPrice: return "Enter a valid asking price before preparing this label."
        case .invalidCopies: return "Choose between 1 and \(InventoryLabelDraft.maximumCopies) labels per card."
        case .invalidRaster: return "This label could not be prepared for the selected paper."
        case .invalidText: return "Review the card information before preparing its label."
        case .wholeDollarRequired: return "Individual price tags use whole dollars. Review this price before printing."
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
        case .unsupportedPrinter: return "This printer or firmware has not been identified as a supported D110 or D110-M."
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

/// Every callback is awaited: the queue must persist the next sending state
/// before radio writes, and each confirmed receipt before advancing a page.
@MainActor protocol LabelBatchPrinterSending: LabelPrinterSending {
    func printBatch(
        _ rasters: [LabelRaster],
        beforePage: @escaping @MainActor (Int) async throws -> Void,
        afterPage: @escaping @MainActor (Int) async throws -> Void
    ) async -> LabelSendOutcome
}

/// A printer may buffer several physical copies. Each group is journaled
/// before dispatch; cumulative completion proofs are saved atomically.
@MainActor protocol LabelContinuousPrinterSending: LabelPrinterSending {
    func printContinuously(
        _ rasters: [LabelRaster],
        beforePages: @escaping @MainActor ([Int]) async throws -> Void,
        afterPages: @escaping @MainActor ([Int]) async throws -> Void
    ) async -> LabelSendOutcome
}
