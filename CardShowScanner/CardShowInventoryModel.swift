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
    private let provider: any CardShowInventoryProviding
    private let applySnapshot: @MainActor (CardShowInventorySnapshot, ModelContext) throws -> CardList
    private var active = false
    private var lookup: Task<Void, Never>?
    private var requestID = UUID()

    init(provider: (any CardShowInventoryProviding)? = nil,
         applySnapshot: @escaping @MainActor (CardShowInventorySnapshot, ModelContext) throws -> CardList = {
             try CardShowInventoryService.apply($0, context: $1)
         }) {
        self.provider = provider ?? CardShowInventoryWebsiteClient(); self.applySnapshot = applySnapshot
    }

    /// Making the page active opens only the saved copy. Refresh stays explicit.
    func setActive(_ active: Bool) {
        self.active = active
        if !active { cancel() }
    }

    func refresh(context: ModelContext) {
        guard active, !isRefreshing else { return }
        let expectedLocationID: Int?, importedListID: UUID?, sourceData: Data?
        do {
            let saved = try CardShowInventoryService.importedList(context: context)
            expectedLocationID = saved?.cardShowInventory?.locationID
            importedListID = saved?.id; sourceData = saved?.inventorySourceData
        } catch { showFailure(error); return }
        isRefreshing = true; message = nil; needsSignIn = false
        let id = UUID(); requestID = id
        DiagnosticLog.shared.record("inventory_import.started", ["phase": expectedLocationID == nil ? "import" : "refresh"])
        lookup = Task { [weak self, provider] in
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
                DiagnosticLog.shared.record("inventory_import.apply_started", ["phase": "persistence", "records": String(snapshot.rows.count)])
                let list = try self.applySnapshot(snapshot, context)
                self.lastImportedListID = list.id
                self.isRefreshing = false; self.lookup = nil
                self.message = "Saved \(snapshot.rows.count) inventory rows on this iPhone."
                DiagnosticLog.shared.record("inventory_import.finished", ["records": String(snapshot.rows.count), "quantity": String(list.quantity)])
            } catch {
                guard let self, !Task.isCancelled, self.active, self.requestID == id else { return }
                self.isRefreshing = false; self.lookup = nil
                if error is CancellationError { return }
                self.showFailure(error)
            }
        }
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
