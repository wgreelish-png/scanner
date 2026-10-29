import SwiftUI
import UIKit
@preconcurrency import AVFoundation

/// Independent native barcode capture. It never starts the card-recognition
/// engine, downloads a card database, opens a barcode URL or saves inventory.
@MainActor struct PSABarcodeScannerView: View {
    let onRead: (PSACertificateCode) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PSABarcodeCaptureModel()
    @State private var manualNumber = ""
    @State private var manualError: String?
    @State private var pausedAfterBackground = false
    @State private var returning = false
    @FocusState private var enteringNumber: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                PSABarcodePreview(engine: model.engine).ignoresSafeArea()
                Color.black.opacity(0.12).ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: 16) {
                    Text(model.candidate == nil ? "Point at the PSA label’s barcode or QR code." : "Certification code captured")
                        .font(.headline).multilineTextAlignment(.center).padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    Spacer()
                    if let code = model.candidate { confirmation(code) }
                    else { captureControls }
                }.padding()
            }
            .navigationTitle("Scan PSA Certification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.pause(); dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { enteringNumber = false }
                }
            }
            .task { if scenePhase == .active { model.start() } }
            .onDisappear { model.pause() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    pausedAfterBackground = true
                    model.pause()
                } else if !pausedAfterBackground && !enteringNumber && model.candidate == nil {
                    model.start()
                }
            }
            .onChange(of: enteringNumber) { _, focused in
                if focused { model.pause() }
                else if scenePhase == .active && !pausedAfterBackground && model.candidate == nil { model.start() }
            }
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = model.message { Text(message).font(.subheadline) }
            if pausedAfterBackground {
                Button("Resume Camera") {
                    guard scenePhase == .active else { return }
                    enteringNumber = false; pausedAfterBackground = false
                    model.start()
                }.buttonStyle(.borderedProminent)
            } else if model.message != nil {
                Button("Retry Camera") {
                    guard scenePhase == .active else { return }
                    enteringNumber = false; model.retry()
                }.buttonStyle(.bordered)
            }
            TextField("Or enter the certification number", text: $manualNumber)
                .keyboardType(.numberPad).textContentType(.none)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($enteringNumber).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("psa.manualNumber")
            if let manualError { Text(manualError).font(.caption).foregroundStyle(.orange) }
            Button("Confirm Number") {
                guard let code = PSACertificateCode.parse(manualNumber, kind: .manual) else {
                    manualError = "Enter the numeric certification number printed on the PSA label."
                    return
                }
                manualError = nil; enteringNumber = false; model.acceptManual(code)
            }.buttonStyle(.borderedProminent).disabled(manualNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("psa.confirmManual")
            Text("The code identifies a possible certification record. It does not authenticate the slab or identify the catalog card by itself.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func confirmation(_ code: PSACertificateCode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify the printed number").font(.headline)
            Text(code.certificateNumber).font(.largeTitle.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                .textSelection(.enabled).accessibilityLabel("Certification number")
                .accessibilityValue(code.certificateNumber.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("psa.capturedNumber")
            Text("Compare this number with the PSA label before looking up the certification. You will still confirm the card match and grade.")
                .font(.subheadline)
            Button("Use This Certification") {
                guard !returning else { return }
                returning = true; model.pause(); onRead(code)
            }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                .disabled(returning)
                .accessibilityIdentifier("psa.useCertificate")
            Button("Scan Again") {
                guard scenePhase == .active else { return }
                manualNumber = ""; pausedAfterBackground = false; model.scanAgain()
            }.buttonStyle(.bordered)
                .disabled(returning)
                .accessibilityIdentifier("psa.scanAgain")
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor private final class PSABarcodeCaptureModel: ObservableObject {
    @Published private(set) var candidate: PSACertificateCode?
    @Published private(set) var message: String?
    let engine: PSABarcodeCaptureEngine
    private var authorization: Task<Void, Never>?
    private var requestID = UUID()
    private var requestedActive = false

    init() {
        engine = PSABarcodeCaptureEngine()
        engine.setHandlers(onRead: { [weak self] code, request in
            guard let self, self.requestedActive, self.requestID == request, self.candidate == nil else { return }
            self.candidate = code; self.pause(); self.message = nil
            DiagnosticLog.shared.record("psa.barcode_captured", ["source": code.source.rawValue])
        }, onFailure: { [weak self] failure, request in
            guard let self, self.requestedActive, self.requestID == request, self.candidate == nil else { return }
            self.message = failure.message; self.pause()
            DiagnosticLog.shared.record("psa.camera_failed", ["reason": failure.rawValue])
        })
    }

    deinit { engine.shutdown() }

    func start() {
        guard !requestedActive, candidate == nil else { return }
        #if targetEnvironment(simulator)
        message = PSACameraFailure.unavailable.message
        return
        #else
        requestedActive = true; message = nil
        let id = UUID(); requestID = id
        authorization = Task { [weak self] in
            let granted = await ScannerCameraAuthorizationCoordinator.shared.authorize()
            guard let self, !Task.isCancelled, self.requestID == id, self.requestedActive,
                  self.candidate == nil else { return }
            self.authorization = nil
            guard granted else {
                self.requestedActive = false
                self.message = "Camera access is unavailable. Enter the certification number, or allow camera access in iPhone Settings."
                return
            }
            self.engine.setActive(true, requestID: id)
        }
        #endif
    }

    func pause() {
        requestedActive = false; requestID = UUID()
        authorization?.cancel(); authorization = nil
        engine.setActive(false)
    }

    func retry() { pause(); start() }
    func scanAgain() { pause(); candidate = nil; engine.releaseHeldCode(); start() }
    func acceptManual(_ code: PSACertificateCode) { pause(); candidate = code; message = nil }
}

private enum PSACameraFailure: String, Sendable {
    case unavailable, configuration, interrupted, runtime
    var message: String {
        switch self {
        case .unavailable: return "No usable back camera is available. Enter the certification number instead."
        case .configuration: return "Barcode capture could not start. Retry the camera or enter the certification number."
        case .interrupted: return "Camera capture was interrupted. Retry when the camera is available, or enter the certification number."
        case .runtime: return "Camera capture stopped. Retry the camera or enter the certification number."
        }
    }
}

/// All mutable capture state and AVFoundation operations are confined to queue.
/// The session is also retained by the system preview layer on the main thread.
private final class PSABarcodeCaptureEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.cardshow.psa-barcode-capture")
    private var configured = false
    private var wantsActive = false
    private var held = false
    private var closed = false
    private var requestID = UUID()
    private var onRead: (@MainActor @Sendable (PSACertificateCode, UUID) -> Void)?
    private var onFailure: (@MainActor @Sendable (PSACameraFailure, UUID) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        for (name, failure) in [(AVCaptureSession.wasInterruptedNotification, PSACameraFailure.interrupted),
                                (AVCaptureSession.runtimeErrorNotification, .runtime)] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.fail(failure) }
            }
            observers.append(observer)
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func setHandlers(onRead: @escaping @MainActor @Sendable (PSACertificateCode, UUID) -> Void,
                     onFailure: @escaping @MainActor @Sendable (PSACameraFailure, UUID) -> Void) {
        queue.async { self.onRead = onRead; self.onFailure = onFailure }
    }

    func setActive(_ active: Bool, requestID: UUID? = nil) {
        queue.async {
            guard !self.closed else { return }
            self.wantsActive = active
            if !active { self.held = false; self.stopSession(); return }
            if let requestID { self.requestID = requestID }
            if self.held { self.stopSession(); return }
            do {
                if !self.configured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            } catch let failure as PSACameraConfigurationError { self.fail(failure.failure) }
            catch { self.fail(.configuration) }
        }
    }

    func releaseHeldCode() { queue.async { self.held = false } }
    func shutdown() { queue.async { self.closed = true; self.wantsActive = false; self.stopSession() } }

    private func configure() throws {
        #if targetEnvironment(simulator)
        throw PSACameraConfigurationError(failure: .unavailable)
        #else
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw PSACameraConfigurationError(failure: .unavailable)
        }
        let input = try AVCaptureDeviceInput(device: device), output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        var succeeded = false
        defer {
            if !succeeded {
                output.setMetadataObjectsDelegate(nil, queue: nil)
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
            }
            session.commitConfiguration()
        }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input) else { throw PSACameraConfigurationError(failure: .configuration) }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw PSACameraConfigurationError(failure: .configuration) }
        session.addOutput(output)
        let supported = [AVMetadataObject.ObjectType.qr, .code128].filter { output.availableMetadataObjectTypes.contains($0) }
        guard !supported.isEmpty else { throw PSACameraConfigurationError(failure: .configuration) }
        output.metadataObjectTypes = supported
        output.setMetadataObjectsDelegate(self, queue: queue)
        succeeded = true; configured = true
        #endif
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard wantsActive, !held, !closed else { return }
        for object in metadataObjects {
            guard let object = object as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { continue }
            let kind: PSABarcodeKind
            switch object.type { case .qr: kind = .qr; case .code128: kind = .code128; default: continue }
            guard let code = PSACertificateCode.parse(value, kind: kind) else { continue }
            // Retire delivery before dispatching the result or processing another frame.
            held = true; wantsActive = false
            queue.async { self.stopSession() }
            let request = requestID
            if let onRead { Task { @MainActor in onRead(code, request) } }
            return
        }
    }

    private func stopSession() { if session.isRunning { session.stopRunning() } }
    private func fail(_ failure: PSACameraFailure) {
        let wasActive = wantsActive
        wantsActive = false; stopSession()
        guard wasActive, !held, !closed, let onFailure else { return }
        let request = requestID
        Task { @MainActor in onFailure(failure, request) }
    }
}

private struct PSACameraConfigurationError: Error { let failure: PSACameraFailure }

@MainActor private struct PSABarcodePreview: UIViewRepresentable {
    let engine: PSABarcodeCaptureEngine
    func makeUIView(context: Context) -> PSABarcodePreviewView {
        let view = PSABarcodePreviewView()
        view.previewLayer.session = engine.session
        return view
    }
    func updateUIView(_ uiView: PSABarcodePreviewView, context: Context) { uiView.setNeedsLayout() }
    static func dismantleUIView(_ uiView: PSABarcodePreviewView, coordinator: ()) { uiView.previewLayer.session = nil }
}

@MainActor private final class PSABarcodePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black; previewLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { super.init(coder: coder); backgroundColor = .black; previewLayer.videoGravity = .resizeAspectFill }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}
