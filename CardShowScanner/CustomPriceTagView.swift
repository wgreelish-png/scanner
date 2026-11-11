import SwiftUI

/// Standalone stickers work without stock, a saved show or tag approvals.
@MainActor struct CustomPriceTagView: View {
    private let onPrintingCompleted: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var model: CustomPriceTagModel
    @State private var paperPreferences: LabelPaperPreferences
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared
    @State private var printing = LabelDirectPrintController()
    @State private var showingQueue = false
    @State private var bitmap: InventoryLabelBitmap?
    @State private var previewDraft: CustomPriceTagDraft?
    @State private var previewError: String?
    @FocusState private var focused: Field?
    private enum Field { case price, copies }

    private var activityState: DiagnosticActivityState {
        let blocked: DiagnosticActivityBlockReason = !queue.isLoaded ? .queueUnavailable
            : queue.isPrinting || printing.isBusy ? .printerBusy
            : model.preparing ? .preparing
            : (queue.entries.contains { $0.state != .completed } && !model.hasPreparedQueue) ? .unfinishedQueue
            : (!model.hasPreparedQueue && printer.isReadingRoll) ? .rollReading
            : model.draft == nil ? .invalidInput
            : !printing.printerReady(printer) ? .printerDisconnected : .ready
        return DiagnosticActivityState(labelCount: model.draft?.copies,
            pendingCount: queue.pendingCount, completedCount: queue.completedCount,
            failedCount: queue.failedCount, uncertainCount: queue.uncertainCount,
            previewReady: bitmap != nil && previewDraft == model.artworkDraft, isPreparing: model.preparing,
            canProceed: blocked == .ready, printerConnected: printer.isConnected,
            rollReading: printer.isReadingRoll, blockReason: blocked)
    }

