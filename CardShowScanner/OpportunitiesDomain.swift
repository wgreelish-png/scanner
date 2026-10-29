import Foundation

/// OppsV2 is an independent entitlement and response family from Research.
enum OpportunitiesFailure: LocalizedError, Equatable, Sendable {
    case notConfigured, directNotConfigured, unsupportedCard, catalogUnavailable
    case authorizationRequired, directAuthorizationRequired, accessDenied
    case notCovered, skuNotCovered, invalidResponse, responseTooLarge, networkUnavailable
    case rateLimited, serviceUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Configure your server in TCGTracking API Connection to load market activity."
        case .directNotConfigured: return "Enter your TCGTracking shipper ID and API key in TCGTracking API Connection to load market activity."
        case .unsupportedCard: return "Market activity requires a catalog-matched card with a selected printing, language and condition."
        case .catalogUnavailable: return "The catalog cannot locate this card’s exact set. Refresh the card database and retry market activity."
        case .authorizationRequired: return "The server requires a valid device access token. Check TCGTracking API Connection."
        case .directAuthorizationRequired: return "TCGTracking rejected these credentials for market activity. Check TCGTracking API Connection."
        case .accessDenied: return "Market activity access was denied. Check your Opportunities subscription, credentials and the provider’s IP allowlist. Direct access uses this phone’s public network IP; server access uses the server’s outbound IP."
        case .notCovered: return "Market activity is not available for this exact catalog card or set."
        case .skuNotCovered: return "Market activity is not available for this exact printing, language and condition."
        case .invalidResponse: return "Market activity returned an unsupported response. Retry later."
        case .responseTooLarge: return "This market activity response is too large to display."
        case .networkUnavailable: return "Market activity could not connect. Check your connection and retry."
        case .rateLimited: return "Market activity requests are temporarily limited. Wait before retrying."
        case .serviceUnavailable(let code): return "Market activity is temporarily unavailable (HTTP \(code)). Retry later."
        }
    }
}

struct OpportunitiesDetails: Equatable, Sendable {
    let meta: OpportunitiesMetadata
    let product: OpportunitiesProduct
    /// The provider's exact SKU, kept only in these read-only details.
    let selectedSKUID: String
    let sku: OpportunitiesSKU

    static let maximumBytes = 8 * 1_024 * 1_024

    /// Decodes the own-server response without accepting a different catalog identity.
    static func decode(_ data: Data, for card: CardCandidate, expectedCategoryID: Int,
                       expectedGroupID: Int, expectedProductID: Int) throws -> Self {
        try decodeBody(data, for: card, expectedCategoryID: expectedCategoryID,
                       expectedGroupID: expectedGroupID, expectedProductID: expectedProductID, setShard: false)
    }

    static func decodeSet(_ data: Data, for card: CardCandidate, expectedCategoryID: Int,
                          expectedGroupID: Int, expectedProductID: Int) throws -> Self {
        try decodeBody(data, for: card, expectedCategoryID: expectedCategoryID,
                       expectedGroupID: expectedGroupID, expectedProductID: expectedProductID, setShard: true)
    }

    /// Validate the shard identity even if this exact product has no coverage.
    static func validateSet(_ data: Data, category: Int, group: Int) throws {
        _ = try envelope(data, category: category, group: group, setShard: true)
    }

    private static func envelope(_ data: Data, category: Int, group: Int,
                                 setShard: Bool) throws -> ([String: Any], OpportunitiesMetadata) {
        guard data.count <= maximumBytes else { throw OpportunitiesFailure.responseTooLarge }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              body["error"] == nil, (body["success"] as? Bool) != false,
              let rawMeta = body["meta"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: rawMeta),
              let meta = try? JSONDecoder().decode(OpportunitiesMetadata.self, from: encoded),
              category > 0, group > 0, meta.categoryID == category, meta.groupID == group,
              !setShard || body["products"] is [String: Any] else {
            throw OpportunitiesFailure.invalidResponse
        }
        return (body, meta)
    }

