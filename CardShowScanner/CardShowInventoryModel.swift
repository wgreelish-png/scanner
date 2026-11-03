import Foundation
import Observation
import SwiftData

/// The importer never clears a saved list while a download is in progress.
/// Only one complete, current foreground response can reach persistence.
@MainActor @Observable final class CardShowInventoryModel {
    private(set) var isRefreshing = false
    private(set) var message: String?
    private(set) var needsSignIn = false
    private(set) var lastImportedListID: UUID?
    private(set) var workingSyncFailed = false
    private(set) var requiresFreshInventoryRefresh = false
    let workingStore: ShowBudgetStore
    private let provider: any CardShowInventoryProviding
    private let applySnapshot: @MainActor (CardShowInventorySnapshot, ModelContext) throws -> CardList
    private let synchronizeWorkingInventory: @MainActor (CardList, ModelContext, ShowBudgetStore) throws -> ShowInventoryReconciliationSummary
    private var active = false
    private var lookup: Task<Void, Never>?
    private var requestID = UUID()

    init(provider: (any CardShowInventoryProviding)? = nil,
         workingStore: ShowBudgetStore = .shared,
         applySnapshot: (@MainActor (CardShowInventorySnapshot, ModelContext) throws -> CardList)? = nil,
         synchronizeWorkingInventory: @escaping @MainActor (CardList, ModelContext, ShowBudgetStore) throws -> ShowInventoryReconciliationSummary = {
             try ShowInventoryBridge.synchronizeImportedList($0, context: $1, store: $2)
         }) {
        self.provider = provider ?? CardShowInventoryWebsiteClient()
        self.applySnapshot = applySnapshot ?? { snapshot, context in
            try CardShowInventoryService.apply(snapshot, context: context, workingRevision: ShowInventorySyncRevision(store: workingStore))
        }
        self.workingStore = workingStore; self.synchronizeWorkingInventory = synchronizeWorkingInventory
    }

    /// Making the page active opens only the saved copy. Refresh stays explicit.
    func setActive(_ active: Bool) {
        self.active = active
        if !active { cancel() }
    }

    func refresh(context: ModelContext) {
        guard active, !isRefreshing else { return }
        let expectedLocationID: Int?, importedListID: UUID?, sourceData: Data?
        let workingVersion: ShowInventorySyncRevision
        do {
            guard !context.hasChanges else { throw CardShowInventoryFailure.persistenceFailed }
            try reloadWorkingStore()
            let saved = try CardShowInventoryService.importedList(context: context)
            // Finish a previous interrupted handoff before replacing its durable marker.
            if let saved, saved.cardShowInventory?.pendingWorkingSync == true, !pendingSnapshotIsStale(saved) {
                do { _ = try synchronizeWorkingInventory(saved, context, workingStore) }
                catch { showWorkingSyncFailure(error); return }
            }
            if let savedLocation = saved?.cardShowInventory?.locationID,
               let workingLocation = workingStore.inventorySourceLocationID, savedLocation != workingLocation {
                throw CardShowInventoryFailure.locationChanged
            }
            expectedLocationID = saved?.cardShowInventory?.locationID ?? workingStore.inventorySourceLocationID
            importedListID = saved?.id; sourceData = saved?.inventorySourceData
            workingVersion = ShowInventorySyncRevision(store: workingStore)
        } catch { showFailure(error); return }
        isRefreshing = true; message = nil; needsSignIn = false; workingSyncFailed = false
        requiresFreshInventoryRefresh = false; lastImportedListID = nil
        let id = UUID(); requestID = id
        DiagnosticLog.shared.record("inventory_import.started", ["phase": expectedLocationID == nil ? "import" : "refresh"])
        lookup = Task { [weak self, provider] in
            var sourceSaved = false
            do {
                let snapshot = try await provider.fetch(expectedLocationID: expectedLocationID)
                try Task.checkCancellation()
                guard let self, self.active, self.requestID == id else { return }
                // Another page may have deleted, replaced or refreshed this copy
                // while the website request was suspended. A late response must
                // never recreate it or overwrite that newer committed snapshot.
                let current = try CardShowInventoryService.importedList(context: context)
                guard current?.id == importedListID, current?.inventorySourceData == sourceData else {
                    self.isRefreshing = false; self.lookup = nil; self.needsSignIn = false
                    self.message = "Saved inventory changed during this download. Its current copy is kept; tap Refresh again."
                    DiagnosticLog.shared.record("inventory_import.discarded", ["reason": "saved_inventory_changed"])
                    return
                }
                try self.reloadWorkingStore()
                guard ShowInventorySyncRevision(store: self.workingStore) == workingVersion else {
                    self.isRefreshing = false; self.lookup = nil
                    self.message = "Working inventory changed during this download. Your changes are kept; tap Refresh again."
                    DiagnosticLog.shared.record("inventory_import.discarded", ["reason": "working_inventory_changed"])
                    return
                }
                guard expectedLocationID.map({ $0 == snapshot.location.id }) ?? true else {
                    throw CardShowInventoryFailure.locationChanged
                }
                DiagnosticLog.shared.record("inventory_import.working_before", ["records": String(self.workingStore.inventory.filter { $0.quantity > 0 }.count), "quantity": String(self.workingQuantity)])
                DiagnosticLog.shared.record("inventory_import.apply_started", ["phase": "persistence", "records": String(snapshot.rows.count)])
                let list = try self.applySnapshot(snapshot, context)
                sourceSaved = true
                _ = try self.synchronizeWorkingInventory(list, context, self.workingStore)
                self.lastImportedListID = list.id
                self.isRefreshing = false; self.lookup = nil
                self.message = "Updated inventory: \(snapshot.rows.count) rows, \(list.quantity) physical cards."
                DiagnosticLog.shared.record("inventory_import.working_after", ["records": String(self.workingStore.inventory.filter { $0.quantity > 0 }.count), "quantity": String(self.workingQuantity)])
                DiagnosticLog.shared.record("inventory_import.finished", ["records": String(snapshot.rows.count), "quantity": String(list.quantity)])
            } catch {
                guard let self, !Task.isCancelled, self.active, self.requestID == id else { return }
                self.isRefreshing = false; self.lookup = nil
                if error is CancellationError { return }
                if sourceSaved {
                    self.showWorkingSyncFailure(error, list: try? CardShowInventoryService.importedList(context: context))
                } else { self.showFailure(error) }
            }
        }
    }

