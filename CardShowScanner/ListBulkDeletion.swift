import Foundation
import Observation
import SwiftData
import SwiftUI

enum ListBulkDeletionFailure: LocalizedError, Equatable {
    case pendingChanges
    var errorDescription: String? {
        "Finish or cancel other edits before deleting selected lists. Your lists have been kept."
    }
}

struct ListBulkDeletionRequest: Identifiable, Sendable {
    let id = UUID()
    let lists: [ListDeletionRequest]
    var ids: Set<UUID> { Set(lists.map(\.id)) }
    var quantity: Int { lists.reduce(0) { $0 + $1.quantity } }
    var containsImportedInventory: Bool { lists.contains { $0.isImportedInventory } }

    @MainActor init(lists: [CardList]) {
        var seen = Set<UUID>()
        self.lists = lists.filter { seen.insert($0.id).inserted }.map(ListDeletionRequest.init)
    }
}

/// Selected lists and their source rows commit in one save. Session history,
/// stored offer snapshots and recorded financial receipts remain independent.
@MainActor enum ListBulkDeletionService {
    @discardableResult static func delete(ids: Set<UUID>, context: ModelContext,
        save: (@MainActor (ModelContext) throws -> Void)? = nil) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let lists = try context.fetch(FetchDescriptor<CardList>()).filter { ids.contains($0.id) }
        guard !lists.isEmpty else { return 0 }
        // Never roll back somebody else's uncommitted card/outcome draft.
        guard !context.hasChanges else { throw ListBulkDeletionFailure.pendingChanges }
        let resolvedIDs = Set(lists.map(\.id))
        let history = try context.fetch(FetchDescriptor<ScanSession>()).filter { $0.listID.map(resolvedIDs.contains) == true }
        let listStates = lists.map { ($0, $0.cards) }
        let sessionStates = history.map { ($0, $0.listID, $0.listName, $0.statusRaw, $0.completedAt) }
        let names = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) })
        let quantity = lists.reduce(0) { $0 + $1.quantity }
        do {
            for session in history {
                if let id = session.listID, let name = names[id] { session.listName = name }
                session.listID = nil
                if session.statusRaw == "active" { session.statusRaw = "completed"; session.completedAt = .now }
            }
            for list in lists { context.delete(list) }
            if let save { try save(context) } else { try context.save() }
            DiagnosticLog.shared.record("list.bulk_deleted", ["records": String(lists.count), "quantity": String(quantity)])
            return lists.count
        } catch {
            context.rollback()
            for (list, cards) in listStates where Set(list.cards.map(\.id)) != Set(cards.map(\.id)) { list.cards = cards }
            for (session, listID, name, status, completion) in sessionStates {
                if session.listID != listID { session.listID = listID }
                if session.listName != name { session.listName = name }
                if session.statusRaw != status { session.statusRaw = status }
                if session.completedAt != completion { session.completedAt = completion }
            }
            context.processPendingChanges()
            if context.hasChanges { context.rollback(); context.processPendingChanges() }
            DiagnosticLog.shared.failure("list.bulk_delete_failed", error)
            throw error
        }
    }
}

@MainActor @Observable final class ListBulkDeletionModel {
    let request: ListBulkDeletionRequest
    private(set) var isDeleting = false
    private(set) var didDelete = false
    private(set) var error: String?
    private var cancelled = false
    private let delete: @MainActor (Set<UUID>, ModelContext) throws -> Void

    init(request: ListBulkDeletionRequest,
         delete: @escaping @MainActor (Set<UUID>, ModelContext) throws -> Void = {
             try SessionService.deleteLists(ids: $0, context: $1)
         }) {
        self.request = request; self.delete = delete
    }

    @discardableResult func confirm(context: ModelContext) -> Bool {
        guard !isDeleting, !didDelete, !cancelled else { return false }
        isDeleting = true; error = nil
        defer { isDeleting = false }
        do {
            try delete(request.ids, context)
            didDelete = true
            return true
        } catch {
            self.error = (error as? ListBulkDeletionFailure)?.errorDescription
                ?? "The selected lists could not be deleted. They have been kept. Tap Retry Delete to try again."
            return false
        }
    }

    func cancel() { guard !isDeleting, !didDelete else { return }; cancelled = true }
}

struct ListBulkDeletionConfirmationView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var model: ListBulkDeletionModel
    let onDeleted: () -> Void
    init(request: ListBulkDeletionRequest, onDeleted: @escaping () -> Void) {
        _model = State(initialValue: ListBulkDeletionModel(request: request)); self.onDeleted = onDeleted
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Delete \(model.request.lists.count) lists and \(model.request.quantity) cards?").font(.headline)
                    Text("Session history, saved offers and recorded show-budget transactions are kept.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.request.containsImportedInventory {
                        Text("The Card Show saved copy is removed only from this iPhone. TCGTracking inventory stays unchanged.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section("Selected lists") {
                    ForEach(model.request.lists) { list in
                        LabeledContent(list.name, value: "\(list.quantity) cards")
                    }
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("bulkDeletion.error") } }
                Section {
                    Button(model.error == nil ? "Delete Selected Lists" : "Retry Delete", role: .destructive) {
                        if model.confirm(context: context) { onDeleted(); dismiss() }
                    }.disabled(model.isDeleting).accessibilityIdentifier("bulkDeletion.confirm")
                }
            }.navigationTitle("Delete Selected Lists").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel(); dismiss() }.disabled(model.isDeleting)
                            .accessibilityIdentifier("bulkDeletion.cancel")
                    }
                }
        }.interactiveDismissDisabled(model.isDeleting)
            .onDisappear { model.cancel() }
    }
}

#if DEBUG
@MainActor struct ListBulkDeletionFixtureScreen: View {
    @State private var container: ModelContainer
    init() {
        let value = try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for name in ["Bulk Fixture Alpha", "Bulk Fixture Beta", "Bulk Fixture Keep"] {
            value.mainContext.insert(CardList(name: name))
        }
        try! value.mainContext.save()
        _container = State(initialValue: value)
    }
    var body: some View { NavigationStack { SavedListsView() }.modelContainer(container) }
}
#endif
