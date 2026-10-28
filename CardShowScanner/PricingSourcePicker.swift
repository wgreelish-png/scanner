import SwiftUI

/// One persisted choice is shared by scanning, manual additions and inventory
/// edits. Choosing a source is explicit; lookups never switch providers silently.
struct PricingSourcePicker: View {
    let accessibilityID: String
    @AppStorage(PricingSource.defaultsKey) private var source = PricingSource.tcgTracking.rawValue
    init(accessibilityID: String = "pricing.source") { self.accessibilityID = accessibilityID }
    var body: some View {
        Picker("Price source", selection: Binding(get: {
            (PricingSource(rawValue: source) ?? .tcgTracking).rawValue
        }, set: {
            source = $0
            DiagnosticLog.shared.record("pricing.source_changed", ["source": $0])
        })) {
            ForEach(PricingSource.allCases) { source in
                Text(source.title).tag(source.rawValue)
            }
        }.pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier(accessibilityID)
            .accessibilityValue((PricingSource(rawValue: source) ?? .tcgTracking).title)
    }
}
