import XCTest
@testable import CardShowScanner

@MainActor final class LabelPrintProgressSessionTests: XCTestCase {
    private func entries(_ count: Int) throws -> [LabelQueueEntry] {
        let paper = InventoryLabelSize.small30x14
        let raster = LabelRaster(width: 96, height: paper.feedDots,
            data: Data(repeating: 0x80, count: paper.feedDots * 12))
        return try (1...count).map { copy in
            try LabelQueueEntry(customPriceCents: 500, raster: raster, copyNumber: copy, paperSize: paper)
        }
    }

    private func queue(_ rows: [LabelQueueEntry]) throws -> LabelPrintQueue {
        let bytes = try JSONEncoder().encode(ProgressQueueDocument(version: 1, entries: rows))
        let storage = ProgressQueueStorage(bytes: bytes)
        return LabelPrintQueue(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            read: { _ in storage.bytes }, write: { data, _ in storage.bytes = data })
    }

    private func waitForFinalAcknowledgement(_ sender: ProgressGatedSender) async {
        for _ in 0..<100 where !sender.isWaiting { await Task.yield() }
        XCTAssertTrue(sender.isWaiting)
    }

    func testAllPhysicalCopiesCanBeConfirmedWhileProgressStillWaitsForFinalJobAcknowledgement() async throws {
        let queue = try queue(entries(2)), sender = ProgressGatedSender(), session = LabelPrintProgressSession()
        XCTAssertTrue(session.start(queue: queue, using: sender))
        await waitForFinalAcknowledgement(sender)
        XCTAssertEqual(session.completed(in: queue.entries), 2)
        XCTAssertEqual(session.total, 2)
        XCTAssertEqual(session.status(in: queue.entries, printerStatus: "Uploading"), "Finishing print job…")
        XCTAssertTrue(queue.isPrinting)
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.isPresented)
        XCTAssertFalse(session.didSucceed, "The last physical receipt cannot dismiss the sheet before PrintEnd completes")
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(queue.lastRunCompletedSuccessfully)
        XCTAssertTrue(session.didSucceed)
        XCTAssertFalse(session.isPresented)
        XCTAssertEqual(queue.entries.count, 2, "Successful navigation preserves all completion receipts")
    }

    func testParentStopAtTheFullCounterCannotBeMistakenForSuccessfulCompletion() async throws {
        let queue = try queue(entries(1)), sender = ProgressGatedSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        await waitForFinalAcknowledgement(sender)
        queue.stop(using: sender)
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertEqual(session.completed(in: queue.entries), 1)
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertFalse(session.didSucceed)
        XCTAssertTrue(session.isPresented, "A stopped job stays available for review even when buffered output completed")
        XCTAssertNotNil(session.issue)
        XCTAssertEqual(sender.cancels, 1)
        session.close()
        XCTAssertFalse(session.isPresented)
    }

    func testFailedJobKeepsProgressOpenForExplicitQueueReview() async throws {
        let queue = try queue(entries(1)), sender = ProgressGatedSender(failsBeforeProof: true)
        let session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        await session.waitUntilFinished()
        XCTAssertFalse(session.didSucceed)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(session.completed(in: queue.entries), 0)
        XCTAssertEqual(queue.uncertainCount, 1)
        XCTAssertNotNil(session.issue)
    }

    func testFinalAcknowledgementFailureKeepsReviewOpenAfterEveryPhysicalCopyWasConfirmed() async throws {
        let queue = try queue(entries(1)), sender = ProgressGatedSender(finalOutcome: .uncertain(.writeFailed))
        let session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        await waitForFinalAcknowledgement(sender)
        XCTAssertEqual(session.completed(in: queue.entries), 1)
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertFalse(session.didSucceed)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.isPresented)
        XCTAssertNotNil(session.issue)
        XCTAssertEqual(queue.completedCount, 1, "Failed final acknowledgement must preserve physical completion receipts")
    }

    func testInactiveAppCannotAutoNavigateWhenTheJobReturns() async throws {
        let queue = try queue(entries(1)), sender = ProgressGatedSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender, canFinish: { false })
        await waitForFinalAcknowledgement(sender)
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertTrue(queue.lastRunCompletedSuccessfully)
        XCTAssertFalse(session.didSucceed)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.isPresented)
        XCTAssertNotNil(session.issue)
    }

    func testProgressOnlyCountsPendingCopiesFromThisExplicitJob() async throws {
        var rows = try entries(3)
        rows[0].state = .completed
        let queue = try queue(rows), sender = ProgressGatedSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        await waitForFinalAcknowledgement(sender)
        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(session.total, 2)
        XCTAssertEqual(session.completed(in: queue.entries), 2)
        XCTAssertFalse(session.requestedIDs.contains(rows[0].id))
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertTrue(session.didSucceed)
    }

    func testOpeningAnAlreadyCompletedQueueDoesNotPresentOrAutoNavigate() throws {
        var rows = try entries(1)
        rows[0].state = .completed
        let queue = try queue(rows), sender = ProgressImmediateSender(), session = LabelPrintProgressSession()
        XCTAssertFalse(session.start(queue: queue, using: sender))
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.didSucceed)
        XCTAssertEqual(sender.sends, 0)
        XCTAssertEqual(queue.entries, rows)
    }

    func testEvenASynchronousSenderWaitsUntilTheProgressSheetAppears() async throws {
        let queue = try queue(entries(1)), sender = ProgressImmediateSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender, deferUntilPresented: true)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(session.isPresented)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(sender.sends, 0, "Success cannot happen before SwiftUI has established the progress presentation")
        session.presentationDidAppear()
        session.presentationDidAppear()
        await session.waitUntilFinished()
        XCTAssertEqual(sender.sends, 1, "Repeated appearance never starts a second print")
        XCTAssertTrue(session.didSucceed)
        XCTAssertFalse(session.isPresented)
    }

    func testBackgroundOrPauseBeforePresentationCancelsTheIntentWithoutSendingOnReturn() async throws {
        let queue = try queue(entries(1)), sender = ProgressImmediateSender(), session = LabelPrintProgressSession()
        let original = queue.entries
        session.start(queue: queue, using: sender, deferUntilPresented: true)
        session.stop(queue: queue, using: sender)
        session.presentationDidAppear()
        await session.waitUntilFinished()
        XCTAssertEqual(sender.sends, 0)
        XCTAssertFalse(session.didSucceed)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(queue.entries, original)
        XCTAssertFalse(queue.isPrinting)
    }

    func testChangedQueueBeforePresentationCannotPrintADifferentBatch() async throws {
        let queue = try queue(entries(1)), sender = ProgressImmediateSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender, deferUntilPresented: true)
        try queue.clear()
        session.presentationDidAppear()
        await session.waitUntilFinished()
        XCTAssertEqual(sender.sends, 0)
        XCTAssertFalse(session.didSucceed)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.isPresented)
        XCTAssertTrue(session.issue?.contains("queue changed") == true)
    }
}

