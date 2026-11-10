import Foundation
import CryptoKit

/// An independent frozen website snapshot. It never owns SwiftData models or
/// changes the imported mirror, working inventory, costs or transaction history.
struct LeftoverStockSourceRow: Codable, Equatable, Sendable {
    let inventoryID: Int
    let card: CardCandidate
    let quantity: Int
}

struct LeftoverStockBaseline: Codable, Equatable, Sendable {
    let location: CardShowInventoryLocation
    let fetchedAt: Date
    let rows: [LeftoverStockSourceRow]

    init(location: CardShowInventoryLocation, fetchedAt: Date, rows: [LeftoverStockSourceRow]) {
        self.location = location; self.fetchedAt = fetchedAt; self.rows = rows
    }

    init(snapshot: CardShowInventorySnapshot) {
        location = snapshot.location; fetchedAt = snapshot.fetchedAt
        rows = snapshot.rows.map { .init(inventoryID: $0.inventoryID, card: $0.card, quantity: $0.quantity) }
    }
}

struct LeftoverStockCountRow: Equatable, Sendable, Identifiable {
    let id: UUID
    let card: CardCandidate
    let quantity: Int
}

enum LeftoverStockFailure: LocalizedError, Equatable {
    case invalidBaseline, invalidCounts, incompleteCount, unresolvedCards, capacityExceeded
    case activeSessionExists, sessionUnavailable, notLoaded, fileTooLarge, invalidVersion, loadFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidBaseline: return "The saved Card Show snapshot is incomplete or invalid. Fetch a complete snapshot before counting."
        case .invalidCounts: return "Some counted cards are invalid. Correct their identity and quantity before exporting."
        case .incompleteCount: return "Finish counting every remaining card and mark the count complete before exporting replacement stock."
        case .unresolvedCards: return "Resolve every card identity issue before exporting replacement stock."
        case .capacityExceeded: return "This reconciliation exceeds the supported card or quantity limit. Your saved work is kept."
        case .activeSessionExists: return "A leftover stock count is already saved. Continue it or discard it before starting another."
        case .sessionUnavailable: return "This leftover stock count is no longer available. Reopen the saved count."
        case .notLoaded: return "Saved leftover stock counts are unavailable. Retry loading them before making changes. The saved file is kept."
        case .fileTooLarge: return "The saved leftover stock count is too large to open or update. The saved file is kept."
        case .invalidVersion: return "The saved leftover stock count uses an unsupported format. The saved file is kept."
        case .loadFailed: return "The saved leftover stock count could not be opened. Retry loading it. The saved file is kept."
        case .saveFailed: return "The leftover stock count could not be saved. Your previous saved work is kept; try again."
        }
    }
}

struct LeftoverStockIssue: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case invalidBaseline, invalidCount, duplicateRow, invalidQuantity, invalidSKU
        case conflictingSKU, ambiguousIdentity, unresolvedCard, capacityExceeded
    }
    let id: String
    let kind: Kind
    let message: String
    let rowIDs: [UUID]
}

enum LeftoverStockComparisonStatus: String, Sendable {
    case notCounted, reduced, extra, unchanged

    var title: String {
        switch self {
        case .notCounted: return "Not counted"
        case .reduced: return "Fewer counted"
        case .extra: return "Extra counted"
        case .unchanged: return "Unchanged"
        }
    }
}

struct LeftoverStockComparisonRow: Equatable, Sendable, Identifiable {
    let id: String
    let skuID: String
    let card: CardCandidate
    let baselineQuantity: Int
    let countedQuantity: Int
    let countRowIDs: [UUID]
    var delta: Int { countedQuantity - baselineQuantity }
    var status: LeftoverStockComparisonStatus {
        if countedQuantity == 0 && baselineQuantity > 0 { return .notCounted }
        if countedQuantity < baselineQuantity { return .reduced }
        if countedQuantity > baselineQuantity { return .extra }
        return .unchanged
    }
}

struct LeftoverStockComparison: Equatable, Sendable {
    let location: CardShowInventoryLocation
    let rows: [LeftoverStockComparisonRow]
    let issues: [LeftoverStockIssue]
    let baselineQuantity: Int
    let countedQuantity: Int
    let countFingerprint: String
    var notCountedQuantity: Int { rows.reduce(0) { $0 + max(0, $1.baselineQuantity - $1.countedQuantity) } }
    var extraQuantity: Int { rows.reduce(0) { $0 + max(0, $1.countedQuantity - $1.baselineQuantity) } }
    var unchangedQuantity: Int { rows.reduce(0) { $0 + min($1.baselineQuantity, $1.countedQuantity) } }
    var canExport: Bool { issues.isEmpty }
}

