import Foundation

enum ResearchFailure: LocalizedError, Equatable {
    case notConfigured, unsupportedCard, catalogUnavailable, authorizationRequired, accessDenied
    case notCovered, invalidResponse, responseTooLarge, networkUnavailable, serviceUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your research server in Settings to look up research."
        case .unsupportedCard: return "Research requires a catalog-matched TCGplayer card in a supported game."
        case .catalogUnavailable: return "The saved catalog cannot locate this card’s set. Refresh the card database, then retry research."
        case .authorizationRequired: return "The research server requires a valid device access token. Check Research Connection in Settings."
        case .accessDenied: return "The research server denied access. Check the server’s Research API credentials and IP allowlist."
        case .notCovered: return "Research is not available for this catalog card or set."
        case .invalidResponse: return "The research server returned an unsupported response. Your saved card and price are unchanged."
        case .responseTooLarge: return "This research response is too large to display."
        case .networkUnavailable: return "Research could not connect. Check your connection and retry."
        case .serviceUnavailable(let code): return "Research is temporarily unavailable (HTTP \(code)). Retry later."
        }
    }
}

struct ResearchProductDetails: Decodable, Equatable, Sendable {
    var meta: ResearchMetadata
    var product: ResearchProduct

    static func decode(_ data: Data, expectedCategoryID: Int, expectedGroupID: Int,
                       expectedProductID: Int) throws -> Self {
        guard data.count <= NativeResearchHTTPDataLoader.maximumBytes else { throw ResearchFailure.responseTooLarge }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ResearchFailure.invalidResponse }
        guard result.meta.categoryID == expectedCategoryID, result.meta.groupID == expectedGroupID,
              result.product.productID == expectedProductID, expectedCategoryID > 0,
              expectedGroupID > 0, expectedProductID > 0, !result.product.name.isEmpty,
              result.product.name.count <= 500, result.product.variants.count <= 256,
              (result.meta.schemaVersion?.count ?? 0) <= 64, (result.meta.status?.count ?? 0) <= 64,
              (result.meta.generatedAt?.count ?? 0) <= 128, (result.meta.setName?.count ?? 0) <= 500,
              (result.meta.gameName?.count ?? 0) <= 200,
              result.product.variants.allSatisfy({ $0.key.count <= 300 && $0.value.grades.count <= 512 &&
                  $0.value.language.count <= 8 && $0.value.finish.count <= 250 }) else {
            throw ResearchFailure.invalidResponse
        }
        return result
    }
}

struct ResearchMetadata: Decodable, Equatable, Sendable {
    var schemaVersion: String?
    var status: String?
    var categoryID: Int
    var groupID: Int
    var generatedAt: String?
    var setName: String?
    var gameName: String?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", status, categoryID = "category_id", groupID = "group_id"
        case generatedAt = "generated_at", setName = "set_name", gameName = "game_name"
    }
}

struct ResearchProduct: Decodable, Equatable, Sendable {
    var productID: Int
    var name: String
    var number: String?
    var rarity: String?
    var catalogMarketPrice: Decimal?
    var images: ResearchImages?
    var variants: [String: ResearchVariant]
    enum CodingKeys: String, CodingKey {
        case productID = "product_id", name, number = "ext_number", rarity = "ext_rarity"
        case catalogMarketPrice = "catalog_market_price", images, variants
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        productID = try values.decode(Int.self, forKey: .productID)
        name = try values.decode(String.self, forKey: .name)
        number = try values.decodeIfPresent(String.self, forKey: .number)
        rarity = try values.decodeIfPresent(String.self, forKey: .rarity)
        catalogMarketPrice = values.researchDecimal(.catalogMarketPrice)
        images = try values.decodeIfPresent(ResearchImages.self, forKey: .images)
        variants = try values.decode([String: ResearchVariant].self, forKey: .variants)
    }
    var imageURL: URL? { images?.imageURL }
}