    private static func decodeBody(_ data: Data, for card: CardCandidate, expectedCategoryID: Int,
                                   expectedGroupID: Int, expectedProductID: Int, setShard: Bool) throws -> Self {
        guard OpenAPIMarketPricing.categoryID(card.identity.game) == expectedCategoryID,
              OpenAPIMarketPricing.productID(card.identity.productID).flatMap(Int.init) == expectedProductID,
              expectedProductID > 0 else { throw OpportunitiesFailure.invalidResponse }
        let (body, meta) = try envelope(data, category: expectedCategoryID, group: expectedGroupID, setShard: setShard)
        let raw: Any?
        if setShard {
            raw = (body["products"] as? [String: Any])?[String(expectedProductID)]
            guard raw != nil else { throw OpportunitiesFailure.notCovered }
        } else { raw = body["product"] }
        guard let raw = raw as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: raw),
              let product = try? JSONDecoder().decode(OpportunitiesProduct.self, from: encoded),
              product.productID == expectedProductID else { throw OpportunitiesFailure.invalidResponse }
        guard card.requiresPrintingSelection != true,
              let language = OpportunitiesIdentity.language(card.identity.language),
              let condition = OpportunitiesIdentity.condition(card.identity.condition),
              !OpportunitiesIdentity.normalized(card.identity.printing).isEmpty else { throw OpportunitiesFailure.skuNotCovered }
        let matches = product.skus.filter { _, sku in
            OpportunitiesIdentity.language(sku.language) == language && sku.conditionID == condition &&
            OpportunitiesIdentity.normalized(sku.finish) == OpportunitiesIdentity.normalized(card.identity.printing)
        }
        let selected: (key: String, value: OpportunitiesSKU)
        if matches.count == 1, let exact = matches.first { selected = exact }
        else if let saved = card.identity.skuID, let exact = matches[saved] { selected = (saved, exact) }
        else { throw OpportunitiesFailure.skuNotCovered }
        return Self(meta: meta, product: product, selectedSKUID: selected.key, sku: selected.value)
    }
}

struct OpportunitiesMetadata: Decodable, Equatable, Sendable {
    let categoryID: Int
    let groupID: Int
    let schemaVersion: String?
    let generatedAt: String?
    let setName: String?
    let gameName: String?
    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id", groupID = "group_id", schemaVersion = "schema_version"
        case generatedAt = "generated_at", setName = "set_name", gameName = "game_name"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = try values.decode(Int.self, forKey: .categoryID)
        groupID = try values.decode(Int.self, forKey: .groupID)
        schemaVersion = try values.opportunitiesText(.schemaVersion, maximum: 64)
        generatedAt = try values.opportunitiesText(.generatedAt, maximum: 128)
        setName = try values.opportunitiesText(.setName, maximum: 500)
        gameName = try values.opportunitiesText(.gameName, maximum: 200)
    }
}

struct OpportunitiesProduct: Decodable, Equatable, Sendable {
    let productID: Int
    let name: String
    let number: String?
    let rarity: String?
    let skus: [String: OpportunitiesSKU]
    enum CodingKeys: String, CodingKey { case productID = "product_id", name, number = "ext_number", rarity = "ext_rarity", skus }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        productID = try values.decode(Int.self, forKey: .productID)
        name = try values.decode(String.self, forKey: .name)
        number = try values.opportunitiesText(.number, maximum: 100)
        rarity = try values.opportunitiesText(.rarity, maximum: 100)
        skus = try values.decode([String: OpportunitiesSKU].self, forKey: .skus)
        guard !name.isEmpty, name.count <= 500, skus.count <= 10_000,
              skus.allSatisfy({ key, sku in OpportunitiesIdentity.numericSKU(key) && (sku.skuID == nil || sku.skuID == key) }) else {
            throw DecodingError.dataCorruptedError(forKey: .skus, in: values, debugDescription: "Invalid catalog SKU identity")
        }
    }
}

