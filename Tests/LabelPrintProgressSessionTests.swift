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

    private func queue(_ rows: [LabelQueueEntry], storage providedStorage: ProgressQueueStorage? = nil) throws -> LabelPrintQueue {
        let bytes = try JSONEncoder().encode(ProgressQueueDocument(version: 1, entries: rows))
        let storage = providedStorage ?? ProgressQueueStorage(bytes: bytes)
        storage.bytes = bytes
        return LabelPrintQueue(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            read: { _ in storage.bytes }, write: { data, _ in
                if storage.failsWrites { throw ProgressStorageFailure.injected }
                storage.bytes = data
            })
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

    func testCustomCompletionClearsOnlyAfterFinalAcknowledgementAndPresentationDismissal() async throws {
        let queue = try queue(entries(2)), sender = ProgressGatedSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        await waitForFinalAcknowledgement(sender)
        XCTAssertFalse(try session.completePresentation(queue: queue))
        XCTAssertEqual(queue.completedCount, 2, "A full counter alone cannot clear labels")
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertEqual(session.completed(in: queue.entries), 2, "The final counter stays visible until progress dismisses")
        XCTAssertTrue(try session.completePresentation(queue: queue))
        XCTAssertTrue(queue.entries.isEmpty)
        queue.reload()
        XCTAssertTrue(queue.entries.isEmpty, "Successful custom cleanup must survive relaunch")
        XCTAssertFalse(try session.completePresentation(queue: queue), "Repeated sheet dismissal cannot repeat cleanup or navigation")
    }

    func testSuccessfulMixedJobRetiresOnlyItsCustomCopiesAndKeepsInventoryAndUnrelatedReceipts() async throws {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:1", printing: "Normal"),
            name: "Inventory proof", set: "Fixture", number: "1", marketPrice: 5, confidence: 100, printings: ["Normal"])
        let draft = InventoryLabelDraft(item: .init(card: card, quantity: 1))
        let custom = try entries(1)[0]
        let inventory = try LabelQueueEntry(draft: draft, raster: custom.raster, copyNumber: 1)
        var priorReceipt = try entries(1)[0]
        priorReceipt.state = .completed
        let queue = try queue([priorReceipt, custom, inventory]), sender = ProgressGatedSender()
        let session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        await waitForFinalAcknowledgement(sender)
        sender.finish(); await session.waitUntilFinished()
        let retained = queue.entries.filter { $0.id != custom.id }
        XCTAssertTrue(try session.completePresentation(queue: queue))
        XCTAssertEqual(queue.entries, retained, "Inventory proof and custom receipts from an earlier job are unrelated")
        XCTAssertEqual(queue.entries.map(\.id), [priorReceipt.id, inventory.id])
        XCTAssertTrue(queue.entries.allSatisfy { $0.state == .completed })
    }

    func testBulkAndWriteInCustomLabelsClearAfterConfirmedCompletionWithoutApprovalProof() async throws {
        let sample = try entries(1)[0]
        for bulk in [false, true] {
            let entry = try LabelQueueEntry(customPriceCents: 0, raster: sample.raster, copyNumber: 1,
                paperSize: sample.paperSize, isBulk: bulk)
            let queue = try queue([entry]), sender = ProgressImmediateSender(), session = LabelPrintProgressSession()
            session.start(queue: queue, using: sender); await session.waitUntilFinished()
            XCTAssertTrue(session.didSucceed)
            XCTAssertEqual(queue.completedCount, 1)
            XCTAssertTrue(try session.completePresentation(queue: queue))
            XCTAssertTrue(queue.entries.isEmpty)
        }
    }

    func testStaleSuccessfulPresentationCannotClearAReplacementQueue() async throws {
        let queue = try queue(entries(1)), sender = ProgressImmediateSender(), session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender); await session.waitUntilFinished()
        let replacement = try entries(2)
        try queue.replace(with: replacement)
        XCTAssertThrowsError(try session.completePresentation(queue: queue)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .invalidSelection)
        }
        XCTAssertEqual(queue.entries, replacement)
        XCTAssertEqual(sender.sends, 1, "Cleanup never sends another label")
    }

    func testCustomCleanupSaveFailureKeepsConfirmedReceiptsAndAllowsReviewWithoutPrintingAgain() async throws {
        let storage = ProgressQueueStorage(bytes: nil)
        let queue = try queue(entries(1), storage: storage), sender = ProgressImmediateSender()
        let session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender); await session.waitUntilFinished()
        let completed = queue.entries, saved = storage.bytes
        storage.failsWrites = true
        XCTAssertThrowsError(try session.completePresentation(queue: queue)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .saveFailed)
        }
        XCTAssertEqual(queue.entries, completed)
        XCTAssertEqual(storage.bytes, saved)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertNotNil(session.issue)
        XCTAssertEqual(sender.sends, 1)
        storage.failsWrites = false; queue.reload()
        XCTAssertTrue(try session.completePresentation(queue: queue))
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertEqual(sender.sends, 1)
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
        let kept = queue.entries
        XCTAssertFalse(try session.completePresentation(queue: queue))
        XCTAssertEqual(queue.entries, kept, "An interrupted custom job must remain reviewable")
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
        let kept = queue.entries
        XCTAssertFalse(try session.completePresentation(queue: queue))
        XCTAssertEqual(queue.entries, kept, "Uncertain custom labels are never auto-cleared")
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

    func testAcceptedUploadCannotAdvanceConfirmedPrintedCountOrDismissProgress() async throws {
        let queue = try queue(entries(3)), sender = ProgressGatedSender(holdsPhysicalProof: true)
        let session = LabelPrintProgressSession()
        session.start(queue: queue, using: sender)
        for _ in 0..<100 where !sender.isWaitingForPhysicalProof { await Task.yield() }
        XCTAssertTrue(sender.isWaitingForPhysicalProof)
        XCTAssertEqual(sender.uploadProgress?.fraction, 1)
        XCTAssertEqual(session.total, 3)
        XCTAssertEqual(session.completed(in: queue.entries), 0)
        XCTAssertTrue(queue.entries.allSatisfy { $0.state == .sending })
        XCTAssertTrue(session.isPresented)
        XCTAssertFalse(session.didSucceed)
        sender.confirmPhysicalCopies()
        await waitForFinalAcknowledgement(sender)
        XCTAssertEqual(session.completed(in: queue.entries), 3)
        XCTAssertNil(sender.uploadProgress)
        XCTAssertTrue(session.isPresented, "Physical confirmation still waits for final job acknowledgement")
        XCTAssertFalse(session.didSucceed)
        sender.finish()
        await session.waitUntilFinished()
        XCTAssertTrue(session.didSucceed)
        XCTAssertFalse(session.isPresented)
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
    var failsWrites = false
    init(bytes: Data?) { self.bytes = bytes }
}
private enum ProgressStorageFailure: Error { case injected }

