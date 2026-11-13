import SwiftUI

/// One size summary for first downloads and explicit database refreshes. The
/// scrolling details never move the action buttons off the screen.
struct ScannerDownloadPreviewContent: View {
    let game: String
    let preview: ScannerDownloadPreview?
    let isLoading: Bool
    let errorMessage: String?
    let continueTitle: String
    let onContinue: () -> Void
    let onCancel: () -> Void
    var onRetry: (() -> Void)? = nil
    var showsCancel = true
    var requiresSpaceForContinue = true

    private var insufficientSpace: Bool {
        guard let preview, let available = preview.availableStorageBytes else { return false }
        return available < preview.minimumAdditionalStorageBytes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Download size").font(.title2.bold())
                        .accessibilityIdentifier("downloadPreview.title")
                    Text(game).font(.headline)
                    Text("Scanner recognition database")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if isLoading {
                    ProgressView("Checking download size…")
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .accessibilityIdentifier("downloadPreview.loading")
                } else if let preview {
                    sizeSummary(preview)
                } else {
                    unavailableSummary
                }
                Text("This covers recognition data only. Card artwork, market prices and research data are separate.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("downloadPreview.scope")
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("downloadPreview.screen")
    }

    private func sizeSummary(_ preview: ScannerDownloadPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 16) {
                LabeledContent("Download size", value: Self.bytes(preview.downloadBytes))
                    .accessibilityIdentifier("downloadPreview.downloadBytes")
                Divider()
                LabeledContent("Additional storage", value: storageLabel(preview))
                    .accessibilityIdentifier("downloadPreview.additionalStorage")
                Divider()
                LabeledContent("Already saved", value: Self.bytes(preview.cachedBytes))
                    .accessibilityIdentifier("downloadPreview.cachedBytes")
                if let available = preview.availableStorageBytes {
                    Divider()
                    LabeledContent("Free on iPhone", value: Self.bytes(available))
                        .accessibilityIdentifier("downloadPreview.freeStorage")
                }
            }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 16))
            if preview.downloadBytes == 0 {
                Text("The recognition files in this estimate are already saved.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("downloadPreview.alreadySaved")
            }
            if !preview.additionalStorageIsExact {
                Text("Additional storage is a minimum. Metadata expands when saved, and its full size is not published, so the final storage use can be larger.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("downloadPreview.storageExplanation")
            }
            if preview.isUsingCachedMetadata {
                Text("Using saved size information. The download may differ if the database has changed.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("downloadPreview.cachedEstimate")
            }
            if insufficientSpace {
                Text("Free up space before downloading. The known portion alone exceeds the free storage on this iPhone.")
                    .font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("downloadPreview.insufficientSpace")
            }
        }
    }

    private var unavailableSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Size unavailable", systemImage: "questionmark.circle")
                .font(.headline)
            Text(errorMessage ?? "The size estimate could not be loaded. No recognition files were downloaded by this check.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let onRetry {
                Button("Retry Size Check", systemImage: "arrow.clockwise", action: onRetry)
                    .accessibilityIdentifier("downloadPreview.retry")
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("downloadPreview.unavailable")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if showsCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("downloadPreview.cancel")
            }
            Button(continueTitle, action: onContinue)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isLoading || (requiresSpaceForContinue && insufficientSpace))
                .accessibilityIdentifier("downloadPreview.continue")
        }.controlSize(.large).padding(16).background(.regularMaterial)
    }

    private func storageLabel(_ preview: ScannerDownloadPreview) -> String {
        let amount = Self.bytes(preview.minimumAdditionalStorageBytes)
        return preview.additionalStorageIsExact ? amount : "At least " + amount
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}

/// The provider owns cancellation and approval. This opaque surface prevents
/// camera controls underneath the review from receiving accidental taps.
struct ScannerDownloadPreviewOverlay: View {
    @ObservedObject var provider: TCGTrackingScannerProvider
    let game: String
    let onCancelInitial: () -> Void

