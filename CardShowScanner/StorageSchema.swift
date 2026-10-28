import Foundation
import SwiftData

/// Exact pre-batch persistent fields. Do not edit this schema after release.
enum ScannerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [CardList.self, InventoryCard.self, ScanSession.self] }
    @Model final class CardList {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \InventoryCard.list) var cards: [InventoryCard] = []
        init(name: String) { id = UUID(); self.name = name; createdAt = .now }
    }
    @Model final class InventoryCard {
        @Attribute(.unique) var id: UUID
        var data: Data
        var quantity: Int
        var addedAt: Date
        var list: CardList?
        init(data: Data, quantity: Int) { id = UUID(); self.data = data; self.quantity = quantity; addedAt = .now }
    }
    @Model final class ScanSession {
        var id: UUID
        var startedAt: Date
        var listName: String
        var addedQuantity: Int
        var knownValueText: String
        var unpricedQuantity: Int
        init(listName: String) {
            id = UUID(); startedAt = .now; self.listName = listName
            addedQuantity = 0; knownValueText = "0"; unpricedQuantity = 0
        }
    }
}

/// Exact released batch schema. Keep these persistent fields frozen as V3 evolves.
enum ScannerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [CardList.self, InventoryCard.self, ScanSession.self] }
    @Model final class CardList {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \InventoryCard.list) var cards: [InventoryCard] = []
        init(name: String) { id = UUID(); self.name = name; createdAt = .now }
    }
    @Model final class InventoryCard {
        @Attribute(.unique) var id: UUID
        var data: Data
        var quantity: Int
        var addedAt: Date
        var list: CardList?
        var cashOverrideText: String? = nil
        var tradeOverrideText: String? = nil
        var maximumOverrideText: String? = nil
        init(data: Data, quantity: Int = 1) {
            id = UUID(); self.data = data; self.quantity = quantity; addedAt = .now
        }
    }
    @Model final class ScanSession {
        var id: UUID
        var startedAt: Date
        var listName: String
        var addedQuantity: Int
        var knownValueText: String
        var unpricedQuantity: Int
        var listID: UUID? = nil
        var game: String? = nil
        var statusRaw: String = "completed"
        var completedAt: Date? = nil
        var cashRateText: String? = nil
        var tradeRateText: String? = nil
        var maximumRateText: String? = nil
        var savedOffersData: Data? = nil
        var lastConsumedRecognitionRef: String? = nil
        init(listName: String) {
            id = UUID(); startedAt = .now; self.listName = listName
            addedQuantity = 0; knownValueText = "0"; unpricedQuantity = 0
        }
    }
}

enum ScannerSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [CardList.self, InventoryCard.self, ScanSession.self] }
}

enum ScannerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ScannerSchemaV1.self, ScannerSchemaV2.self, ScannerSchemaV3.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ScannerSchemaV1.self, toVersion: ScannerSchemaV2.self),
         .lightweight(fromVersion: ScannerSchemaV2.self, toVersion: ScannerSchemaV3.self)]
    }
}

@MainActor enum AppPersistence {
    static func open(url: URL? = nil) throws -> ModelContainer {
        let store: URL
        if let url { store = url }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            store = support.appendingPathComponent("default.store")
        }
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: ScannerSchemaV3.self)
        let configuration = ModelConfiguration("default", schema: schema, url: store, cloudKitDatabase: .none)
        // Never delete a store or substitute an in-memory database on migration failure.
        return try ModelContainer(for: schema, migrationPlan: ScannerMigrationPlan.self, configurations: [configuration])
    }
}
