import SwiftUI

/// Existing PSA/deep links enter the Graded mode of the combined page.
struct ResearchView: View {
    let card: CardCandidate
    let grader: String
    let grade: String
    private let provider: any ResearchProviding
    init(card: CardCandidate, grader: String = "RAW", grade: String = "Raw",
         provider: any ResearchProviding = ConfiguredResearchProvider()) {
        self.card = card; self.grader = grader; self.grade = grade; self.provider = provider
    }
    var body: some View {
        CardResearchView(card: card, initialSection: .graded, grader: grader, grade: grade, research: provider)
    }
}

/// Numeric research sections; charts remain deferred and selections are local.
struct GradedResearchContent: View {
    @Bindable var model: ResearchModel
    var body: some View {
        Section("Grade") {
            if model.loading { ProgressView("Loading research…").accessibilityIdentifier("research.status") }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("research.status")
                Button("Retry Research") { model.refresh() }.disabled(model.loading).accessibilityIdentifier("research.retry")
            }
            if model.details != nil {
                Picker("Grader / grade", selection: Binding(get: { selectedGrade }, set: {
                    model.selectGrade(grader: $0.grader, grade: $0.grade)
                })) {
                    if !choices.contains(selectedGrade) {
                        Text(selectedGrade.grade.isEmpty ? "Choose grade" : selectedGrade.label + " • unavailable").tag(selectedGrade)
                    }
                    ForEach(choices) { choice in Text(choice.label).tag(choice) }
                }.pickerStyle(.menu).disabled(model.selectedVariant == nil).accessibilityIdentifier("research.grade")
                if let message = model.selectionMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("research.selectionStatus")
                }
                if model.selectedGrader == "RAW" {
                    Text("Raw research combines conditions.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let grade = model.selectedGrade {
            Section("Valuation") {
                LabeledContent("Guide estimate", value: money(grade.guideValue)).accessibilityIdentifier("research.guideEstimate")
                LabeledContent("Research market value", value: money(grade.marketValue)).accessibilityIdentifier("research.marketValue")
                if grade.grader != "RAW" {
                    LabeledContent("Population at this grade", value: count(grade.population)).accessibilityIdentifier("research.population")
                }
            }
            Section("Past 30 days") {
                LabeledContent("Recorded sales", value: count(grade.dailyHistory?.stats?.month?.sales)).accessibilityIdentifier("research.sales30d")
                LabeledContent("Sold average", value: money(grade.dailyHistory?.stats?.month?.average)).accessibilityIdentifier("research.average30d")
                DisclosureGroup("More research") {
                    LabeledContent("Recorded low", value: money(grade.dailyHistory?.stats?.month?.low))
                    LabeledContent("Recorded high", value: money(grade.dailyHistory?.stats?.month?.high))
                    LabeledContent("Total historical sales", value: count(grade.sales))
                    LabeledContent("Provider rating", value: grade.confidence.map { "\($0) of 5" } ?? "Unavailable")
                    LabeledContent("Latest sale price", value: money(grade.dailyHistory?.stats?.lastSale?.price))
                    if let date = grade.dailyHistory?.stats?.lastSale?.date ?? grade.lastSoldAt {
                        LabeledContent("Latest recorded sale", value: date)
                    }
                }
            }
        }
    }
    private var selectedGrade: ResearchGradeChoice { .init(grader: model.selectedGrader, grade: model.selectedGradeLabel) }
    private var choices: [ResearchGradeChoice] {
        Array(Set(model.availableGrades.map { ResearchGradeChoice(grader: $0.grader, grade: $0.grade) })).sorted {
            $0.grader == $1.grader ? $0.grade.localizedStandardCompare($1.grade) == .orderedAscending : $0.grader < $1.grader
        }
    }
    private func money(_ value: Decimal?) -> String { value?.money ?? "Unavailable" }
    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Unavailable" }
}

private struct ResearchGradeChoice: Hashable, Identifiable {
    let grader: String
    let grade: String
    var id: Self { self }
    var label: String { grader == "RAW" && grade == "Raw" ? "Raw (ungraded)" : grader + " " + grade }
}
