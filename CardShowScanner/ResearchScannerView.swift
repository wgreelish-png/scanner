import SwiftUI

/// Reuses live recognition for an explicit research lookup, without a saved batch.
struct ResearchScannerView: View {
    let game: String
    let onChoose: (CardCandidate?) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model = ResearchScanModel()
    @State private var visible = false
    @State private var completed = false

    var body: some View {
        Group {
            if model.result != nil { matches }
            else { camera }
        }
        .onAppear {
            visible = true
            startIfReady()
        }
        .onDisappear {
            visible = false
            model.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfReady() }
            else if phase == .background { model.stop() }
        }
        .overlay {
            if let provider = model.liveProvider {
                ScannerDownloadPreviewOverlay(provider: provider, game: game) { finish(nil) }
            }
        }
    }

    private var camera: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let provider = model.liveProvider {
                TCGScannerWebView(provider: provider).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan for Research").font(.headline)
                        Text(game).font(.caption)
                    }
                    Spacer(minLength: 8)
                    Button { finish(nil) } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close research scanner")
                    .accessibilityIdentifier("researchScanner.close")
                }
                .padding(12).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    Text("Hold one card steady, then choose its match.").font(.subheadline)
                    if let provider = model.liveProvider {
                        ResearchCameraStatus(provider: provider)
                    }
                    if let error = model.error {
                        Text(error).font(.caption)
                    }
                    HStack(spacing: 20) {
                        Button("Use Text Search", systemImage: "magnifyingglass") { finish(nil) }
                            .accessibilityIdentifier("researchScanner.useText")
                        Spacer(minLength: 0)
                        Button("Retry", systemImage: "arrow.clockwise", action: retry)
                            .accessibilityLabel("Retry Live Scanner")
                            .accessibilityIdentifier("researchScanner.retry")
                    }.font(.subheadline.weight(.semibold))
                }
                .padding(16).frame(maxWidth: .infinity)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 16).padding(.vertical, 8).foregroundStyle(.white)
        }
        .accessibilityIdentifier("researchScanner.camera")
    }

    private var matches: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the correct card to open its research.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 14) {
                    ForEach(model.candidates) { card in
                        Button {
                            guard let selection = model.choose(card) else { return }
                            finish(selection)
                        } label: { ResearchSearchTile(card: card) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("researchScanner.match." + card.identity.productID)
                    }
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Possible Matches").font(.title2.bold())
                Spacer(minLength: 8)
                Button { finish(nil) } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Close research scanner")
                    .accessibilityIdentifier("researchScanner.close")
            }.padding(.horizontal, 20).background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                Button("Use Text Search") { finish(nil) }
                    .accessibilityIdentifier("researchScanner.useText")
                Spacer(minLength: 0)
                Button("Scan Again", systemImage: "camera", action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("researchScanner.scanAgain")
            }.padding(16).background(.regularMaterial)
        }
        .accessibilityIdentifier("researchScanner.matches")
    }

    private func startIfReady() {
        guard visible, scenePhase == .active, !completed else { return }
        model.start(game: game)
    }

    private func retry() {
        guard visible, scenePhase == .active, !completed else { return }
        model.scanAgain()
    }

    private func finish(_ card: CardCandidate?) {
        guard !completed else { return }
        completed = true
        model.stop()
        onChoose(card)
    }
}

private struct ResearchCameraStatus: View {
    @ObservedObject var provider: TCGTrackingScannerProvider
    var body: some View {
        VStack(spacing: 10) {
            CameraStatusView(provider: provider)
            if provider.manualSearchSuggested {
                Text("No match yet. Try text search or keep scanning.").font(.caption)
                Button("Keep Scanning") { provider.resumeAfterManualSearchPrompt() }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}