    @ViewBuilder var body: some View {
        switch provider.downloadPreviewState {
        case .idle:
            EmptyView()
        case .checking:
            review(preview: nil, isLoading: true)
        case .ready(let preview, _):
            review(preview: preview, isLoading: false)
        case .unavailable:
            review(preview: nil, isLoading: false)
        }
    }

    private func review(preview: ScannerDownloadPreview?, isLoading: Bool) -> some View {
        ScannerDownloadPreviewContent(game: game, preview: preview, isLoading: isLoading,
            errorMessage: nil, continueTitle: preview == nil && !isLoading ? "Continue Without Estimate" : "Download & Continue",
            onContinue: {
                if preview == nil { provider.continueWithoutDownloadEstimate() }
                else { provider.approveDownloadPreview() }
            }, onCancel: {
                let wasInitial = provider.downloadPreviewState.action == .initialLoad
                provider.cancelDownloadPreview()
                if wasInitial { onCancelInitial() }
            }, onRetry: provider.retryDownloadPreview)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .contentShape(Rectangle())
    }
}

/// Settings may preview a first download, but the scanner still owns that
/// download. An existing database refresh starts only after this review closes.
struct ScannerDatabaseDownloadReviewSheet: View {
    let game: String
    let refreshRequested: Bool
    let onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: ScannerDownloadPreview?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var canRefresh = false
    @State private var requestID = UUID()

    private var continueTitle: String {
        if refreshRequested, canRefresh {
            return errorMessage == nil ? "Refresh Database" : "Refresh Without Estimate"
        }
        return "Done"
    }

    var body: some View {
        ScannerDownloadPreviewContent(game: game, preview: preview, isLoading: isLoading,
            errorMessage: errorMessage, continueTitle: continueTitle,
            onContinue: {
                guard scenePhase == .active, !isLoading else { return }
                if refreshRequested && canRefresh { onRefresh() }
                dismiss()
            }, onCancel: { dismiss() }, onRetry: { requestID = UUID() },
            showsCancel: refreshRequested && canRefresh,
            requiresSpaceForContinue: refreshRequested && canRefresh)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isLoading, !canRefresh {
                Text("Start a scan to download this game's database.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .accessibilityIdentifier("downloadPreview.startScan")
            }
        }
        .task(id: requestID) { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dismiss() }
        }
    }

    private func load() async {
        isLoading = true; errorMessage = nil; preview = nil
        do {
            canRefresh = try await ScannerDatabaseCache.shared.hasUpdateableManifest(
                gameKey: TCGGameRegistry.scannerKey(for: game) ?? "")
            let result = try await ScannerDownloadPreviewService.shared.preview(game: game)
            try Task.checkCancellation()
            guard scenePhase == .active else { return }
            preview = result; isLoading = false
        } catch {
            guard !Task.isCancelled, scenePhase == .active else { return }
            errorMessage = "The size estimate could not be loaded. No recognition files were downloaded by this check."
            isLoading = false
        }
    }
}

#if DEBUG
/// Synthetic values exercise the review without fetching metadata, starting a
/// camera or writing to the application's downloaded database cache.
@MainActor struct ScannerDownloadPreviewFixtureScreen: View {
    @State private var outcome: String?
    private let unavailable = ProcessInfo.processInfo.arguments.contains("--uitest-download-preview-unavailable")

    private var fixture: ScannerDownloadPreview {
        ScannerDownloadPreview(gameKey: "tcgp:3", downloadBytes: 12_000_000, cachedBytes: 8_000_000,
            minimumAdditionalStorageBytes: 10_000_000, additionalStorageIsExact: false,
            missingFiles: 10, totalFiles: 20, isUsingCachedMetadata: true, availableStorageBytes: 4_000_000_000)
    }

    var body: some View {
        if let outcome {
            Text(outcome).accessibilityIdentifier("downloadPreview.fixtureOutcome")
        } else {
            ScannerDownloadPreviewContent(game: "Pokémon", preview: unavailable ? nil : fixture,
                isLoading: false, errorMessage: nil,
                continueTitle: unavailable ? "Continue Without Estimate" : "Download & Continue",
                onContinue: { outcome = "Download approved" }, onCancel: { outcome = "Download cancelled" })
        }
    }
}
#endif
