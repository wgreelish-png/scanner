import XCTest
@testable import CardShowScanner

@MainActor final class LabelPrintRunOutcomeTests: XCTestCase {
    private func fixture() throws -> (LabelPrintQueue, PrintRunStorage) {
        let storage = PrintRunStorage()
        let queue = LabelPrintQueue(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            read: { _ in storage.bytes }, write: { data, _ in
                storage.writes += 1
                if storage.writes == storage.failAtWrite { throw LabelPrintQueueFailure.saveFailed }
                storage.bytes = data
            })
        let raster = LabelRaster(width: 96, height: 240, data: Data(repeating: 0x80, count: 12 * 240))
        try queue.replace(with: [LabelQueueEntry(customPriceCents: 500, raster: raster,
            copyNumber: 1, paperSize: .small30x14)])
        return (queue, storage)
    }

    private func waitForFinishing(_ sender: PrintRunSender) async {
        for _ in 0..<100 where sender.finish == nil { await Task.yield() }
        XCTAssertNotNil(sender.finish, "The sender did not reach its final job confirmation")
    }

    func testPhysicalCountDoesNotBecomeSuccessUntilTheJobFinishes() async throws {
        let (queue, _) = try fixture(), sender = PrintRunSender()
        let operation = Task { await queue.start(using: sender) }
        await waitForFinishing(sender)
        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertTrue(queue.isPrinting)
        XCTAssertFalse(queue.lastRunCompletedSuccessfully, "All labels can print before the final job acknowledgement")
        sender.complete(.completed)
        await operation.value
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(queue.lastRunCompletedSuccessfully)
        let receipts = queue.entries
        await queue.start(using: sender)
        XCTAssertFalse(queue.lastRunCompletedSuccessfully, "Opening an old completed job cannot supply a new success event")
        XCTAssertEqual(queue.entries, receipts)
    }

    func testFinalAcknowledgementFailureKeepsPhysicalReceiptsButDoesNotNavigateAsSuccess() async throws {
        let (queue, _) = try fixture(), sender = PrintRunSender()
        let operation = Task { await queue.start(using: sender) }
        await waitForFinishing(sender)
        sender.complete(.uncertain(.responseTimeout))
        await operation.value
        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertEqual(queue.entries.first?.state, .completed)
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertNotNil(queue.error)
    }

    func testPauseRacingTheFinalConfirmationCannotTriggerAutomaticReturn() async throws {
        let (queue, _) = try fixture(), sender = PrintRunSender()
        let operation = Task { await queue.start(using: sender) }
        await waitForFinishing(sender)
        queue.stop(using: sender)
        sender.complete(.completed)
        await operation.value
        XCTAssertEqual(sender.cancels, 1)
        XCTAssertEqual(queue.completedCount, 1, "Stopping does not erase proven output")
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertFalse(queue.isPrinting)
    }

    func testTaskCancellationRacingTheFinalConfirmationCannotTriggerAutomaticReturn() async throws {
        let (queue, _) = try fixture(), sender = PrintRunSender()
        let operation = Task { await queue.start(using: sender) }
        await waitForFinishing(sender)
        operation.cancel()
        sender.complete(.completed)
        await operation.value
        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertFalse(queue.isPrinting)
    }

    func testUnsavedPhysicalCompletionCannotBecomeASuccessfulJob() async throws {
        let (queue, storage) = try fixture(), sender = PrintRunSender()
        storage.failAtWrite = 3 // Initial queue, sending marker, completion receipt.
        await queue.start(using: sender)
        XCTAssertEqual(queue.completedCount, 1, "Observed output remains visible while storage is blocked")
        XCTAssertFalse(queue.isLoaded)
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertNotNil(queue.error)
        XCTAssertNil(sender.finish, "The failed receipt cannot advance to a successful final acknowledgement")
    }
}

@MainActor private final class PrintRunStorage {
    var bytes: Data?
    var writes = 0
    var failAtWrite: Int?
}

@MainActor private final class PrintRunSender: LabelBatchPrinterSending {
    var finish: CheckedContinuation<LabelSendOutcome, Never>?
    var cancels = 0

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { .notSent(.unsupportedResponse) }

    func printBatch(_ rasters: [LabelRaster],
                    beforePage: @escaping @MainActor (Int) async throws -> Void,
                    afterPage: @escaping @MainActor (Int) async throws -> Void) async -> LabelSendOutcome {
        do {
            for page in rasters.indices {
                try await beforePage(page)
                try await afterPage(page)
            }
        } catch { return .uncertain(.writeFailed) }
        return await withCheckedContinuation { finish = $0 }
    }

    func complete(_ outcome: LabelSendOutcome) {
        let continuation = finish; finish = nil
        continuation?.resume(returning: outcome)
    }
    func cancelPrinting() { cancels += 1 }
}
