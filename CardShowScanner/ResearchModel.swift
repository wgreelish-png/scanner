import Foundation
import Observation

/// Read-only enrichment. Neither the selected guide estimate nor a change of
/// grader/grade writes a price, condition, offer or inventory row.
@MainActor @Observable final class ResearchModel {
    private(set) var card: CardCandidate
    private(set) var details: ResearchProductDetails?
    private(set) var selectedVariantKey: String?
    private(set) var selectedGrader: String
    private(set) var selectedGradeLabel: String
    private(set) var loading = false
    private(set) var message: String?
    private let provider: any ResearchProviding
    private var lookup: Task<Void, Never>?
    private var requestID = UUID()

    init(card: CardCandidate, provider: any ResearchProviding, grader: String = "RAW", grade: String = "Raw") {
        self.card = card; self.provider = provider; selectedGrader = grader; selectedGradeLabel = grade
    }

    var variantKeys: [String] {
        (details?.product.variants ?? [:]).filter { $0.key == $0.value.key }.keys.sorted()
    }
    var selectedVariant: ResearchVariant? {
        guard let key = selectedVariantKey, let variant = details?.product.variants[key], key == variant.key else { return nil }
        return variant
    }
    var availableGrades: [ResearchGrade] {
        var seen: Set<String> = []
        return (selectedVariant?.grades ?? []).filter { seen.insert($0.id).inserted }
    }
    var selectedGrade: ResearchGrade? {
        let matches = (selectedVariant?.grades ?? []).filter { $0.grader == selectedGrader && $0.grade == selectedGradeLabel }
        return matches.count == 1 ? matches[0] : nil
    }
    var selectionMessage: String? {
        guard details != nil else { return nil }
        guard selectedVariant != nil else { return "No research matches this exact printing and language. Select a returned variant if appropriate." }
        guard !selectedGradeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Choose an available research grade." }
        guard selectedGrade != nil else { return "Research is unavailable or ambiguous for \(selectedGrader) \(selectedGradeLabel). No other grade is substituted." }
        return nil
    }

    func refresh(forceRefresh: Bool = true) {
        cancel(); details = nil; message = nil; loading = true
        let requested = card, request = requestID
        lookup = Task { [weak self, provider] in
            do {
                let result = try await provider.research(for: requested, forceRefresh: forceRefresh)
                guard let self, !Task.isCancelled, self.requestID == request else { return }
                self.details = result
                if let key = self.selectedVariantKey, result.product.variants[key]?.key == key {
                    // Preserve an explicit valid variant choice on refresh.
                } else { self.selectedVariantKey = Self.matchingVariant(in: result, for: requested.identity) }
                self.loading = false
            } catch {
                guard let self, !Task.isCancelled, self.requestID == request else { return }
                self.loading = false
                self.message = (error as? ResearchFailure)?.errorDescription ?? ResearchFailure.networkUnavailable.errorDescription
            }
        }
    }
    func changeCard(_ card: CardCandidate) {
        cancel(); self.card = card; selectedVariantKey = nil; details = nil
        refresh(forceRefresh: false)
    }
    func selectVariant(_ key: String) { selectedVariantKey = key }
    func selectGrade(grader: String, grade: String) { selectedGrader = grader; selectedGradeLabel = grade }
    func cancel() { lookup?.cancel(); lookup = nil; requestID = UUID(); loading = false }

    private static func matchingVariant(in details: ResearchProductDetails, for identity: CardIdentity) -> String? {
        let languages = ["English": "EN", "Japanese": "JP", "French": "FR", "German": "DE", "Italian": "IT", "Spanish": "ES",
                         "Portuguese": "PT", "Russian": "RU", "Korean": "KO", "Simplified Chinese": "CS", "Traditional Chinese": "CT"]
        let input = identity.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = languages.first { $0.key.caseInsensitiveCompare(input) == .orderedSame }?.value
            ?? (Set(languages.values).contains(input.uppercased()) ? input.uppercased() : nil)
        guard let language else { return nil }
        let matches = details.product.variants.filter { key, variant in
            key == variant.key && variant.language == language && normalized(variant.finish) == normalized(identity.printing)
        }
        return matches.count == 1 ? matches.first?.key : nil
    }
    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
