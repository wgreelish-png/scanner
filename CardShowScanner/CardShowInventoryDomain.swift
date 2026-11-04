import Foundation
import CoreFoundation

struct CardShowInventoryLocation: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct CardShowInventoryRow: Equatable, Sendable {
    let inventoryID: Int
    let card: CardCandidate
    let quantity: Int
}

struct CardShowInventorySnapshot: Sendable {
    let location: CardShowInventoryLocation
    let rows: [CardShowInventoryRow]
    let fetchedAt: Date
}

enum CardShowInventoryFailure: LocalizedError, Equatable, Sendable {
    case signInRequired, locationNotFound, ambiguousLocation, locationChanged
    case invalidResponse, networkUnavailable, responseTooLarge, rateLimited, persistenceFailed, readOnlyList

    var diagnosticReason: String {
        switch self {
        case .signInRequired: return "sign_in_required"
        case .locationNotFound: return "location_not_found"
        case .ambiguousLocation: return "ambiguous_location"
        case .locationChanged: return "location_changed"
        case .invalidResponse: return "invalid_response"
        case .networkUnavailable: return "network_unavailable"
        case .responseTooLarge: return "response_too_large"
        case .rateLimited: return "rate_limited"
        case .persistenceFailed: return "persistence_failed"
        case .readOnlyList: return "read_only_list"
        }
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in to TCGTracking to refresh your Card Show inventory. Your saved copy is kept."
        case .locationNotFound:
            return "No active location named Card Show was found in this TCGTracking account. Your saved copy is kept."
        case .ambiguousLocation:
            return "More than one active Card Show location was returned. Give the intended location a unique Card Show name before importing."
        case .locationChanged:
            return "This account does not match the saved Card Show location. Sign in to the original account, or delete the local imported list before importing another account."
        case .invalidResponse:
            return "TCGTracking returned incomplete or changed inventory data. Your saved copy is kept; try Refresh again."
        case .networkUnavailable:
            return "Card Show inventory could not connect. You can keep using your saved copy and refresh when reception improves."
        case .responseTooLarge:
            return "This inventory exceeds the supported import size. Your saved copy is kept."
        case .rateLimited:
            return "TCGTracking temporarily limited inventory requests. Your saved copy is kept; wait before refreshing."
        case .persistenceFailed:
            return "Card Show inventory could not be saved. Your previous copy is kept; try Refresh again."
        case .readOnlyList:
            return "This list mirrors TCGTracking. Duplicate it to scan or edit cards locally."
        }
    }
}

/// Only fixed classifications and bounded positions are carried out of the
/// decoder. Source values, IDs, names, URLs and response messages are excluded.
struct CardShowInventoryValidationFailure: Error, Sendable {
    enum Stage: String, Equatable, Sendable { case session, response, envelope, locations, pagination, row, snapshot }
    enum Reason: String, Equatable, Sendable {
        case missingSession = "missing_session", responseURL = "response_url_mismatch"
        case httpAuthentication = "http_authentication", httpStatus = "http_status", rateLimited = "rate_limited"
        case contentType = "content_type", responseTooLarge = "response_too_large"
        case invalidJSON = "invalid_json", unsuccessful = "unsuccessful_response", authentication = "authentication_required"
        case locationsShape = "locations_shape", locationID = "location_id_invalid", duplicateLocation = "duplicate_location_id"
        case locationName = "location_name_invalid", locationActive = "location_active_invalid"
        case page = "page_invalid", pages = "pages_invalid", total = "total_invalid", limit = "limit_invalid"
        case inventoryType = "inventory_type_invalid", itemsShape = "items_shape", pageShape = "page_shape"
        case stockTotal = "stock_total_mismatch", customTotal = "custom_total_unsupported"
        case changingTotals = "changing_totals", duplicateInventory = "duplicate_inventory_id", finalCount = "final_count_mismatch"
        case inventoryID = "inventory_id_invalid", locationMismatch = "row_location_mismatch", quantity = "quantity_invalid"
        case productID = "product_id_invalid", skuID = "sku_id_invalid", name = "product_name_invalid"
        case set = "set_name_invalid", game = "game_name_invalid", printing = "printing_invalid"
        case condition = "condition_invalid", language = "language_invalid", number = "card_number_invalid"
        case price = "market_price_invalid", image = "image_url_invalid"
    }
    let failure: CardShowInventoryFailure
    let stage: Stage
    let reason: Reason
    var page: Int? = nil
    var recordIndex: Int? = nil
    init(_ stage: Stage, _ reason: Reason, failure: CardShowInventoryFailure = .invalidResponse,
         page: Int? = nil, recordIndex: Int? = nil) {
        self.failure = failure; self.stage = stage; self.reason = reason; self.page = page; self.recordIndex = recordIndex
    }
    var diagnosticFields: [String: String] {
        var fields = ["stage": stage.rawValue, "reason": reason.rawValue]
        if let page, (1...20).contains(page) { fields["page"] = String(page) }
        if let recordIndex, (0..<10_000).contains(recordIndex) { fields["record_index"] = String(recordIndex) }
        return fields
    }
}