/// Comparison is value-only. Missing counts are shown as uncounted, never
/// inferred sales. Only an explicit completed count can create replacement CSV.
enum LeftoverStockReconciliation {
    static let maximumSourceRows = 10_000
    static let maximumCountRows = 100_000
    static let maximumQuantity = 1_000_000
    static let maximumTotalQuantity = 100_000_000_000

    private struct Identity: Hashable {
        let game: String
        let product: String
        let printing: String
        let language: String
        let condition: String

        init(_ value: CardIdentity) {
            let game = TCGGameRegistry.categoryID(for: value.game).flatMap(TCGGameRegistry.name(for:)) ?? value.game
            self.game = LeftoverStockReconciliation.normalized(game)
            product = LeftoverStockReconciliation.normalized(value.productID)
            printing = LeftoverStockReconciliation.normalized(value.printing)
            language = LeftoverStockReconciliation.normalized(value.language)
            condition = LeftoverStockReconciliation.normalized(value.condition)
        }

        var token: String { [game, product, printing, language, condition].map { "\($0.utf8.count):\($0)" }.joined() }
    }

    private struct Key: Hashable {
        let sku: String
        let identity: Identity
        var token: String { "\(sku.utf8.count):\(sku)" + identity.token }
    }

    private struct Group {
        let card: CardCandidate
        let sku: String
        var baseline = 0
        var counted = 0
        var countRowIDs: [UUID] = []
    }