struct ResearchImages: Decodable, Equatable, Sendable {
    var front200: String?
    var front400: String?
    enum CodingKeys: String, CodingKey { case front200 = "front_200", front400 = "front_400" }
    var imageURL: URL? {
        for value in [front400, front200] {
            if let value, let url = URL(string: value), url.scheme == "https", url.host != nil,
               url.user == nil, url.password == nil { return url }
        }
        return nil
    }
}

struct ResearchVariant: Decodable, Equatable, Sendable {
    var language: String
    var finish: String
    var updatedAt: String?
    var summary: ResearchVariantSummary?
    var grades: [ResearchGrade]
    enum CodingKeys: String, CodingKey { case language, finish, updatedAt = "updated_at", summary, grades }
    var key: String { language + ":" + finish }
}

struct ResearchVariantSummary: Decodable, Equatable, Sendable {
    var rawGuideValue: Decimal?
    var psa10GuideValue: Decimal?
    var totalGradesTracked: Int?
    var totalSalesRecorded: Int?
    enum CodingKeys: String, CodingKey {
        case rawGuideValue = "raw_guide_value", psa10GuideValue = "psa10_guide_value"
        case totalGradesTracked = "total_grades_tracked", totalSalesRecorded = "total_sales_recorded"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rawGuideValue = values.researchDecimal(.rawGuideValue); psa10GuideValue = values.researchDecimal(.psa10GuideValue)
        totalGradesTracked = values.researchCount(.totalGradesTracked); totalSalesRecorded = values.researchCount(.totalSalesRecorded)
    }
}

struct ResearchGrade: Decodable, Equatable, Sendable, Identifiable {
    var grader: String
    var grade: String
    var population: Int?
    var sales: Int?
    var guideValue: Decimal?
    var marketValue: Decimal?
    var confidence: Int?
    var lastSoldAt: String?
    var syncedOn: String?
    var dailyHistory: ResearchDailyHistory?
    var id: String { grader + "|" + grade }
    enum CodingKeys: String, CodingKey {
        case grader, grade, population = "pop", sales, guideValue = "guide_value", marketValue = "market_value"
        case confidence, lastSoldAt = "last_sold_at", syncedOn = "synced_on", dailyHistory = "daily_history"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grader = try values.decode(String.self, forKey: .grader); grade = try values.decode(String.self, forKey: .grade)
        guard !grader.isEmpty, grader.count <= 32, !grade.isEmpty, grade.count <= 80 else {
            throw DecodingError.dataCorruptedError(forKey: .grade, in: values, debugDescription: "Invalid grade identity")
        }
        population = values.researchCount(.population); sales = values.researchCount(.sales)
        guideValue = values.researchDecimal(.guideValue); marketValue = values.researchDecimal(.marketValue)
        confidence = values.researchConfidence(.confidence)
        lastSoldAt = try values.decodeIfPresent(String.self, forKey: .lastSoldAt)
        syncedOn = try values.decodeIfPresent(String.self, forKey: .syncedOn)
        dailyHistory = try values.decodeIfPresent(ResearchDailyHistory.self, forKey: .dailyHistory)
    }
}

struct ResearchDailyHistory: Decodable, Equatable, Sendable {
    var updatedAt: String?
    var stats: ResearchHistoryStats?
    var series: [ResearchDailyPoint]
    enum CodingKeys: String, CodingKey { case updatedAt = "updated_at", stats, series }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        stats = try values.decodeIfPresent(ResearchHistoryStats.self, forKey: .stats)
        let decoded = try values.decodeIfPresent([OptionalResearchPoint].self, forKey: .series) ?? []
        series = decoded.compactMap(\.value).sorted { $0.day < $1.day }
    }
}

