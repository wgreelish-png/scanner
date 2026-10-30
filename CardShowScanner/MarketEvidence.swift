import Foundation

/// A read-only projection of returned evidence for one captured card selection.
/// It supplies chart values without deriving a valuation, demand score or price.
struct MarketEvidence: Sendable {
    enum PriceKind: String, Equatable, Sendable { case market, sold, listing }
    enum SKUAgreement: Equatable, Sendable { case same, different, unavailable }
    enum DataAge: Equatable, Sendable { case withinDay, older, unknown, future }

    struct PricePoint: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let price: Decimal
        let kind: PriceKind
    }

    struct VolumePoint: Identifiable, Equatable, Sendable {
        let id: String
        let windowDays: Int
        let source: String
        let quantity: Int
    }

    let priceComparisons: [PricePoint]
    let volumePoints: [VolumePoint]
    let skuAgreement: SKUAgreement
    /// The age of the provider's price timestamp, never the retrieval timestamp.
    let publicDataAge: DataAge
    /// The age of this activity shard's generation, not its underlying last sale.
    let activityDataAge: DataAge

    init(publicDetails: MarketDetails?, activity: OpportunitiesDetails?, now: Date = Date()) {
        let reportedPublicSKU = publicDetails?.quote?.skuID
        let publicSKU = reportedPublicSKU.flatMap { OpportunitiesIdentity.numericSKU($0) ? $0 : nil }
        if let publicSKU, let activity {
            skuAgreement = publicSKU == activity.selectedSKUID ? .same : .different
        } else { skuAgreement = .unavailable }
        publicDataAge = Self.dataAge(publicDetails?.metadata?.updatedAt, now: now)
        activityDataAge = Self.dataAge(Self.timestamp(activity?.meta.generatedAt), now: now)

        var prices: [PricePoint] = []
        func price(_ id: String, _ label: String, _ value: Decimal?, _ kind: PriceKind) {
            guard let value, !value.isNaN, value >= 0 else { return }
            prices.append(PricePoint(id: id, label: label, price: value, kind: kind))
        }
        price("public.market", "OpenAPI SKU market", publicDetails?.quote?.marketPrice, .market)
        if publicDetails?.quote != nil {
            price("public.low", "OpenAPI low listing", publicDetails?.context?.lowPrice, .listing)
        }
        // The provider validates the activity's exact card dimensions before
        // constructing OpportunitiesDetails. If a public quote exists, compare
        // sources only when both return the same actual SKU identifier.
        if let activity, publicDetails?.quote == nil || skuAgreement == .same {
            price("activity.market", "OppsV2 SKU market", activity.sku.pricing?.marketSKU, .market)
            for days in [30, 90] {
                price("activity.sold.\(days)", "TCGplayer sold • \(days)d",
                      activity.sku.trends?.windows["\(days)d"]?.tcgSoldAverage, .sold)
            }
            price("activity.listed", "OppsV2 listed card (no shipping)", activity.sku.pricing?.listedLowCard, .listing)
        }
        priceComparisons = prices

        var volumes: [VolumePoint] = []
        for days in [30, 90, 365] {
            guard let window = activity?.sku.trends?.windows["\(days)d"] else { continue }
            for (source, quantity) in [("TCGplayer", window.tcgQuantity), ("Manapool", window.manapoolQuantity)] {
                guard let quantity, quantity >= 0 else { continue }
                volumes.append(VolumePoint(id: "\(days)d.\(source)", windowDays: days, source: source, quantity: quantity))
            }
        }
        // Windows overlap. Do not add them, subtract them into invented periods,
        // infer missing quantities, or equate listing counts with sold units.
        volumePoints = volumes
    }

    static func dataAge(_ date: Date?, now: Date) -> DataAge {
        guard let date, date.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else { return .unknown }
        let age = now.timeIntervalSince(date)
        if age < 0 { return .future }
        return age <= 24 * 60 * 60 ? .withinDay : .older
    }

    /// Provider ISO-8601 timestamps require an explicit timezone. SQL/date-only
    /// values have unknown timezone/freshness and are not interpreted as local.
    static func timestamp(_ string: String?) -> Date? {
        guard let string, string.utf8.count <= 40,
              string.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                           options: .regularExpression) != nil else { return nil }
        let day = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        let time = string.dropFirst(11).prefix(8).split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, time.count == 3, (1...9999).contains(day[0]),
              (0...23).contains(time[0]), (0...59).contains(time[1]), (0...59).contains(time[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let parsedDay = calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2])) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: parsedDay)
        guard components.year == day[0], components.month == day[1], components.day == day[2] else { return nil }
        if !string.hasSuffix("Z") {
            let offset = string.suffix(5).split(separator: ":").compactMap { Int($0) }
            guard offset.count == 2, (0...23).contains(offset[0]), (0...59).contains(offset[1]) else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        if string.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter.date(from: string)
    }
}