/// Decode only the fields used by the local inventory. Account notes, costs,
/// automatic-price settings and marketplace account information are discarded.
enum CardShowInventoryDecoder {
    static let maximumPageBytes = 8 * 1_024 * 1_024
    static let pageLimit = 500
    static let maximumRows = 10_000
    static let maximumPages = maximumRows / pageLimit

    struct Page: Sendable {
        let page: Int
        let pages: Int
        let total: Int
        let rows: [CardShowInventoryRow]
        let invalidPriceRecords: Int

        var marketPriceDiagnosticFields: [String: String] {
            let priced = rows.filter { $0.card.marketPrice != nil }.count
            return ["priced_records": String(priced), "unpriced_records": String(rows.count - priced),
                    "invalid_price_records": String(invalidPriceRecords)]
        }
    }

    /// Decode numeric quotes from their JSON tokens rather than from an
    /// NSNumber's binary floating-point rendering. All inventory validation
    /// still uses the existing bounded envelope/row decoder below.
    private struct MarketPrices: Decodable {
        let items: [MarketPriceValue]
    }

    private struct MarketPriceValue: Decodable {
        let value: Decimal?
        private enum CodingKeys: String, CodingKey { case marketPrice = "market_price" }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            value = try? fields.decode(Decimal.self, forKey: .marketPrice)
        }
    }

    static func location(_ data: Data, expectedID: Int?) throws -> CardShowInventoryLocation {
        let body = try object(data)
        guard let locations = body["locations"] as? [[String: Any]], locations.count <= 10_000 else {
            throw CardShowInventoryValidationFailure(.locations, .locationsShape)
        }
        var seen = Set<Int>()
        var matches: [CardShowInventoryLocation] = []
        for (index, row) in locations.enumerated() {
            guard let id = integer(row["location_id"]), id > 0 else {
                throw CardShowInventoryValidationFailure(.locations, .locationID, recordIndex: index)
            }
            guard seen.insert(id).inserted else {
                throw CardShowInventoryValidationFailure(.locations, .duplicateLocation, recordIndex: index)
            }
            guard let name = text(row["name"], maximum: 200), !name.isEmpty else {
                throw CardShowInventoryValidationFailure(.locations, .locationName, recordIndex: index)
            }
            guard let active = integer(row["is_active"]), active == 0 || active == 1 else {
                throw CardShowInventoryValidationFailure(.locations, .locationActive, recordIndex: index)
            }
            if active == 1 && normalized(name) == "card show" {
                matches.append(.init(id: id, name: name))
            }
        }
        if let expectedID {
            guard expectedID > 0, let saved = matches.first(where: { $0.id == expectedID }) else {
                throw CardShowInventoryFailure.locationChanged
            }
            return saved
        }
        guard !matches.isEmpty else { throw CardShowInventoryFailure.locationNotFound }
        guard matches.count == 1 else { throw CardShowInventoryFailure.ambiguousLocation }
        return matches[0]
    }

    static func page(_ data: Data, location: CardShowInventoryLocation, requestedPage: Int) throws -> Page {
        do {
            let body = try object(data)
            guard let page = integer(body["page"]), page == requestedPage, page > 0 else {
                throw CardShowInventoryValidationFailure(.pagination, .page)
            }
            guard let returnedPages = integer(body["pages"]), returnedPages >= 0 else {
                throw CardShowInventoryValidationFailure(.pagination, .pages)
            }
            guard let total = integer(body["total"]), total >= 0 else {
                throw CardShowInventoryValidationFailure(.pagination, .total)
            }
            guard let limit = integer(body["limit"]), limit == pageLimit else {
                throw CardShowInventoryValidationFailure(.pagination, .limit)
            }
            guard let type = text(body["inventory_type"], maximum: 40), type == "stock" else {
                throw CardShowInventoryValidationFailure(.pagination, .inventoryType)
            }
            guard let items = body["items"] as? [[String: Any]], items.count <= limit else {
                throw CardShowInventoryValidationFailure(.pagination, .itemsShape)
            }
            let pages = max(1, returnedPages)
            guard returnedPages > 0 || total == 0 else { throw CardShowInventoryValidationFailure(.pagination, .pages) }
            guard total <= maximumRows, pages <= maximumPages else {
                throw CardShowInventoryValidationFailure(.pagination, .responseTooLarge, failure: .responseTooLarge)
            }
            guard pages == max(1, (total + limit - 1) / limit), page <= pages,
                  items.count == min(limit, max(0, total - (page - 1) * limit)) else {
                throw CardShowInventoryValidationFailure(.pagination, .pageShape)
            }
            if let stockTotal = body["stock_total"], integer(stockTotal) != total {
                throw CardShowInventoryValidationFailure(.pagination, .stockTotal)
            }
            if let customTotal = body["custom_total"], integer(customTotal) != 0 {
                throw CardShowInventoryValidationFailure(.pagination, .customTotal)
            }
            guard let prices = try? JSONDecoder().decode(MarketPrices.self, from: data),
                  prices.items.count == items.count else {
                throw CardShowInventoryValidationFailure(.pagination, .itemsShape)
            }
            var seen = Set<Int>()
            var invalidPriceRecords = 0
            let rows = try items.enumerated().map { index, item -> CardShowInventoryRow in
                do {
                    let price = marketPrice(item["market_price"], numericPrice: prices.items[index].value)
                    if price.invalid { invalidPriceRecords += 1 }
                    let row = try inventoryRow(item, location: location, marketPrice: price.value)
                    guard seen.insert(row.inventoryID).inserted else {
                        throw CardShowInventoryValidationFailure(.row, .duplicateInventory)
                    }
                    return row
                } catch var error as CardShowInventoryValidationFailure {
                    error.recordIndex = index; throw error
                }
            }
            return .init(page: page, pages: pages, total: total, rows: rows, invalidPriceRecords: invalidPriceRecords)
        } catch var error as CardShowInventoryValidationFailure {
            error.page = requestedPage; throw error
        }
    }

    private static func inventoryRow(_ item: [String: Any], location: CardShowInventoryLocation,
                                     marketPrice: Decimal?) throws -> CardShowInventoryRow {
        guard let inventoryID = integer(item["inventory_id"]), inventoryID > 0 else { throw invalidRow(.inventoryID) }
        guard integer(item["location_id"]) == location.id else { throw invalidRow(.locationMismatch) }
        guard let quantity = integer(item["quantity"]), (0...1_000_000).contains(quantity) else { throw invalidRow(.quantity) }
        guard let productID = integer(item["product_id"]), productID > 0 else { throw invalidRow(.productID) }
        guard let skuID = integer(item["sku_id"]), skuID > 0 else { throw invalidRow(.skuID) }
        guard let name = text(item["product_name"], maximum: 500), !name.isEmpty else { throw invalidRow(.name) }
        guard let set = text(item["set_name"], maximum: 500), !set.isEmpty else { throw invalidRow(.set) }
        guard let game = text(item["game_name"], maximum: 200), !game.isEmpty else { throw invalidRow(.game) }
        guard let printing = text(item["variant_name"], maximum: 200), !printing.isEmpty else { throw invalidRow(.printing) }
        guard let condition = text(item["condition_name"], maximum: 200), !condition.isEmpty else { throw invalidRow(.condition) }
        guard let language = text(item["language_name"], maximum: 200), !language.isEmpty else { throw invalidRow(.language) }
        guard item["inventory_type"] == nil || item["inventory_type"] as? String == "stock" else { throw invalidRow(.inventoryType) }
        if let returnedName = item["location_name"] {
            guard let name = text(returnedName, maximum: 500), normalized(name) == normalized(location.name) else {
                throw invalidRow(.locationName)
            }
        }
        let number: String
        if item["ext_number"] == nil || item["ext_number"] is NSNull { number = "" }
        else {
            guard let returned = text(item["ext_number"], maximum: 100) else { throw invalidRow(.number) }
            number = returned
        }
        let image: URL?
        if item["image_url"] == nil || item["image_url"] is NSNull || item["image_url"] as? String == "" { image = nil }
        else {
            guard let raw = text(item["image_url"], maximum: 2_048), let url = URL(string: raw),
                  url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw invalidRow(.image)
            }
            image = url
        }
        let card = CardCandidate(identity: .init(game: normalizedGame(game), productID: "p:\(productID)", skuID: String(skuID),
            printing: printing, language: language, condition: condition), name: name, set: set, number: number,
            marketPrice: marketPrice, imageURL: image, confidence: 0, printings: [printing])
        return .init(inventoryID: inventoryID, card: card, quantity: quantity)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumPageBytes else {
            throw CardShowInventoryValidationFailure(.envelope, .responseTooLarge, failure: .responseTooLarge)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CardShowInventoryValidationFailure(.envelope, .invalidJSON)
        }
        guard let success = body["success"] as? NSNumber, CFGetTypeID(success) == CFBooleanGetTypeID(), success.boolValue else {
            let error = [body["error"], body["message"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            if ["auth", "login", "log in", "sign in", "session"].contains(where: { error.contains($0) }) {
                throw CardShowInventoryValidationFailure(.envelope, .authentication, failure: .signInRequired)
            }
            throw CardShowInventoryValidationFailure(.envelope, .unsuccessful)
        }
        return body
    }

    private static func integer(_ value: Any?) -> Int? {
        let raw: String
        if let value = value as? String { raw = value }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { raw = value.stringValue }
        else { return nil }
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(raw)
    }
    private static func text(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String, value.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// An optional quote cannot invalidate an otherwise complete inventory row.
    /// Validate the entire token before Decimal parsing, which otherwise accepts
    /// numeric prefixes. Unusable quotes stay unavailable, distinct from zero.
    private static func marketPrice(_ value: Any?, numericPrice: Decimal?) -> (value: Decimal?, invalid: Bool) {
        guard let value, !(value is NSNull) else { return (nil, false) }
        let raw: String
        let pattern: String
        let isNumeric: Bool
        if let value = value as? String {
            raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return (nil, false) }
            pattern = #"[0-9]{1,12}(?:\.[0-9]{1,8})?"#
            isNumeric = false
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            raw = value.stringValue
            // JSON numeric values may use exponent notation or more decimal
            // places than price strings, especially for small market values.
            pattern = #"[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
            isNumeric = true
        } else { return (nil, true) }
        guard raw.utf8.count <= 128,
              raw.range(of: pattern, options: .regularExpression) == (raw.startIndex..<raw.endIndex) else {
            return (nil, true)
        }
        let decoded = isNumeric ? numericPrice : Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
        guard let price = decoded, !price.isNaN, price >= 0, price < Decimal(1_000_000_000_000) else {
            return (nil, true)
        }
        let mantissa = raw.prefix { $0 != "e" && $0 != "E" }
        if price == 0 && mantissa.utf8.contains(where: { (49...57).contains($0) }) { return (nil, true) }
        return (price, false)
    }
    private static func invalidRow(_ reason: CardShowInventoryValidationFailure.Reason) -> CardShowInventoryValidationFailure {
        .init(.row, reason)
    }
    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    private static func normalizedGame(_ value: String) -> String {
        if let id = TCGGameRegistry.categoryID(for: value), let name = TCGGameRegistry.name(for: id) { return name }
        switch normalized(value) {
        case "pokemon", "pokémon": return "Pokémon"
        case "magic", "magic the gathering", "magic: the gathering": return "Magic: The Gathering"
        case "yu-gi-oh", "yu-gi-oh!": return "Yu-Gi-Oh!"
        default: return value
        }
    }
}