private struct ProgressQueueDocument: Codable { let version: Int; let entries: [LabelQueueEntry] }
@MainActor private final class ProgressQueueStorage {
    var bytes: Data?
    init(bytes: Data) { self.bytes = bytes }
}

@MainActor private final class ProgressImmediateSender: LabelPrinterSending {
    var sends = 0
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { sends += 1; return .completed }
    func cancelPrinting() {}
}

@MainActor private final class ProgressGatedSender: LabelContinuousPrinterSending {
    let failsBeforeProof: Bool
    let finalOutcome: LabelSendOutcome
    var cancels = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    init(failsBeforeProof: Bool = false, finalOutcome: LabelSendOutcome = .completed) {
        self.failsBeforeProof = failsBeforeProof
        self.finalOutcome = finalOutcome
    }
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { .notSent(.unsupportedResponse) }
    func cancelPrinting() { cancels += 1 }
    func finish() { let waiting = continuation; continuation = nil; waiting?.resume() }

    func printContinuously(_ rasters: [LabelRaster],
                           beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                           afterPages: @escaping @MainActor ([Int]) async throws -> Void) async -> LabelSendOutcome {
        do {
            let pages = Array(rasters.indices)
            try await beforePages(pages)
            if failsBeforeProof { return .uncertain(.writeFailed) }
            try await afterPages(pages)
            await withCheckedContinuation { continuation = $0 }
            return finalOutcome
        } catch { return .notSent(.writeFailed) }
    }
}