struct OpportunitiesSKU: Decodable, Equatable, Sendable {
    let skuID: String?
    let conditionID: Int
    let condition: String
    let finish: String
    let language: String
    let timestamps: OpportunitiesTimestamps?
    let pricing: OpportunitiesPricing?
    let marketplaces: [String: OpportunitiesMarketplace]
    let trends: OpportunitiesTrends?
    enum CodingKeys: String, CodingKey {
        case skuID = "sku_id", conditionID = "condition_id", condition, finish, language, timestamps, pricing, marketplaces, trends
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? values.decode(String.self, forKey: .skuID) { skuID = text }
        else if let number = try? values.decode(UInt64.self, forKey: .skuID), number <= 9_007_199_254_740_991 { skuID = String(number) }
        else if try values.decodeNil(forKey: .skuID) { skuID = nil }
        else { throw DecodingError.dataCorruptedError(forKey: .skuID, in: values, debugDescription: "Invalid SKU identifier") }
        conditionID = try values.decode(Int.self, forKey: .conditionID)
        condition = try values.decode(String.self, forKey: .condition)
        finish = try values.decode(String.self, forKey: .finish)
        language = try values.decode(String.self, forKey: .language)
        guard skuID.map(OpportunitiesIdentity.numericSKU) ?? true,
              OpportunitiesIdentity.condition(condition) == conditionID,
              !finish.isEmpty, finish.count <= 250, !language.isEmpty, language.count <= 50 else {
            throw DecodingError.dataCorruptedError(forKey: .condition, in: values, debugDescription: "Invalid SKU context")
        }
        timestamps = try values.decodeIfPresent(OpportunitiesTimestamps.self, forKey: .timestamps)
        pricing = try values.decodeIfPresent(OpportunitiesPricing.self, forKey: .pricing)
        marketplaces = try values.decodeIfPresent([String: OpportunitiesMarketplace].self, forKey: .marketplaces) ?? [:]
        trends = try values.decodeIfPresent(OpportunitiesTrends.self, forKey: .trends)
        guard marketplaces.count <= 8 else { throw DecodingError.dataCorruptedError(forKey: .marketplaces, in: values, debugDescription: "Too many marketplaces") }
    }
}

struct OpportunitiesTimestamps: Decodable, Equatable, Sendable {
    let opportunityComputedAt: String?
    let tcgLiveUpdatedAt: String?
    let lastVerifiedAt: String?
    let tcgSalesUpdatedAt: String?
    let manapoolSalesUpdatedAt: String?
    let productScrapeFetchedAt: String?
    enum CodingKeys: String, CodingKey {
        case opportunityComputedAt = "opp_computed_at", tcgLiveUpdatedAt = "tcgp_live_updated_at", lastVerifiedAt = "last_verified_at"
        case tcgSalesUpdatedAt = "tcgp_sales_updated_at", manapoolSalesUpdatedAt = "mp_sales_updated_at", productScrapeFetchedAt = "product_scrape_fetched_at"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        opportunityComputedAt = try values.opportunitiesText(.opportunityComputedAt, maximum: 128)
        tcgLiveUpdatedAt = try values.opportunitiesText(.tcgLiveUpdatedAt, maximum: 128)
        lastVerifiedAt = try values.opportunitiesText(.lastVerifiedAt, maximum: 128)
        tcgSalesUpdatedAt = try values.opportunitiesText(.tcgSalesUpdatedAt, maximum: 128)
        manapoolSalesUpdatedAt = try values.opportunitiesText(.manapoolSalesUpdatedAt, maximum: 128)
        productScrapeFetchedAt = try values.opportunitiesText(.productScrapeFetchedAt, maximum: 128)
    }
}