struct ResearchHistoryStats: Decodable, Equatable, Sendable {
    var value: Decimal?
    var market: Decimal?
    var highAll: Decimal?
    var confidence: Int?
    var lastSale: ResearchLastSale?
    var changes: ResearchValueChanges?
    var month: ResearchSalesPeriod?
    var year: ResearchSalesPeriod?
    enum CodingKeys: String, CodingKey {
        case value, market, highAll = "high_all", confidence, lastSale = "last_sale", changes = "change", month, year
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = values.researchDecimal(.value); market = values.researchDecimal(.market); highAll = values.researchDecimal(.highAll)
        confidence = values.researchConfidence(.confidence)
        lastSale = try values.decodeIfPresent(ResearchLastSale.self, forKey: .lastSale)
        changes = try values.decodeIfPresent(ResearchValueChanges.self, forKey: .changes)
        month = try values.decodeIfPresent(ResearchSalesPeriod.self, forKey: .month)
        year = try values.decodeIfPresent(ResearchSalesPeriod.self, forKey: .year)
    }
}

struct ResearchLastSale: Decodable, Equatable, Sendable {
    var price: Decimal?
    var date: String?
    enum CodingKeys: String, CodingKey { case price, date }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        price = values.researchDecimal(.price); date = try values.decodeIfPresent(String.self, forKey: .date)
    }
}

struct ResearchSalesPeriod: Decodable, Equatable, Sendable {
    var sales: Int?
    var average: Decimal?
    var low: Decimal?
    var high: Decimal?
    enum CodingKeys: String, CodingKey { case sales, average = "avg", low, high }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sales = values.researchCount(.sales); average = values.researchDecimal(.average)
        low = values.researchDecimal(.low); high = values.researchDecimal(.high)
    }
}

struct ResearchValueChanges: Decodable, Equatable, Sendable {
    var week: Decimal?
    var month: Decimal?
    var quarter: Decimal?
    var year: Decimal?
    enum CodingKeys: String, CodingKey { case week, month, quarter, year }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        week = values.researchDecimal(.week, allowsNegative: true); month = values.researchDecimal(.month, allowsNegative: true)
        quarter = values.researchDecimal(.quarter, allowsNegative: true); year = values.researchDecimal(.year, allowsNegative: true)
    }
}

struct ResearchDailyPoint: Decodable, Equatable, Sendable {
    var day: String
    var date: Date
    var sales: Int?
    var average: Decimal?
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count == 3 else { throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid daily row") }
        day = try values.decode(String.self)
        guard let parsed = Self.parseDay(day) else { throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid daily date") }
        date = parsed
        sales = try values.decode(ResearchCount.self).value
        average = try values.decode(ResearchDecimal.self).value.flatMap { $0 >= 0 ? $0 : nil }
    }
    private static func parseDay(_ day: String) -> Date? {
        guard day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let fields = day.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2])) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == fields[0] && components.month == fields[1] && components.day == fields[2] ? date : nil
    }
}

private struct OptionalResearchPoint: Decodable {
    var value: ResearchDailyPoint?
    init(from decoder: Decoder) { value = try? ResearchDailyPoint(from: decoder) }
}

private struct ResearchDecimal: Decodable {
    var value: Decimal?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if values.decodeNil() || (try? values.decode(Bool.self)) != nil { value = nil; return }
        if let text = try? values.decode(String.self) {
            guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { value = nil; return }
            value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        } else { value = try? values.decode(Decimal.self) }
        if value?.isNaN == true { value = nil }
    }
}

private struct ResearchCount: Decodable {
    var value: Int?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if let count = try? values.decode(Int.self), count >= 0 { value = count }
        else if let text = try? values.decode(String.self), text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                let count = Int(text), count >= 0 { value = count }
        else { value = nil }
    }
}

private extension KeyedDecodingContainer {
    func researchDecimal(_ key: Key, allowsNegative: Bool = false) -> Decimal? {
        guard let decoded = try? decodeIfPresent(ResearchDecimal.self, forKey: key), let value = decoded.value,
              allowsNegative || value >= 0 else { return nil }
        return value
    }
    func researchCount(_ key: Key) -> Int? { (try? decodeIfPresent(ResearchCount.self, forKey: key))?.value }
    func researchConfidence(_ key: Key) -> Int? {
        guard let value = researchCount(key), (1...5).contains(value) else { return nil }
        return value
    }
}