@MainActor private final class ProgressImmediateSender: LabelPrinterSending {
    var sends = 0
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { sends += 1; return .completed }
    func cancelPrinting() {}
}

@MainActor private final class ProgressGatedSender: LabelContinuousPrinterSending {
    let failsBeforeProof: Bool
    let finalOutcome: LabelSendOutcome
    let holdsPhysicalProof: Bool
    var cancels = 0
    private(set) var uploadProgress: NiimbotUploadProgress?
    private var continuation: CheckedContinuation<Void, Never>?
    private var proofContinuation: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { continuation != nil }
    var isWaitingForPhysicalProof: Bool { proofContinuation != nil }
    init(failsBeforeProof: Bool = false, finalOutcome: LabelSendOutcome = .completed, holdsPhysicalProof: Bool = false) {
        self.failsBeforeProof = failsBeforeProof
        self.finalOutcome = finalOutcome
        self.holdsPhysicalProof = holdsPhysicalProof
    }
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { .notSent(.unsupportedResponse) }
    func cancelPrinting() {
        cancels += 1
        let waiting = proofContinuation; proofContinuation = nil
        waiting?.resume(returning: false)
    }
    func confirmPhysicalCopies() {
        let waiting = proofContinuation; proofContinuation = nil
        waiting?.resume(returning: true)
    }
    func finish() { let waiting = continuation; continuation = nil; waiting?.resume() }

    func printContinuously(_ rasters: [LabelRaster],
                           beforePages: @escaping @MainActor ([Int]) async throws -> Void,
                           afterPages: @escaping @MainActor ([Int]) async throws -> Void) async -> LabelSendOutcome {
        do {
            let pages = Array(rasters.indices)
            try await beforePages(pages)
            if holdsPhysicalProof {
                uploadProgress = NiimbotUploadProgress(pages: 0..<rasters.count, completedRequests: 4, totalRequests: 4)
                let confirmed = await withCheckedContinuation { proofContinuation = $0 }
                uploadProgress = nil
                guard confirmed, !Task.isCancelled else { return .uncertain(.cancelled) }
            }
            if failsBeforeProof { return .uncertain(.writeFailed) }
            try await afterPages(pages)
            await withCheckedContinuation { continuation = $0 }
            return finalOutcome
        } catch { return .notSent(.writeFailed) }
    }
}
