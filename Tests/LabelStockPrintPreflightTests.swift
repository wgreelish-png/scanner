import XCTest
@testable import CardShowScanner

@MainActor final class LabelStockPrintPreflightTests: XCTestCase {
    private func product(_ code: String = "120425109") throws -> NiimbotLabelProduct {
        try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: code))
    }

    private func entry(_ paper: InventoryLabelSize) throws -> LabelQueueEntry {
        let raster = LabelRaster(width: paper.headDots, height: paper.feedDots,
            data: Data(repeating: 0x80, count: 12 * paper.feedDots))
        return try LabelQueueEntry(customPriceCents: 500, raster: raster, copyNumber: 1, paperSize: paper)
    }

    private func fixture(_ paper: InventoryLabelSize) throws -> StockQueueFixture {
        let storage = StockQueueStorage()
        let queue = LabelPrintQueue(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            read: { _ in storage.data }, write: { bytes, _ in storage.data = bytes; storage.writes += 1 })
        try queue.replace(with: [entry(paper)])
        return StockQueueFixture(queue: queue, storage: storage)
    }

    func testKnownStockAcceptsOnlyMatchingCapturedGeometryAndMedia() throws {
        let stock = try product(), paper = try InventoryLabelSize(product: stock)
        XCTAssertNil(LabelStockCompatibility.issue(for: [paper, paper], detected: stock))
        XCTAssertNotNil(LabelStockCompatibility.issue(for: [.medium40x12], detected: stock),
            "An old full-head raster cannot silently acquire a newly detected printable region")
        XCTAssertNotNil(LabelStockCompatibility.issue(for: [paper, .small30x14], detected: stock))
        let sameGeometry = try NiimbotLabelProduct(code: "999999", width: stock.width, height: stock.height,
            rotation: stock.rotation, paperType: stock.paperType, flags: stock.flags, inputAreas: stock.inputAreas)
        XCTAssertNil(LabelStockCompatibility.issue(for: [paper], detected: sameGeometry),
            "Equivalent print geometry does not require re-rendering merely because the product code changed")
        let otherMedia = try NiimbotLabelProduct(code: "999998", width: stock.width, height: stock.height,
            rotation: stock.rotation, paperType: stock.paperType == 1 ? 5 : 1,
            flags: stock.flags, inputAreas: stock.inputAreas)
        XCTAssertNotNil(LabelStockCompatibility.issue(for: [paper], detected: otherMedia))
    }

    func testUnknownRollKeepsManualWorkflowButCannotValidateAnOldAutomaticSnapshot() throws {
        XCTAssertNil(LabelStockCompatibility.issue(for: InventoryLabelSize.allCases, detected: nil))
        let paper = try InventoryLabelSize(product: product())
        XCTAssertNotNil(LabelStockCompatibility.issue(for: [paper], detected: nil))
        XCTAssertNil(LabelStockCompatibility.issue(for: [], detected: try product()))
    }

    func testRejectedPreflightLeavesEveryReceiptAndSavedByteUntouched() async throws {
        let fixture = try fixture(.medium40x12), sender = StockCheckingSender()
        sender.issue = "The loaded roll changed."
        let before = fixture.queue.entries, bytes = fixture.storage.data, writes = fixture.storage.writes
        await fixture.queue.start(using: sender)
        XCTAssertEqual(sender.checkedPapers, [.medium40x12])
        XCTAssertEqual(sender.sends, 0)
        XCTAssertEqual(fixture.queue.entries, before)
        XCTAssertEqual(fixture.storage.data, bytes)
        XCTAssertEqual(fixture.storage.writes, writes, "No sending marker is written before stock validation")
        XCTAssertEqual(fixture.queue.error, sender.issue)
        XCTAssertFalse(fixture.queue.isPrinting)
    }

    func testMatchingPreflightPrintsTheOriginalQueuedRaster() async throws {
        let paper = try InventoryLabelSize(product: product()), fixture = try fixture(paper)
        let sender = StockCheckingSender(), original = try XCTUnwrap(fixture.queue.entries.first)
        await fixture.queue.start(using: sender)
        XCTAssertEqual(sender.checkedPapers, [paper])
        XCTAssertEqual(sender.rasters, [original.raster])
        XCTAssertEqual(fixture.queue.entries.first?.state, .completed)
        XCTAssertEqual(fixture.queue.entries.first?.paperSize, paper)
        XCTAssertEqual(fixture.queue.entries.first?.raster, original.raster)
    }

    func testPauseDuringStockReadCannotStartPrintingOrRewriteTheQueue() async throws {
        let fixture = try fixture(.small30x14), sender = StockCheckingSender()
        sender.waitForRelease = true
        let before = fixture.storage.data, writes = fixture.storage.writes
        let operation = Task { await fixture.queue.start(using: sender) }
        for _ in 0..<100 where sender.continuation == nil { await Task.yield() }
        XCTAssertNotNil(sender.continuation)
        fixture.queue.stop(using: sender)
        sender.continuation?.resume(returning: nil); sender.continuation = nil
        await operation.value
        XCTAssertEqual(sender.sends, 0)
        XCTAssertEqual(sender.cancels, 1)
        XCTAssertEqual(fixture.storage.data, before)
        XCTAssertEqual(fixture.storage.writes, writes)
        XCTAssertFalse(fixture.queue.isPrinting)
        XCTAssertEqual(fixture.queue.entries.first?.state, .pending)
    }

    func testRestoringDynamicSnapshotNeedsNoNewCatalogSelectionAndDoesNotRewriteArtwork() throws {
        let paper = try InventoryLabelSize(product: product()), fixture = try fixture(paper)
        let original = fixture.queue.entries, bytes = fixture.storage.data, writes = fixture.storage.writes
        let restored = LabelPrintQueue(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            read: { _ in fixture.storage.data }, write: { data, _ in fixture.storage.data = data; fixture.storage.writes += 1 })
        XCTAssertTrue(restored.isLoaded)
        XCTAssertEqual(restored.entries, original)
        XCTAssertEqual(restored.entries.first?.paperSize.geometry, paper.geometry)
        XCTAssertEqual(fixture.storage.data, bytes)
        XCTAssertEqual(fixture.storage.writes, writes)
    }
}

@MainActor private final class StockQueueStorage {
    var data: Data?
    var writes = 0
}

@MainActor private struct StockQueueFixture {
    let queue: LabelPrintQueue
    let storage: StockQueueStorage
}

@MainActor private final class StockCheckingSender: LabelPrinterSending, LabelStockValidating {
    var issue: String?
    var checkedPapers: [InventoryLabelSize] = []
    var rasters: [LabelRaster] = []
    var sends: Int { rasters.count }
    var cancels = 0
    var waitForRelease = false
    var continuation: CheckedContinuation<String?, Never>?

    func queuedPaperIssue(_ papers: [InventoryLabelSize]) async -> String? {
        checkedPapers = papers
        if waitForRelease { return await withCheckedContinuation { continuation = $0 } }
        return issue
    }
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { rasters.append(raster); return .completed }
    func cancelPrinting() { cancels += 1 }
}
