import SwiftUI

/// Standalone stickers work without stock, a saved show or tag approvals.
@MainActor struct CustomPriceTagView: View {
    private let onPrintingCompleted: (() -> Void)?
    @State private var model: CustomPriceTagModel
    @State private var paperPreferences: LabelPaperPreferences
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared
    @State private var showingQueue = false
    @State private var bitmap: InventoryLabelBitmap?
    @State private var previewDraft: CustomPriceTagDraft?
    @State private var previewError: String?
    @FocusState private var focused: Field?
    private enum Field { case price, copies }

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
                    paperPreferences.select(size)
                    model.paperSize = paperPreferences.size
                })) {
                    ForEach(paperPreferences.availableSizes) { paper in Text(paper.title).tag(paper) }
                }.disabled(paperPreferences.detectedProduct != nil)
                    .accessibilityIdentifier("customLabels.paper")
                LabelPricePositionPicker(selection: Binding(get: { model.pricePosition }, set: { position in
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
                if let bitmap, let previewDraft, previewDraft == model.draft {
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
            if !queue.isLoaded || (!queue.entries.isEmpty && !model.hasPreparedQueue) {
                Section("Saved print queue") {
                    Text(queue.isLoaded
                         ? "Review or clear the saved queue before preparing new labels."
                         : (queue.error ?? "Your saved queue needs attention."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Review Saved Queue") { focused = nil; showingQueue = true }
                        .accessibilityIdentifier("customLabels.reviewQueue")
                    if !queue.isLoaded {
                        Button("Reload Queue") { queue.reload() }.accessibilityIdentifier("customLabels.reloadQueue")
                    }
                }
            }
            if let error = model.error {
                Section { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Custom Price Tag").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: $showingQueue) {
            LabelPrintQueueView(onPrintingCompleted: onPrintingCompleted)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(model.copies) labels").font(.subheadline).monospacedDigit()
                Spacer(minLength: 12)
                Button(model.hasPreparedQueue ? "View Queue" : "Prepare Labels") {
                    guard model.hasPreparedQueue || !printer.isReadingRoll else { return }
                    focused = nil
                    model.paperSize = paperPreferences.size
                    model.pricePosition = paperPreferences.pricePosition
                    if model.prepare() { showingQueue = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.draft == nil || model.preparing || queue.isPrinting || !queue.isLoaded
                          || (!model.hasPreparedQueue && printer.isReadingRoll)
                          || (!queue.entries.isEmpty && !model.hasPreparedQueue))
                .accessibilityIdentifier("customLabels.prepare")
            }.padding(16).background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ClearLabelPrintQueueButton(identifier: "customLabels.clearQueue")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }.fixedSize().frame(minWidth: 64, minHeight: 44)
                    .accessibilityIdentifier("customLabels.keyboardDone")
            }
        }
        .onAppear {
            model.paperSize = paperPreferences.size
            model.pricePosition = paperPreferences.pricePosition
        }
        .onChange(of: paperPreferences.size) { _, size in model.paperSize = size }
        .onChange(of: paperPreferences.pricePosition) { _, position in model.pricePosition = position }
        .onChange(of: model.isBulk) { _, _ in focused = nil }
        .task(id: model.draft) {
            bitmap = nil; previewDraft = nil; previewError = nil
            guard let draft = model.draft else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard model.draft == draft else { return }
                let raster = try model.previewRaster(for: draft)
                bitmap = InventoryLabelBitmap(raster: raster,
                    previewImage: try InventoryLabelRenderer.image(raster: raster, paper: draft.paperSize))
                previewDraft = draft
            } catch is CancellationError {} catch { previewError = error.localizedDescription }
        }
    }
}
