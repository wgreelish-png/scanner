import Foundation

/// Stock identity is resolved before the queue writes any sending markers.
/// A printer without RFID keeps the existing explicit manual-paper workflow.
@MainActor protocol LabelStockValidating {
    func queuedPaperIssue(_ papers: [InventoryLabelSize]) async -> String?
}

enum LabelStockCompatibility {
    static func issue(for papers: [InventoryLabelSize], detected: NiimbotLabelProduct?) -> String? {
        guard !papers.isEmpty else { return nil }
        guard let detected else {
            return papers.contains(where: { $0.product != nil })
                ? "Refresh the roll or reconnect to verify the paper for these saved labels."
                : nil
        }
        guard let loaded = try? InventoryLabelSize(product: detected) else {
            return "The detected roll measurements could not be used. Check the loaded paper."
        }
        guard papers.allSatisfy({ paper in
            paper.product?.paperType == detected.paperType && paper.geometry == loaded.geometry
        }) else {
            return "These labels were prepared for a different paper layout. Clear the queue and prepare labels for the detected \(loaded.title) roll."
        }
        return nil
    }
}