    static func compare(baseline: LeftoverStockBaseline, counts: [LeftoverStockCountRow]) -> LeftoverStockComparison {
        var issues: [LeftoverStockIssue] = [], issueIDs = Set<String>()
        func issue(_ kind: LeftoverStockIssue.Kind, _ token: String, _ message: String, rows: [UUID] = []) {
            let id = kind.rawValue + ":" + token
            guard issueIDs.insert(id).inserted else { return }
            issues.append(.init(id: id, kind: kind, message: message, rowIDs: rows))
        }

        var groups: [Key: Group] = [:], order: [Key] = []
        var identitiesBySKU: [String: Set<Identity>] = [:]
        var baselineSKUsByIdentity: [Identity: Set<String>] = [:]
        var allSKUsByIdentity: [Identity: Set<String>] = [:]
        var countIDsBySKU: [String: [UUID]] = [:], countIDsByIdentity: [Identity: [UUID]] = [:]
        var baselineIDs = Set<Int>(), countIDs = Set<UUID>()
        var baselineTotal = 0, countTotal = 0

        do { try validate(baseline: baseline) }
        catch {
            issue(.invalidBaseline, "snapshot", "The Card Show snapshot contains invalid or incomplete source rows.")
        }
        if baseline.rows.count > maximumSourceRows || counts.count > maximumCountRows {
            issue(.capacityExceeded, "rows", "There are too many source or counted rows to export safely.")
        }

        // Bound work even when a malformed caller supplies too many rows.
        for row in baseline.rows.prefix(maximumSourceRows) {
            guard baselineIDs.insert(row.inventoryID).inserted else {
                issue(.duplicateRow, "source:\(row.inventoryID)", "The source snapshot repeats an inventory row."); continue
            }
            guard row.inventoryID > 0, validIdentity(row.card), (0...maximumQuantity).contains(row.quantity) else { continue }
            guard let sku = validSKU(row.card.identity.skuID) else {
                issue(.invalidSKU, "source:\(row.inventoryID)", "A source card has no valid numeric TCGplayer SKU."); continue
            }
            let identity = Identity(row.card.identity), key = Key(sku: sku, identity: identity)
            identitiesBySKU[sku, default: []].insert(identity)
            baselineSKUsByIdentity[identity, default: []].insert(sku)
            allSKUsByIdentity[identity, default: []].insert(sku)
            if groups[key] == nil { groups[key] = Group(card: row.card, sku: sku); order.append(key) }
            if let sum = adding(groups[key]?.baseline ?? 0, row.quantity, maximum: maximumQuantity) {
                groups[key]?.baseline = sum
            } else { issue(.invalidQuantity, "source:" + key.token, "A source SKU exceeds the supported quantity.") }
            if let sum = adding(baselineTotal, row.quantity, maximum: maximumTotalQuantity) { baselineTotal = sum }
            else { issue(.invalidQuantity, "source-total", "The source quantity exceeds the supported total.") }
        }

        // First collect every supplied SKU identity, so conflicting new cards
        // cannot depend on physical scan order or match the first row by name.
        for row in counts.prefix(maximumCountRows) where validIdentity(row.card) {
            let identity = Identity(row.card.identity)
            countIDsByIdentity[identity, default: []].append(row.id)
            if let sku = validSKU(row.card.identity.skuID) {
                identitiesBySKU[sku, default: []].insert(identity)
                allSKUsByIdentity[identity, default: []].insert(sku)
                countIDsBySKU[sku, default: []].append(row.id)
            }
        }
        for sku in identitiesBySKU.keys.sorted() where (identitiesBySKU[sku]?.count ?? 0) > 1 {
            let affected = countIDsBySKU[sku] ?? []
            issue(.conflictingSKU, sku, "SKU \(sku) is attached to different products, games, printings, languages or conditions.", rows: affected)
        }
        for (identity, skus) in allSKUsByIdentity.sorted(by: { $0.key.token < $1.key.token }) where skus.count > 1 {
            let affected = countIDsByIdentity[identity] ?? []
            issue(.ambiguousIdentity, identity.token, "The same card identity has multiple SKUs. Resolve the ambiguity before exporting.", rows: affected)
        }

        for row in counts.prefix(maximumCountRows) {
            guard countIDs.insert(row.id).inserted else {
                issue(.duplicateRow, "count:\(row.id)", "A counted physical row was included more than once.", rows: [row.id]); continue
            }
            guard (1...maximumQuantity).contains(row.quantity) else {
                issue(.invalidQuantity, "count:\(row.id)", "A counted card must have a supported positive quantity.", rows: [row.id]); continue
            }
            if let sum = adding(countTotal, row.quantity, maximum: maximumTotalQuantity) { countTotal = sum }
            else { issue(.invalidQuantity, "count-total", "The counted quantity exceeds the supported total.") }
            guard validIdentity(row.card) else {
                issue(.invalidCount, row.id.uuidString, "Choose a complete game, product, printing, language and condition for this card.", rows: [row.id]); continue
            }
            let identity = Identity(row.card.identity), sku: String
            if let raw = row.card.identity.skuID, !raw.isEmpty {
                guard let supplied = validSKU(raw) else {
                    issue(.invalidSKU, row.id.uuidString, "Choose a valid numeric TCGplayer SKU for this card.", rows: [row.id]); continue
                }
                sku = supplied
                if let sourceSKUs = baselineSKUsByIdentity[identity], !sourceSKUs.contains(sku) {
                    issue(.conflictingSKU, row.id.uuidString, "This card's SKU disagrees with its exact source identity. Correct the card before exporting.", rows: [row.id])
                }
            } else {
                let matches = baselineSKUsByIdentity[identity] ?? []
                guard matches.count == 1, let match = matches.first else {
                    issue(matches.isEmpty ? .unresolvedCard : .ambiguousIdentity, row.id.uuidString,
                          matches.isEmpty ? "This card needs an exact TCGplayer SKU before it can be exported." : "This card matches multiple source SKUs. Correct its exact identity before exporting.", rows: [row.id])
                    continue
                }
                sku = match
            }
            let key = Key(sku: sku, identity: identity)
            if groups[key] == nil {
                var card = row.card; card.identity.skuID = sku
                groups[key] = Group(card: card, sku: sku); order.append(key)
            }
            if let sum = adding(groups[key]?.counted ?? 0, row.quantity, maximum: maximumQuantity) {
                groups[key]?.counted = sum
            } else { issue(.invalidQuantity, "count:" + key.token, "A counted SKU exceeds the supported quantity.", rows: [row.id]) }
            groups[key]?.countRowIDs.append(row.id)
        }
        let rows = order.compactMap { key -> LeftoverStockComparisonRow? in
            guard let group = groups[key] else { return nil }
            return .init(id: key.token, skuID: group.sku, card: group.card,
                         baselineQuantity: group.baseline, countedQuantity: group.counted, countRowIDs: group.countRowIDs)
        }
        return .init(location: baseline.location, rows: rows, issues: issues, baselineQuantity: baselineTotal,
                     countedQuantity: countTotal, countFingerprint: countFingerprint(counts))
    }