    /// Complete a saved download without another website request. The financial
    /// marker makes retries safe even if its write succeeded before an error.
    func retryWorkingInventory(context: ModelContext) {
        guard active, !isRefreshing else { return }
        var pendingList: CardList?
        do {
            guard let list = try CardShowInventoryService.importedList(context: context),
                  list.cardShowInventory?.pendingWorkingSync == true else { return }
            pendingList = list
            let result = try synchronizeWorkingInventory(list, context, workingStore)
            workingSyncFailed = false; requiresFreshInventoryRefresh = false
            needsSignIn = false; lastImportedListID = list.id
            message = "Inventory update finished. \(result.totalQuantity) physical cards available."
            DiagnosticLog.shared.record("inventory_import.working_retry_finished", ["records": String(workingStore.inventory.filter { $0.quantity > 0 }.count), "quantity": String(workingQuantity)])
        } catch { showWorkingSyncFailure(error, list: pendingList) }
    }

    private var workingQuantity: Int { workingStore.inventory.reduce(0) { $0 + $1.quantity } }

    private func reloadWorkingStore() throws {
        guard !workingStore.isSaving else { throw ShowBudgetStoreFailure.saving }
        workingStore.reload()
        guard workingStore.isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
    }

    private func pendingSnapshotIsStale(_ list: CardList) -> Bool {
        guard workingStore.isLoaded, let link = list.cardShowInventory,
              let marker = link.inventorySnapshotID, let revision = link.workingRevision,
              !workingStore.inventoryReconciliations.contains(where: { $0.snapshotID == marker }) else { return false }
        return revision != ShowInventorySyncRevision(store: workingStore)
    }

    private func showWorkingSyncFailure(_ error: Error, list: CardList? = nil) {
        workingSyncFailed = true; needsSignIn = false; lastImportedListID = nil
        requiresFreshInventoryRefresh = list.map(pendingSnapshotIsStale) ?? false
        message = requiresFreshInventoryRefresh
            ? "Working inventory changed after this download. Your changes are kept; tap Refresh Inventory for a new website copy."
            : "Website inventory was downloaded, but finishing the local inventory update failed. Tap Retry Inventory Update."
        DiagnosticLog.shared.record("inventory_import.working_sync_failed", ServiceDiagnosticFields.failure(error).merging(["phase": "working_inventory"]) { _, value in value })
    }

    func cancel() {
        requestID = UUID(); lookup?.cancel(); lookup = nil
        provider.cancel(); isRefreshing = false
    }

    private func showFailure(_ error: Error) {
        let failure = error as? CardShowInventoryFailure
        if case .signInRequired? = failure { needsSignIn = true } else { needsSignIn = false }
        message = failure?.errorDescription ?? CardShowInventoryFailure.persistenceFailed.errorDescription
        var fields = ServiceDiagnosticFields.failure(error)
        fields["phase"] = needsSignIn ? "sign_in" : "import"
        DiagnosticLog.shared.record("inventory_import.failed", fields)
    }
}
