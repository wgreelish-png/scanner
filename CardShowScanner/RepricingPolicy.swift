import Foundation

enum RepricingReason: String, Codable, CaseIterable, Sendable {
    case newPricing, marketUnavailable, marketDecrease, overpriced, marketIncrease

    /// Lower values appear first in the review queue.
    var priority: Int {
        switch self {
        case .marketDecrease, .overpriced: return 0
        case .newPricing: return 1
        case .marketUnavailable: return 2
        case .marketIncrease: return 3
        }
    }
}

struct RepricingEvaluation: Equatable, Sendable {
    let baselineMarket: Decimal?
    let currentMarket: Decimal?
    /// Current market minus the market recorded at the last approval, without rounding.
    let marketDelta: Decimal?
    let increaseThreshold: Decimal?
    let decreaseThreshold: Decimal?
    /// A sticker above current market is overpriced at or above this exact premium limit.
    let competitivenessLimit: Decimal?
    let reasons: [RepricingReason]

    var priority: Int { reasons.map(\.priority).min() ?? 4 }
}

/// Stateless comparisons against the market saved at the last explicit pricing approval.
/// Importing another quote does not change that baseline, so small movements accumulate.
enum RepricingPolicy {
    static let maximumCents: Int64 = 99_999_999_999
    static let maximumMarket = Decimal(maximumCents) / 100

    static func evaluate(baselineMarket: Decimal?, currentMarket: Decimal?,
                         approvedStickerCents: Int64?, hasApprovedCategory: Bool = false) -> RepricingEvaluation {
        let baseline = validMarket(baselineMarket)
        let current = validMarket(currentMarket)
        let sticker = approvedStickerCents.flatMap { cents -> Decimal? in
            guard (0...maximumCents).contains(cents) else { return nil }
            return Decimal(cents) / 100
        }
        let thresholds = baseline.map { movementThresholds(for: $0) }
        let delta: Decimal?
        if let baseline, let current { delta = current - baseline }
        else { delta = nil }
        let competitivenessLimit = current.map {
            $0 * Decimal(100 + competitivenessPercent(for: $0)) / 100
        }

        var reasons: [RepricingReason] = []
        // Approved bulk categories have no individual sticker amount.
        if baseline == nil || (sticker == nil && !hasApprovedCategory) { reasons.append(.newPricing) }
        if current == nil { reasons.append(.marketUnavailable) }
        if let delta, let thresholds, delta <= -thresholds.decrease {
            reasons.append(.marketDecrease)
        }
        if let sticker, let current, let competitivenessLimit,
           sticker > current && sticker >= competitivenessLimit {
            reasons.append(.overpriced)
        }
        if let delta, let thresholds, delta >= thresholds.increase {
            reasons.append(.marketIncrease)
        }

        return RepricingEvaluation(baselineMarket: baseline, currentMarket: current,
            marketDelta: delta, increaseThreshold: thresholds?.increase,
            decreaseThreshold: thresholds?.decrease, competitivenessLimit: competitivenessLimit,
            reasons: reasons)
    }

    private static func validMarket(_ value: Decimal?) -> Decimal? {
        guard let value, !value.isNaN, value >= 0, value <= maximumMarket else { return nil }
        return value
    }

    private static func movementThresholds(for baseline: Decimal) -> (decrease: Decimal, increase: Decimal) {
        let decrease: Decimal
        let increase: Decimal
        if baseline < 5 {
            decrease = max(Decimal(25) / 100, baseline * 10 / 100)
            increase = max(Decimal(50) / 100, baseline * 20 / 100)
        } else if baseline < 20 {
            decrease = max(Decimal(50) / 100, baseline * 5 / 100)
            increase = max(Decimal(1), baseline * 10 / 100)
        } else {
            decrease = min(max(Decimal(1), baseline * 5 / 100), Decimal(25))
            increase = min(max(Decimal(2), baseline * 10 / 100), Decimal(25))
        }
        return (ceilToCent(decrease), ceilToCent(increase))
    }

    private static func competitivenessPercent(for current: Decimal) -> Int {
        if current < 5 { return 10 }
        if current < 20 { return 8 }
        return 5
    }

    /// A fractional cent must not lower the change needed to enter the review queue.
    private static func ceilToCent(_ value: Decimal) -> Decimal {
        var source = value
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &source, 2, .up)
        return rounded
    }
}