    init(isBulk: Bool = false, paperPreferences: LabelPaperPreferences = .shared,
         onPrintingCompleted: (() -> Void)? = nil) {
        self.onPrintingCompleted = onPrintingCompleted
        _paperPreferences = State(initialValue: paperPreferences)
        let model = CustomPriceTagModel(paperSize: paperPreferences.size, pricePosition: paperPreferences.pricePosition)
        model.isBulk = isBulk
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            Section("Tag") {
                Picker("Tag", selection: $model.isBulk) {
                    Text("Individual price").tag(false)
                    Text("2 for $1").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("customLabels.tag")
                if model.isBulk {
                    Text("Print extra PokéDen 2 for $1 tags for cards or bins. Inventory batches also label each selected 2 for $1 card.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Whole-dollar price", text: $model.price).keyboardType(.numberPad)
                            .focused($focused, equals: .price).accessibilityIdentifier("customLabels.price")
                    }
                    Text("PokéDen logo and price. Enter 0 to leave the price area blank for writing in. Inventory prices stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Labels") {
                LabeledContent("Copies") {
                    TextField("1", text: $model.copies).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .focused($focused, equals: .copies).frame(minWidth: 60)
                        .accessibilityIdentifier("customLabels.copies")
                }
                Picker("Physical paper", selection: Binding(get: { paperPreferences.size }, set: { size in
                    DiagnosticLog.shared.activity(.action, screen: .customLabels, action: .changePaper)
                    paperPreferences.select(size)
                    model.paperSize = paperPreferences.size
                })) {
                    ForEach(paperPreferences.availableSizes) { paper in Text(paper.title).tag(paper) }
                }.disabled(paperPreferences.detectedProduct != nil)
                    .accessibilityIdentifier("customLabels.paper")
                LabelPricePositionPicker(selection: Binding(get: { model.pricePosition }, set: { position in
                    DiagnosticLog.shared.activity(.action, screen: .customLabels, action: .changeLayout)
                    model.pricePosition = position
                    paperPreferences.selectPricePosition(position)
                }), identifier: "customLabels.pricePosition")
                Text(printer.isReadingRoll ? "Reading label measurements…" : paperPreferences.detectedProduct == nil
                     ? "1–100 copies. Label size and price position are remembered. Check the size matches the loaded roll."
                     : "Detected from roll. The design uses these measurements within the printer's 12 mm head. Your price-side preference is remembered.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("customLabels.paperSource")
            }
            Section("Preview") {
                if let bitmap, let previewDraft, previewDraft == model.artworkDraft {
                    Image(uiImage: bitmap.previewImage).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: .infinity).padding(12).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Price tag preview")
                        .accessibilityValue("\(previewDraft.priceDescription) · \(previewDraft.paperSize.title) · \(previewDraft.pricePosition.title)")
                        .accessibilityIdentifier("customLabels.preview")
                } else {
                    Text(previewError ?? (model.isBulk
                        ? "Enter 1–100 copies to preview your 2 for $1 sticker."
                        : "Enter a whole-dollar price and copy count to preview your sticker."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !queue.isLoaded || (queue.entries.contains { $0.state != .completed } && !model.hasPreparedQueue) {
                Section("Saved print queue") {
                    Text(queue.isLoaded
                         ? "Review or clear the saved queue before preparing new labels."
                         : (queue.error ?? "Your saved queue needs attention."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Review Saved Queue") {
                        DiagnosticLog.shared.activity(.action, screen: .customLabels, action: .openQueue, state: activityState)
                        focused = nil; showingQueue = true
                    }
                        .accessibilityIdentifier("customLabels.reviewQueue")
                    if !queue.isLoaded {
                        Button("Reload Queue") { queue.reload() }.accessibilityIdentifier("customLabels.reloadQueue")
                    }
                }
            }
            if let error = model.error {
                Section { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            LabelEditorPrinterStatus(controller: printing, printer: printer)
        }
        .navigationTitle("Custom Price Tag").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: $showingQueue) {
            LabelPrintQueueView(onPrintingCompleted: onPrintingCompleted)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("\(model.copies) labels").font(.subheadline).monospacedDigit()
                    Spacer(minLength: 12)
                    Button("Review Queue") {
                        DiagnosticLog.shared.activity(.action, screen: .customLabels,
                            action: model.hasPreparedQueue ? .openQueue : .prepareLabels, state: activityState)
                        guard model.hasPreparedQueue || !printer.isReadingRoll else { return }
                        focused = nil
                        model.paperSize = paperPreferences.size
                        model.pricePosition = paperPreferences.pricePosition
                        let prepared = model.prepare()
                        if prepared { showingQueue = true }
                        DiagnosticLog.shared.activity(.outcome, screen: .customLabels, action: .prepareLabels,
                            state: DiagnosticActivityState(labelCount: model.draft?.copies,
                                pendingCount: queue.pendingCount, completedCount: queue.completedCount,
                                failedCount: queue.failedCount, uncertainCount: queue.uncertainCount,
                                succeeded: prepared))
                    }
                    .font(.subheadline).buttonStyle(.plain)
                    .disabled(model.draft == nil || model.preparing || queue.isPrinting || printing.isBusy || !queue.isLoaded
                              || (!model.hasPreparedQueue && printer.isReadingRoll)
                              || (queue.entries.contains { $0.state != .completed } && !model.hasPreparedQueue))
                    .accessibilityIdentifier("customLabels.prepare")
                }
                Button("Print \(model.draft?.copies ?? 0) Labels") { startPrinting() }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    .disabled(model.draft == nil || model.preparing || queue.isPrinting || printing.isBusy || !queue.isLoaded
                              || printer.isReadingRoll || !printing.printerReady(printer)
                              || (model.hasPreparedQueue ? !queue.canStart : queue.entries.contains { $0.state != .completed }))
                    .accessibilityIdentifier("customLabels.print")
            }.padding(16).background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ClearLabelPrintQueueButton(identifier: "customLabels.clearQueue", activityScreen: .customLabels)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }.fixedSize().frame(minWidth: 64, minHeight: 44)
                    .accessibilityIdentifier("customLabels.keyboardDone")
            }
        }
        .onAppear {
            if !printing.usesFixturePrinter { printer.startPriceTagsConnection() }
            model.paperSize = paperPreferences.size
            model.pricePosition = paperPreferences.pricePosition
            DiagnosticLog.shared.activity(.screen, screen: .customLabels, state: activityState)
        }
        .onDisappear { DiagnosticLog.shared.activity(.exit, screen: .customLabels, state: activityState) }
        .onChange(of: activityState) { _, state in
            DiagnosticLog.shared.activity(.state, screen: .customLabels, state: state)
        }
        .onChange(of: paperPreferences.size) { _, size in model.paperSize = size }
        .onChange(of: paperPreferences.pricePosition) { _, position in model.pricePosition = position }
        .onChange(of: model.isBulk) { _, _ in
            DiagnosticLog.shared.activity(.action, screen: .customLabels, action: .changeLayout)
            focused = nil
        }
        .modifier(LabelDirectPrintPresentation(controller: printing, queue: queue, printer: printer,
            onSuccess: { if let onPrintingCompleted { onPrintingCompleted() } else { dismiss() } },
            onReview: { showingQueue = true }))
        .task(id: model.artworkDraft) {
            bitmap = nil; previewDraft = nil; previewError = nil
            guard let draft = model.artworkDraft else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard model.artworkDraft == draft else { return }
                let raster = try model.previewRaster(for: draft)
                bitmap = InventoryLabelBitmap(raster: raster,
                    previewImage: try InventoryLabelRenderer.image(raster: raster, paper: draft.paperSize))
                previewDraft = draft
            } catch is CancellationError {} catch { previewError = error.localizedDescription }
        }
    }

    private func startPrinting() {
        guard !printing.isBusy,
              printing.printerReady(printer), !printer.isReadingRoll else { return }
        focused = nil
        model.paperSize = paperPreferences.size; model.pricePosition = paperPreferences.pricePosition
        DiagnosticLog.shared.activity(.action, screen: .customLabels, action: .printLabels, state: activityState)
        guard model.prepare() else { return }
        if !printing.start(queue: queue, printer: printer) { showingQueue = true }
    }
}