struct OpportunitiesPricing: Decodable, Equatable, Sendable {
    let marketProduct: Decimal?
    let marketSKU: Decimal?
    let liveMarket: Decimal?
    /// Blended fallback: this is not evidence of an actual sold average.
    let average30Days: Decimal?
    let listedLowCard: Decimal?
    let listedLowShipping: Decimal?
    let listedLowTotal: Decimal?
    let directLowCard: Decimal?
    enum CodingKeys: String, CodingKey {
        case marketProduct = "market_product", marketSKU = "market_sku", liveMarket = "live_market", average30Days = "avg_30d"
        case listedLowCard = "listed_low_card", listedLowShipping = "listed_low_ship", listedLowTotal = "listed_low_total", directLowCard = "direct_low_card"
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        marketProduct = v.opportunitiesDecimal(.marketProduct); marketSKU = v.opportunitiesDecimal(.marketSKU)
        liveMarket = v.opportunitiesDecimal(.liveMarket); average30Days = v.opportunitiesDecimal(.average30Days)
        listedLowCard = v.opportunitiesDecimal(.listedLowCard); listedLowShipping = v.opportunitiesDecimal(.listedLowShipping)
        listedLowTotal = v.opportunitiesDecimal(.listedLowTotal); directLowCard = v.opportunitiesDecimal(.directLowCard)
    }
}

struct OpportunitiesTrends: Decodable, Equatable, Sendable {
    let updatedAt: String?
    let trend30DaysVersus90DaysPercent: Int?
    let trend90DaysPercent: Int?
    /// The documentation names this field "TCG MP" without defining MP.
    let tcgMPTrend30DaysPercent: Int?
    let windows: [String: OpportunitiesSalesWindow]
    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at", windows, trend30DaysVersus90DaysPercent = "trend_30d_vs_90d_pct"
        case trend90DaysPercent = "trend_90d_pct", tcgMPTrend30DaysPercent = "tcg_mp_trend_30d_pct"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try values.opportunitiesText(.updatedAt, maximum: 128)
        trend30DaysVersus90DaysPercent = values.opportunitiesPercent(.trend30DaysVersus90DaysPercent)
        trend90DaysPercent = values.opportunitiesPercent(.trend90DaysPercent)
        tcgMPTrend30DaysPercent = values.opportunitiesPercent(.tcgMPTrend30DaysPercent)
        windows = try values.decodeIfPresent([String: OpportunitiesSalesWindow].self, forKey: .windows) ?? [:]
        guard windows.count <= 16 else { throw DecodingError.dataCorruptedError(forKey: .windows, in: values, debugDescription: "Too many activity windows") }
    }
}

struct OpportunitiesSalesWindow: Decodable, Equatable, Sendable {
    let tcgQuantity: Int?
    let tcgMarketAverage: Decimal?
    let tcgSoldAverage: Decimal?
    let tcgSoldAverageWithShipping: Decimal?
    let manapoolQuantity: Int?
    let manapoolAverage: Decimal?
    let combinedQuantity: Int?
    enum CodingKeys: String, CodingKey {
        case tcgQuantity = "tcg_qty", tcgMarketAverage = "tcg_market_avg", tcgSoldAverage = "tcg_sold_avg"
        case tcgSoldAverageWithShipping = "tcg_sold_avg_with_sh", manapoolQuantity = "mp_qty", manapoolAverage = "mp_avg", combinedQuantity = "combined_qty"
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        tcgQuantity = v.opportunitiesCount(.tcgQuantity); tcgMarketAverage = v.opportunitiesDecimal(.tcgMarketAverage)
        tcgSoldAverage = v.opportunitiesDecimal(.tcgSoldAverage); tcgSoldAverageWithShipping = v.opportunitiesDecimal(.tcgSoldAverageWithShipping)
        manapoolQuantity = v.opportunitiesCount(.manapoolQuantity); manapoolAverage = v.opportunitiesDecimal(.manapoolAverage)
        combinedQuantity = v.opportunitiesCount(.combinedQuantity)
    }
}

struct OpportunitiesMarketplace: Decodable, Equatable, Sendable {
    let available: Bool?
    let updatedAt: String?
    let totalQuantityAvailable: Int?
    let listings: [OpportunitiesListing]
    enum CodingKeys: String, CodingKey { case available, updatedAt = "updated_at", totalQuantityAvailable = "total_qty_available", listings }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        available = try values.decodeIfPresent(Bool.self, forKey: .available)
        updatedAt = try values.opportunitiesText(.updatedAt, maximum: 128)
        totalQuantityAvailable = values.opportunitiesCount(.totalQuantityAvailable)
        listings = try values.decodeIfPresent([OpportunitiesListing].self, forKey: .listings) ?? []
        guard listings.count <= 100 else { throw DecodingError.dataCorruptedError(forKey: .listings, in: values, debugDescription: "Too many listings") }
    }
}

