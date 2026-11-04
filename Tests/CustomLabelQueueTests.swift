import XCTest
@testable import CardShowScanner

@MainActor final class CustomLabelQueueTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CustomLabelQueueTests-" + UUID().uuidString)
    }

    private func raster(_ paper: InventoryLabelSize = .small30x14) -> LabelRaster {
        LabelRaster(width: paper.headDots, height: paper.feedDots,
                    data: Data(repeating: 0x80, count: 12 * paper.feedDots))
    }

    private func custom(price: Int64 = 500, copy: Int = 1,
                        paper: InventoryLabelSize = .small30x14) throws -> LabelQueueEntry {
        try LabelQueueEntry(customPriceCents: price, raster: raster(paper), copyNumber: copy, paperSize: paper)
    }

    private func inventory(id: UUID = UUID(), cents: Int64 = 1_000,
                           revision: UUID? = nil) throws -> LabelQueueEntry {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Inventory fixture", set: "Set", number: "42", marketPrice: 10,
            confidence: 100, printings: ["Normal"])
        var draft = InventoryLabelDraft(item: ShowInventoryItem(id: id, card: card, quantity: 1))
        draft.askingPriceText = InventoryLabelDraft.inputText(cents)
        return try LabelQueueEntry(draft: draft, raster: raster(), copyNumber: 1, pricingRevisionID: revision)
    }

    private func document(_ entry: LabelQueueEntry,
                          change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let encoded = try JSONEncoder().encode(entry)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        change(&row)
        return try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [row]])
    }

    private func decodedEntry(_ data: Data) throws -> LabelQueueEntry {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        return try JSONDecoder().decode(LabelQueueEntry.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(entries.first)))
    }

    private func queue(_ storage: CustomLabelQueueStorage, approvals: TagApprovalStore? = nil) -> LabelPrintQueue {
        LabelPrintQueue(url: location(), read: { _ in storage.bytes },
            write: { data, _ in storage.bytes = data; storage.writes += 1 },
            onChanged: { entries in
                guard let approvals else { return }
                do { try approvals.observeCompletedQueue(entries) }
                catch { XCTFail("Custom-only queue must not require approval storage: \(error)") }
            }, approvalIssue: { entry in
                guard let approvals else { return nil }
                return TagPricingContext.printingIssue(for: entry, store: approvals)
            })
    }

    private func approvalStore(unavailable: Bool = false) -> TagApprovalStore {
        TagApprovalStore(url: location(), read: { _ in
            if unavailable { throw TagApprovalStoreFailure.loadFailed }
            return nil
        }, write: { _, _ in })
    }

    func testStandaloneInitializerRequiresWholeDollarPriceAndExistingPaperCopyLimits() throws {
        let entry = try custom(price: 0, copy: 100, paper: .large50x14)
        XCTAssertEqual(entry.source, .custom)
        XCTAssertNil(entry.inventoryID)
        XCTAssertNil(entry.pricingRevisionID)
        XCTAssertEqual(entry.cardName, "Custom price tag")
        XCTAssertEqual(entry.style, .priceOnly)
        XCTAssertEqual(entry.priceCents, 0, "Known zero is valid")
        XCTAssertNoThrow(try entry.validate())
        for price in [Int64(-100), 1, 550, ShowBudgetMoney.maximumCents + 1] {
            XCTAssertThrowsError(try custom(price: price))
        }
        for copy in [0, 101] { XCTAssertThrowsError(try custom(copy: copy)) }
        XCTAssertThrowsError(try LabelQueueEntry(customPriceCents: 500, raster: raster(), copyNumber: 1,
                                                paperSize: .large50x14))
    }

    func testStandaloneQueuePersistsWithoutStartingAndPrintsWithUnavailableApprovals() async throws {
        let storage = CustomLabelQueueStorage(), approvals = approvalStore(unavailable: true)
        let queue = queue(storage, approvals: approvals), printer = CustomLabelQueuePrinter()
        let entries = try [custom(copy: 1), custom(copy: 2)]
        XCTAssertFalse(approvals.isLoaded)
        try queue.replace(with: entries)
        XCTAssertEqual(printer.sent, 0)
        XCTAssertFalse(queue.isPrinting)
        let restored = self.queue(storage, approvals: approvals)
        XCTAssertEqual(restored.entries, entries)
        XCTAssertNil(TagPricingContext.printingIssue(for: entries[0], store: approvals))
        await restored.start(using: printer)
        XCTAssertEqual(printer.sent, 2)
        XCTAssertEqual(restored.completedCount, 2)
        XCTAssertTrue(approvals.records.isEmpty)
        let completed = self.queue(storage, approvals: approvals)
        XCTAssertEqual(completed.completedCount, 2)
        XCTAssertFalse(completed.canStart, "Completed standalone labels cannot restart automatically")
    }

    func testLegacyMissingSourceKeepsItsInventoryIdentityAndCentsWithoutRewritingStorage() throws {
        let original = try inventory()
        XCTAssertEqual(original.source, .inventory)
        let bytes = try document(original) {
            $0.removeValue(forKey: "source")
            $0.removeValue(forKey: "pricingRevisionID")
            $0["priceCents"] = 1_450
        }
        let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
        let saved = try XCTUnwrap(queue.entries.first)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertNil(saved.source)
        XCTAssertEqual(saved.inventoryID, original.inventoryID)
        XCTAssertEqual(saved.priceCents, 1_450)
        XCTAssertNoThrow(try saved.validate())
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertNotNil(TagPricingContext.printingIssue(for: saved, store: approvalStore(unavailable: true)),
                        "Missing source/revision cannot bypass inventory approval availability")
    }

    func testUnknownOrMalformedSourceAndLegacyWithoutInventoryIdentityFailClosed() throws {
        let original = try inventory()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["source"] = "future-kind" },
            { $0["source"] = 123 },
            { $0["source"] = "inventory"; $0.removeValue(forKey: "inventoryID") },
            { $0.removeValue(forKey: "source"); $0.removeValue(forKey: "inventoryID") },
            { $0["source"] = NSNull(); $0.removeValue(forKey: "inventoryID") }
        ]
        for change in mutations {
            let bytes = try document(original, change: change)
            let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
        }
    }

    func testCustomContradictoryIdentityRevisionStyleOrCentsCannotUseApprovalExemption() throws {
        let original = try custom(), approvals = approvalStore(unavailable: true)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["inventoryID"] = UUID().uuidString },
            { $0["pricingRevisionID"] = UUID().uuidString },
            { $0["style"] = InventoryLabelStyle.cardDetails.rawValue },
            { $0["priceCents"] = 550 }
        ]
        for change in mutations {
            let bytes = try document(original, change: change)
            let decoded = try decodedEntry(bytes)
            XCTAssertThrowsError(try decoded.validate())
            XCTAssertNotNil(TagPricingContext.printingIssue(for: decoded, store: approvals))
            let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
        }
    }

    func testCustomCompletionNeverAcknowledgesAnInventoryApprovalEvenWithInjectedMatchingIdentifiers() throws {
        let approvals = approvalStore(), id = UUID()
        try approvals.approve([.init(id: id, approvedTag: .individual(500), currentMarket: 5)])
        let record = try XCTUnwrap(approvals.record(for: id)), original = try custom()
        let malformed = try decodedEntry(document(original) {
            $0["inventoryID"] = id.uuidString
            $0["pricingRevisionID"] = record.priceRevisionID.uuidString
            $0["state"] = LabelQueueState.completed.rawValue
        })
        XCTAssertThrowsError(try malformed.validate())
        try approvals.observeCompletedQueue([malformed])
        XCTAssertEqual(approvals.record(for: id), record)
        XCTAssertTrue(try XCTUnwrap(approvals.record(for: id)).needsLabels)
    }

    func testInventoryStalePriceAndRevisionStillBlockPrinterTransport() async throws {
        let approvals = approvalStore(), id = UUID()
        try approvals.approve([.init(id: id, approvedTag: .individual(1_000), currentMarket: 10)])
        let firstRevision = try XCTUnwrap(approvals.record(for: id)).priceRevisionID
        let entry = try inventory(id: id, revision: firstRevision)
        try approvals.approve([.init(id: id, approvedTag: .individual(1_200), currentMarket: 12)])
        XCTAssertNotNil(TagPricingContext.printingIssue(for: entry, store: approvals))
        try approvals.approve([.init(id: id, approvedTag: .individual(1_000), currentMarket: 10)])
        XCTAssertNotEqual(approvals.record(for: id)?.priceRevisionID, firstRevision)
        XCTAssertNotNil(TagPricingContext.printingIssue(for: entry, store: approvals))
        let storage = CustomLabelQueueStorage(), queue = queue(storage, approvals: approvals)
        try queue.replace(with: [entry])
        let printer = CustomLabelQueuePrinter()
        await queue.start(using: printer)
        XCTAssertEqual(printer.sent, 0)
        XCTAssertEqual(queue.entries.first?.state, .failed)
        XCTAssertTrue(try XCTUnwrap(approvals.record(for: id)).needsLabels)
    }
}

@MainActor private final class CustomLabelQueueStorage {
    var bytes: Data?
    var writes = 0
    init(bytes: Data? = nil) { self.bytes = bytes }
}

@MainActor private final class CustomLabelQueuePrinter: LabelPrinterSending {
    var sent = 0
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { sent += 1; return .completed }
    func cancelPrinting() {}
}
