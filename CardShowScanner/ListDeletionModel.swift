import Foundation
import Observation
import SwiftData

/// The confirmation owns values, not a SwiftData object that a query can replace.
struct ListDeletionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let quantity: Int
    let isImportedInventory: Bool

    @MainActor init(list: CardList) {
        self.init(id: list.id, name: list.name, quantity: list.quantity, isImportedInventory: list.isCardShowInventory)
    }

    init(id: UUID, name: String, quantity: Int, isImportedInventory: Bool = false) {
        self.id = id; self.name = name; self.quantity = quantity; self.isImportedInventory = isImportedInventory
    }
}

@MainActor @Observable final class ListDeletionModel {
    private struct RollbackState {
        let list: CardList?
        let cards: [InventoryCard]
        let sessions: [(session: ScanSession, listID: UUID?, name: String, status: String, completedAt: Date?)]

        init(id: UUID, context: ModelContext) throws {
            list = try context.fetch(FetchDescriptor<CardList>(predicate: #Predicate { $0.id == id })).first
            cards = list?.cards ?? []
            sessions = try context.fetch(FetchDescriptor<ScanSession>()).filter { $0.listID == id }.map {
                ($0, $0.listID, $0.listName, $0.statusRaw, $0.completedAt)
            }
        }
        func restore(context: ModelContext) {
            context.rollback()
            // SwiftData rollback can retain changed values in live models and
            // relationship arrays. Restore this operation's cached state too.
            if let list { list.cards = cards }
            for snapshot in sessions {
                snapshot.session.listID = snapshot.listID
                snapshot.session.listName = snapshot.name
                snapshot.session.statusRaw = snapshot.status
                snapshot.session.completedAt = snapshot.completedAt
            }
            context.processPendingChanges()
        }
    }
    let request: ListDeletionRequest
    private(set) var isDeleting = false
    private(set) var didDelete = false
    private(set) var error: String?
    private let delete: @MainActor (UUID, ModelContext) throws -> Void
    private let log: DiagnosticLog
    private var hasPresented = false
    private var hasCancelled = false
    private var hasDismissed = false

    init(request: ListDeletionRequest,
         delete: @escaping @MainActor (UUID, ModelContext) throws -> Void = {
             try SessionService.deleteList(id: $0, context: $1)
         }, log: DiagnosticLog? = nil) {
        self.request = request; self.delete = delete; self.log = log ?? .shared
    }

    /// True only after the deletion commits, or the target is already absent.
    @discardableResult func confirm(context: ModelContext) -> Bool {
        guard !isDeleting, !didDelete, !hasCancelled, !hasDismissed else { return false }
        isDeleting = true; error = nil
        defer { isDeleting = false }
        log.record("list.delete_confirmed", ["quantity": String(request.quantity)])
        var previous: RollbackState?
        do {
            previous = try RollbackState(id: request.id, context: context)
            try delete(request.id, context)
            didDelete = true
            return true
        } catch {
            // The production save already rolls back. This also protects the
            // draft when an injected or future deletion operation throws early.
            if let previous { previous.restore(context: context) }
            else { context.rollback() }
            log.failure("list.delete_attempt_failed", error)
            self.error = "The list could not be deleted. It has been kept. Tap Retry Delete to try again."
            return false
        }
    }

    func presented() {
        guard !hasPresented else { return }
        hasPresented = true
        log.record("list.delete_presented", ["quantity": String(request.quantity)])
    }

    func cancel() {
        guard !isDeleting, !didDelete, !hasCancelled, !hasDismissed else { return }
        hasCancelled = true
        log.record("list.delete_cancelled", ["quantity": String(request.quantity)])
    }

    func dismissed() {
        guard !hasDismissed else { return }
        hasDismissed = true
        log.record("list.delete_dismissed", ["reason": didDelete ? "deleted" : (hasCancelled ? "cancelled" : "unconfirmed")])
    }
}
