import SwiftUI

struct ScannerCaptureModeSelector: View {
    @Binding var selection: ScannerCaptureMode
    var blocked = false
    var body: some View {
        Picker("Scan Mode", selection: $selection) {
            Text("Live Scan").tag(ScannerCaptureMode.live)
            Text("Photo Scan").tag(ScannerCaptureMode.photo)
        }.disabled(blocked).accessibilityIdentifier("photoScan.modePicker")
    }
}

struct ScannerCaptureModeMenu: View {
    @ObservedObject var provider: TCGTrackingScannerProvider
    @Binding var selection: ScannerCaptureMode
    var blocked: Bool
    var body: some View {
        ScannerCaptureModeSelector(selection: $selection, blocked: blocked || provider.photoState == .processing)
    }
}

struct ScannerPhotoCaptureControls: View {
    @ObservedObject var provider: TCGTrackingScannerProvider
    let enabled: Bool
    let onRetry: () -> Void
    var body: some View {
        PhotoScanActionPanel(state: provider.photoState, enabled: enabled,
            canCapture: provider.canCapturePhoto, canRetake: provider.canRetakePhoto,
            onCapture: provider.capturePhoto, onRetake: provider.retakePhoto, onRetry: onRetry)
    }
}

/// Presentation is shared with a synthetic UI fixture; camera/recognition state
/// and command availability come from the nonce-fenced provider in production.
struct PhotoScanActionPanel: View {
    let state: PhotoScanState
    let enabled: Bool
    let canCapture: Bool
    let canRetake: Bool
    let onCapture: () -> Void
    let onRetake: () -> Void
    var onRetry: (() -> Void)? = nil

    private var isRetake: Bool { state == .ready || state == .noMatch || state == .failed }
    private var needsRetry: Bool { state == .failed && !canRetake && onRetry != nil }
    private var message: String {
        switch state {
        case .off: return "Preparing Photo Scan…"
        case .framing: return "Frame one card, then take a photo."
        case .processing: return "Scanning photo · Camera is off"
        case .ready: return "Photo scanned · Camera is off"
        case .noMatch: return "No confident match. Retake or search manually."
        case .failed: return "Photo scan interrupted. Retake or search manually."
        case .cooling: return "Camera paused while your iPhone cools."
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            Text(message).font(.caption).multilineTextAlignment(.center)
                .accessibilityIdentifier("photoScan.status")
            if state == .processing {
                ProgressView().tint(.white).accessibilityLabel("Scanning photo")
                    .accessibilityIdentifier("photoScan.processing")
            } else {
                Button(action: needsRetry ? (onRetry ?? {}) : isRetake ? onRetake : onCapture) {
                    Label(needsRetry ? "Retry Scanner" : isRetake ? "Take Another Photo" : "Take Photo", systemImage: isRetake ? "camera.rotate" : "camera.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                    .disabled(!enabled || (!needsRetry && (isRetake ? !canRetake : !canCapture)))
                    .accessibilityIdentifier(needsRetry ? "photoScan.retry" : isRetake ? "photoScan.retake" : "photoScan.capture")
            }
        }
    }
}

#if DEBUG
@MainActor struct PhotoScanFixtureScreen: View {
    @AppStorage private var mode: ScannerCaptureMode
    @State private var state = PhotoScanState.framing
    init() {
        let args = ProcessInfo.processInfo.arguments
        let id = args.first(where: { $0.hasPrefix("--photo-fixture-id=") }) ?? "--photo-fixture-id=default"
        let suite = "PhotoScanFixture." + id
        let defaults = UserDefaults(suiteName: suite)!
        if args.contains("--photo-fixture-reset") { defaults.removePersistentDomain(forName: suite) }
        _mode = AppStorage(wrappedValue: .live, "scannerCaptureMode", store: defaults)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ScannerCaptureModeSelector(selection: $mode, blocked: state == .processing).pickerStyle(.segmented)
                if mode == .photo {
                    PhotoScanActionPanel(state: state, enabled: true,
                        canCapture: state == .framing, canRetake: state == .ready,
                        onCapture: {
                            state = .processing
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(200))
                                state = .ready
                            }
                        }, onRetake: { state = .framing })
                }
                Spacer()
            }.padding().navigationTitle("Photo Scan Fixture")
                .onChange(of: mode) { _, _ in state = .framing }
        }
    }
}
#endif
