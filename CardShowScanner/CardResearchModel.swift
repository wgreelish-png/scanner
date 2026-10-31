import Foundation
import Observation

enum CardResearchSection: String, CaseIterable, Identifiable {
    case market, graded
    var id: Self { self }
    var title: String { self == .market ? "Market" : "Graded" }
}

/// A read-only card copy coordinates two independently cached services. Only
/// the visible mode loads; changing research selections never edits inventory.
@MainActor @Observable final class CardResearchModel {
    private(set) var card: CardCandidate
    private(set) var section: CardResearchSection
    let market: MarketInsightsModel
    let graded: ResearchModel
    var marketWindow = 30
    private var visible = false
    private var marketAttempted = false
    private var gradedAttempted = false

    init(card: CardCandidate, initialSection: CardResearchSection = .market,
         grader: String = "PSA", grade: String = "",
         publicPricing: any MarketPricing = StandardMarketPricing(),
         opportunities: any OpportunitiesProviding = ConfiguredOpportunitiesProvider(),
         research: any ResearchProviding = ConfiguredResearchProvider()) {
        self.card = card; section = initialSection
        market = MarketInsightsModel(card: card, publicPricing: publicPricing, opportunities: opportunities)
        graded = ResearchModel(card: card, provider: research, grader: grader, grade: grade)
    }

    var printings: [String] {
        let returned = graded.variantKeys.compactMap { graded.details?.product.variants[$0]?.finish }
        return Array(Set(card.printings + [card.identity.printing] + (market.publicDetails?.printings ?? []) + returned)).sorted()
    }
    var languages: [String] {
        let returned = graded.variantKeys.compactMap { graded.details?.product.variants[$0]?.language }
            .map(Self.languageName)
        return Array(Set([card.identity.language, "English", "Japanese", "French", "German", "Italian", "Spanish",
                          "Portuguese", "Russian", "Korean", "Simplified Chinese", "Traditional Chinese"] + returned)).sorted()
    }

    func start() {
        guard !visible else { return }
        visible = true; loadActiveIfNeeded()
    }
    func stop() {
        visible = false; retireMarket(); retireGraded()
    }
    func selectSection(_ section: CardResearchSection) {
        guard self.section != section else { return }
        if self.section == .market { retireMarket() } else { retireGraded() }
        self.section = section
        if visible { loadActiveIfNeeded() }
        DiagnosticLog.shared.record("card_research.mode_changed", ["phase": section.rawValue])
    }
    func selectCondition(_ condition: String) {
        guard CatalogOptions.conditions.contains(condition), condition != card.identity.condition else { return }
        var draft = card; draft.identity.condition = condition; changeCard(draft)
    }
    func selectPrinting(_ printing: String) {
        guard printings.contains(printing), printing != card.identity.printing || card.requiresPrintingSelection == true else { return }
        var draft = card; draft.printings = printings; draft.identity.printing = printing
        draft.requiresPrintingSelection = false; changeCard(draft)
    }
    func selectLanguage(_ language: String) {
        guard languages.contains(language), language != card.identity.language else { return }
        var draft = card; draft.identity.language = language; changeCard(draft)
    }
    func changeCard(_ card: CardCandidate) {
        var draft = card
        draft.identity.skuID = nil; draft.marketPrice = nil; draft.marketPriceMetadata = nil
        self.card = draft
        market.changeCard(draft, refresh: false); graded.changeCard(draft, refresh: false)
        marketAttempted = false; gradedAttempted = false
        if visible { loadActiveIfNeeded() }
    }
    func refresh() {
        guard visible else { return }
        if section == .market { marketAttempted = true; market.refresh() }
        else { gradedAttempted = true; graded.refresh() }
    }

    /// Connection changes can alter Beta account identity and entitlement.
    /// Invalidate both modes, but reload only the visible mode using normal caches.
    func connectionDidChange() {
        market.changeCard(card, refresh: false); graded.changeCard(card, refresh: false)
        marketAttempted = false; gradedAttempted = false
        if visible { loadActiveIfNeeded() }
    }

    private func loadActiveIfNeeded() {
        switch section {
        case .market:
            guard !marketAttempted else { return }
            marketAttempted = true; market.refresh(forceRefresh: false)
        case .graded:
            guard !gradedAttempted else { return }
            gradedAttempted = true; graded.refresh(forceRefresh: false)
        }
    }
    private func retireMarket() {
        if market.publicLoading || market.activityLoading { marketAttempted = false }
        market.cancel()
    }
    private func retireGraded() {
        if graded.loading { gradedAttempted = false }
        graded.cancel()
    }
    private static func languageName(_ code: String) -> String {
        ["EN": "English", "JP": "Japanese", "FR": "French", "DE": "German", "IT": "Italian", "ES": "Spanish",
         "PT": "Portuguese", "RU": "Russian", "KO": "Korean", "CS": "Simplified Chinese", "CT": "Traditional Chinese"][code] ?? code
    }
}