struct OpportunitiesListing: Decodable, Equatable, Sendable {
    let rank: Int?
    let price: Decimal?
    let shipping: Decimal?
    let landedPrice: Decimal?
    let sellerQuantity: Int?
    let updatedAt: String?
    enum CodingKeys: String, CodingKey {
        case rank, price, shipping = "ship_price", landedPrice = "landed_price", sellerQuantity = "seller_qty", updatedAt = "updated_at"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rank = values.opportunitiesCount(.rank); price = values.opportunitiesDecimal(.price)
        shipping = values.opportunitiesDecimal(.shipping); landedPrice = values.opportunitiesDecimal(.landedPrice)
        sellerQuantity = values.opportunitiesCount(.sellerQuantity)
        updatedAt = try values.opportunitiesText(.updatedAt, maximum: 128)
    }
}

enum OpportunitiesIdentity {
    static func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
    static func numericSKU(_ value: String) -> Bool {
        (1...20).contains(value.utf8.count) && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func language(_ value: String) -> String? {
        let known = ["english": "EN", "japanese": "JP", "french": "FR", "german": "DE", "italian": "IT", "spanish": "ES",
                     "portuguese": "PT", "russian": "RU", "korean": "KO", "simplified chinese": "CS", "traditional chinese": "CT"]
        let text = normalized(value)
        return known[text] ?? (Set(known.values).contains(text.uppercased()) ? text.uppercased() : nil)
    }
    static func condition(_ value: String) -> Int? {
        ["near mint": 1, "nm": 1, "lightly played": 2, "lp": 2, "moderately played": 3, "mp": 3,
         "heavily played": 4, "hp": 4, "damaged": 5, "dmg": 5, "unopened": 6][normalized(value)]
    }
}

private struct OpportunitiesDecimal: Decodable {
    let value: Decimal?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if values.decodeNil() || (try? values.decode(Bool.self)) != nil { value = nil; return }
        let number: Decimal?
        if let text = try? values.decode(String.self) {
            guard text.utf8.count <= 64, text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { value = nil; return }
            number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        } else { number = try? values.decode(Decimal.self) }
        value = number.flatMap { !$0.isNaN && $0 >= 0 ? $0 : nil }
    }
}

private struct OpportunitiesCount: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if (try? values.decode(Bool.self)) != nil { value = nil }
        else if let count = try? values.decode(Int.self), count >= 0 { value = count }
        else if let text = try? values.decode(String.self), text.utf8.count <= 20,
                text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil, let count = Int(text), count >= 0 { value = count }
        else { value = nil }
    }
}

private struct OpportunitiesPercent: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if (try? values.decode(Bool.self)) != nil { value = nil; return }
        let number: Int?
        if let text = try? values.decode(String.self), text.utf8.count <= 8,
           text.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil { number = Int(text) }
        else { number = try? values.decode(Int.self) }
        value = number.flatMap { (-32_768...32_767).contains($0) ? $0 : nil }
    }
}

private extension KeyedDecodingContainer {
    func opportunitiesDecimal(_ key: Key) -> Decimal? { (try? decodeIfPresent(OpportunitiesDecimal.self, forKey: key))?.value }
    func opportunitiesCount(_ key: Key) -> Int? { (try? decodeIfPresent(OpportunitiesCount.self, forKey: key))?.value }
    func opportunitiesPercent(_ key: Key) -> Int? { (try? decodeIfPresent(OpportunitiesPercent.self, forKey: key))?.value }
    func opportunitiesText(_ key: Key, maximum: Int) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.count <= maximum else { throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Text exceeds maximum length") }
        return value
    }
}
