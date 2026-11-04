import SwiftUI

/// Standalone stickers work without stock, a saved show or tag approvals.
@MainActor struct CustomPriceTagView: View {
    @State private var model = CustomPriceTagModel()
    @State private var queue = LabelPrintQueue.shared
    @State private var showingQueue = false
    @State private var bitmap: InventoryLabelBitmap?
    @State private var previewDraft: CustomPriceTagDraft?
    @State private var previewError: String?
    @FocusState private var focused: Field?
    private enum Field { case price, copies }

    var body: some View {
        Form {
            Section("Price") {
                HStack {
                    Text("$").foregroundStyle(.secondary)
                    TextField("Whole-dollar price", text: $model.price).keyboardType(.numberPad)
                        .focused($focused, equals: .price).accessibilityIdentifier("customLabels.price")
                }
                Text("A price-only sticker. Check each card's cost before using it; inventory prices stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Labels") {
                LabeledContent("Copies") {
                    TextField("1", text: $model.copies).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .focused($focused, equals: .copies).frame(minWidth: 60)
                        .accessibilityIdentifier("customLabels.copies")
                }
                Picker("Physical paper", selection: $model.paperSize) {
                    ForEach(InventoryLabelSize.allCases) { paper in Text(paper.title).tag(paper) }
                }.accessibilityIdentifier("customLabels.paper")
                Text("1–100 copies. Choose the size on the roll loaded in your printer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                if let bitmap, let previewDraft, previewDraft == model.draft {
                    Image(uiImage: bitmap.previewImage).resizable().interpolation(.none).scaledToFit()
                        .frame(maxWidth: .infinity).padding(12).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Price tag preview")
                        .accessibilityValue("\(previewDraft.priceText) · \(previewDraft.paperSize.title)")
                        .accessibilityIdentifier("customLabels.preview")
                } else {
                    Text(previewError ?? "Enter a whole-dollar price and copy count to preview your sticker.")
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
        .navigationDestination(isPresented: $showingQueue) { LabelPrintQueueView() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(model.copies) labels").font(.subheadline).monospacedDigit()
                Spacer(minLength: 12)
                Button(model.hasPreparedQueue ? "View Queue" : "Prepare Labels") {
                    focused = nil
                    if model.prepare() { showingQueue = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.draft == nil || model.preparing || queue.isPrinting || !queue.isLoaded
                          || (!queue.entries.isEmpty && !model.hasPreparedQueue))
                .accessibilityIdentifier("customLabels.prepare")
            }.padding(16).background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }.fixedSize().frame(minWidth: 64, minHeight: 44)
                    .accessibilityIdentifier("customLabels.keyboardDone")
            }
        }
        .task(id: model.draft) {
            bitmap = nil; previewDraft = nil; previewError = nil
            guard let draft = model.draft else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard model.draft == draft else { return }
                bitmap = try InventoryLabelRenderer.render(draft)
                previewDraft = draft
            } catch is CancellationError {} catch { previewError = error.localizedDescription }
        }
    }
}
