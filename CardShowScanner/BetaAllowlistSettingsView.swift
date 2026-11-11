import SwiftUI

/// Reuses the existing website sign-in and its persistent WebKit session.
struct BetaAllowlistSettingsSection: View {
    @ObservedObject private var sync = BetaIPAllowlistSync.shared
    @State private var signingIn = false

    var body: some View {
        Section {
            Toggle("Keep This iPhone Connected", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                .accessibilityIdentifier("betaAllowlist.enabled")
            Text(sync.status).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("betaAllowlist.status")
            if let ip = sync.lastIP {
                LabeledContent("Confirmed public IP", value: ip)
                    .font(.footnote).textSelection(.enabled).accessibilityIdentifier("betaAllowlist.ip")
            }
            if let date = sync.lastCheckedAt {
                LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).accessibilityIdentifier("betaAllowlist.lastChecked")
            }
            if sync.busy { ProgressView("Updating IP access…") }
            Button("Check IP Now") { sync.checkNow() }
                .disabled(!sync.enabled || sync.busy || sync.isCoolingPaused).accessibilityIdentifier("betaAllowlist.check")
            if sync.needsSignIn {
                Button("Sign In to Update IP Access") { signingIn = true }
                    .accessibilityIdentifier("betaAllowlist.signIn")
            }
        } header: { Text("Automatic Beta IP access") } footer: {
            Text("While active and signed in, checks run on launch, when you return, after network changes, and once a minute. Sign-in failures pause automatic checks until sign-in changes or you tap Check IP Now. Website checks also pause while this iPhone cools and stop when you leave the app. It replaces only this iPhone’s recorded previous IP and preserves the account’s other addresses. Requires website sign-in for the same Shipper ID.")
        }
        .fullScreenCover(isPresented: $signingIn) {
            TCGTrackingConnectionView(continueTitle: "Done") {
                signingIn = false
            }
        }
    }
}