    /// This file is uploaded with Add only after clearing the Card Show location.
    /// Full Replace on the website affects other locations and is not this flow.
    static func replacementCSV(comparison: LeftoverStockComparison, countComplete: Bool) throws -> String {
        guard countComplete else { throw LeftoverStockFailure.incompleteCount }
        guard comparison.canExport else { throw LeftoverStockFailure.unresolvedCards }
        let header = "tcgplayer_sku,name,set_name,collector_number,condition,foil,language,quantity,location"
        let records = comparison.rows.filter { $0.countedQuantity > 0 }.map { row in
            let card = row.card
            return [row.skuID, card.name, card.set, card.number, card.identity.condition,
                    card.identity.printing, card.identity.language, String(row.countedQuantity), comparison.location.name]
                .map(humanCSV).joined(separator: ",")
        }
        return ([header] + records).joined(separator: "\r\n") + "\r\n"
    }

    static func comparisonCSV(comparison: LeftoverStockComparison) -> String {
        let header = "tcgplayer_sku,name,set_name,collector_number,game,condition,foil,language,previous_quantity,counted_quantity,delta,status,location"
        let records = comparison.rows.map { row in
            let card = row.card
            let human = [row.skuID, card.name, card.set, card.number, card.identity.game,
                         card.identity.condition, card.identity.printing, card.identity.language]
                .map(humanCSV)
            // App-generated signed deltas are numbers, not spreadsheet formulas.
            let numeric = [row.baselineQuantity, row.countedQuantity, row.delta].map { "\"\($0)\"" }
            return (human + numeric + [row.status.title, comparison.location.name].map(humanCSV)).joined(separator: ",")
        }
        return ([header] + records).joined(separator: "\r\n") + "\r\n"
    }

    /// Stable across process launches and insensitive to live market-price
    /// refreshes. Any row, identity, quantity or exported text edit invalidates
    /// the user's completion acknowledgement, including edits in other screens.
    static func countFingerprint(_ counts: [LeftoverStockCountRow]) -> String {
        var hash = SHA256()
        for row in counts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let card = row.card, identity = card.identity
            let fields = [row.id.uuidString, identity.game, identity.productID, identity.skuID ?? "",
                          identity.printing, identity.language, identity.condition, card.name, card.set,
                          card.number, String(row.quantity)]
            for field in fields {
                let data = Data(field.utf8)
                hash.update(data: Data("\(data.count):".utf8)); hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validate(baseline: LeftoverStockBaseline) throws {
        guard baseline.location.id > 0, validText(baseline.location.name, maximum: 200),
              normalized(baseline.location.name) == "card show", baseline.fetchedAt.timeIntervalSince1970.isFinite,
              baseline.rows.count <= maximumSourceRows else { throw LeftoverStockFailure.invalidBaseline }
        var seen = Set<Int>()
        for row in baseline.rows {
            guard row.inventoryID > 0, seen.insert(row.inventoryID).inserted,
                  (0...maximumQuantity).contains(row.quantity), validIdentity(row.card),
                  validSKU(row.card.identity.skuID) != nil else { throw LeftoverStockFailure.invalidBaseline }
        }
    }

    private static func validIdentity(_ card: CardCandidate) -> Bool {
        let identity = card.identity
        return validText(identity.game, maximum: 200) && validText(identity.productID, maximum: 200) &&
            validText(identity.printing, maximum: 200) && validText(identity.language, maximum: 200) &&
            validText(identity.condition, maximum: 200) && validText(card.name, maximum: 500) &&
            validText(card.set, maximum: 500) && validText(card.number, maximum: 100, allowEmpty: true)
    }

    private static func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        value.count <= maximum && (allowEmpty || !normalized(value).isEmpty) &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func validSKU(_ value: String?) -> String? {
        guard let value, (1...20).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) }), value.utf8.contains(where: { (49...57).contains($0) }) else { return nil }
        return value
    }

    private static func humanCSV(_ value: String) -> String {
        let probe = value.drop(while: { $0.isWhitespace })
        let risky = probe.first.map { "=+-@".contains($0) } ?? false
        return CSVExportService.escape(risky ? "'" + value : value)
    }

    private static func adding(_ left: Int, _ right: Int, maximum: Int) -> Int? {
        let sum = left.addingReportingOverflow(right)
        return !sum.overflow && sum.partialValue <= maximum ? sum.partialValue : nil
    }
}
