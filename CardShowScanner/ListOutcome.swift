import Foundation
import SwiftData

/// A recorded outcome belongs to the saved list, independently of its scanner
/// session lifecycle and the proposed amounts in saved offer calculations.
enum ListOutcomeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case purchase, tradeAndPurchase, trade, nothingHappened

    var id: String { rawValue }
    var title: String {
        switch self {
        case .purchase: return "Purchase"
        case .tradeAndPurchase: return "Trade + Purchase"
        case .trade: return "Trade"
        case .nothingHappened: return "Nothing Happened"
        }
    }
}

struct ListOutcomeRecord: Codable, Equatable, Sendable {
    let version: Int
    let kind: ListOutcomeKind
    let recordedAt: Date

    init(kind: ListOutcomeKind, recordedAt: Date, version: Int = 1) {
        self.version = version; self.kind = kind; self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey { case version, kind, recordedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        kind = try values.decode(ListOutcomeKind.self, forKey: .kind)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        guard version == 1, recordedAt.timeIntervalSince1970.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported or invalid list outcome record."))
        }
    }

    func encode(to encoder: Encoder) throws {
        guard version == 1, recordedAt.timeIntervalSince1970.isFinite else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Unsupported or invalid list outcome record."))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(kind, forKey: .kind)
        try values.encode(recordedAt, forKey: .recordedAt)
    }
}

extension CardList {
    var outcomeRecord: ListOutcomeRecord? {
        guard let transactionOutcomeData, transactionOutcomeData.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(ListOutcomeRecord.self, from: transactionOutcomeData)
    }
    var outcomeTitle: String {
        guard transactionOutcomeData != nil else { return "No status" }
        return outcomeRecord?.kind.title ?? "Status unavailable"
    }
}

@MainActor enum ListOutcomeService {
    /// Only an explicit user action records or clears the outcome. Do not call
    /// from view dismissal, calculator changes, scanning, or offer persistence.
    static func set(_ kind: ListOutcomeKind?, for list: CardList, context: ModelContext, now: Date = .now,
                    save: @MainActor (ModelContext) throws -> Void = { try $0.save() }) throws {
        if let kind, list.outcomeRecord?.kind == kind { return }
        if kind == nil, list.transactionOutcomeData == nil { return }
        let next = try kind.map { try JSONEncoder().encode(ListOutcomeRecord(kind: $0, recordedAt: now)) }
        let previous = list.transactionOutcomeData
        list.transactionOutcomeData = next
        do {
            try save(context)
            DiagnosticLog.shared.record("list.outcome_saved")
        } catch {
            // This operation changes one field. Restore it without discarding
            // unrelated edits that were pending in the same model context.
            list.transactionOutcomeData = previous
            context.processPendingChanges()
            DiagnosticLog.shared.failure("list.outcome_failed", error)
            throw error
        }
    }
}
