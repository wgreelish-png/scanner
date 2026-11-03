import SwiftUI
import UIKit

/// Bluetooth is created by the printer only after an explicit scan action.
@MainActor struct LabelPrinterSettingsView: View {
    let printer: LetraTagPrinter
    var retainConnectionOnDisappear: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: PriceTagBitmap?
    @State private var previewError: String?

    init(printer: LetraTagPrinter = .shared, retainConnectionOnDisappear: Bool = false) {
        self.printer = printer
        self.retainConnectionOnDisappear = retainConnectionOnDisappear
    }

    var body: some View {
        Form {
            Section {
                Label("DYMO LetraTag 200B", systemImage: "printer")
                Text("Experimental Bluetooth printing. This iPhone connection still needs verification with your printer.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(printer.status).accessibilityIdentifier("labelPrinter.status")
            }
            Section("Connection") {
                if printer.isConnected {
                    Button("Disconnect", role: .destructive) { printer.disconnect() }
                        .disabled(printer.isPrinting)
                        .accessibilityIdentifier("labelPrinter.disconnect")
                } else {
                    Button(printer.isScanning ? "Stop Searching" : "Search for Printer", systemImage: printer.isScanning ? "stop.circle" : "antenna.radiowaves.left.and.right") {
                        if printer.isScanning { printer.stopScanning() }
                        else { printer.scan() }
                    }.disabled(printer.isPrinting)
                        .accessibilityIdentifier("labelPrinter.scan")
                    ForEach(printer.devices) { device in
                        Button {
                            printer.connect(deviceID: device.id)
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                Image(systemName: "link")
                            }
                        }.disabled(printer.isPrinting)
                            .accessibilityIdentifier("labelPrinter.device." + device.id.uuidString)
                    }
                    if printer.isScanning { ProgressView("Looking for nearby printers…") }
                }
            }
            Section {
                if let preview {
                    PriceTagPreview(bitmap: preview)
                }
                Button("Print One Test Label", systemImage: "printer") {
                    do {
                        let bitmap = try PriceTagRenderer.testLabel()
                        preview = bitmap
                        previewError = nil
                        printer.print(bitmapData: bitmap.packedColumns)
                    } catch { previewError = error.localizedDescription }
                }.disabled(!printer.isConnected || printer.isPrinting || scenePhase != .active)
                    .accessibilityIdentifier("labelPrinter.test")
            } header: {
                Text("Test before printing price tags")
            } footer: {
                Text("Each tap sends one test label. Check its orientation and readability before printing inventory tags.")
            }
            Section {
                DisclosureGroup("Printer protocol credits") {
                    Text(LetraTagProtocol.thirdPartyNotice).font(.footnote).textSelection(.enabled)
                }
            }
            if let error = previewError ?? printer.error {
                Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("labelPrinter.error") }
            }
            if printer.isPrinting {
                Section {
                    ProgressView("Waiting for printer confirmation…")
                    Button("Stop Sending", role: .destructive) { printer.stop() }
                }
            }
        }
        .navigationTitle("Label Printer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(printer.isPrinting)
        .onAppear {
            if preview == nil { preview = try? PriceTagRenderer.testLabel() }
        }
        .onChange(of: scenePhase) { _, phase in
            printer.setActive(phase == .active)
        }
        .onDisappear {
            if retainConnectionOnDisappear { printer.stopScanning() }
            else { printer.stop() }
        }
    }
}

/// Label drafts are local to this screen. Printing never changes stock or quotes.
@MainActor struct PriceTagQueueView: View {
    let inventory: [ShowInventoryItem]
    let printer: LetraTagPrinter
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var drafts: [UUID: PriceTagDraft] = [:]
    @State private var confirmedCopies: [UUID: Int] = [:]
    @State private var needsPrintCheck = false
    @State private var showingSettings = false
    @State private var showingReview = false

    init(inventory: [ShowInventoryItem], printer: LetraTagPrinter = .shared) {
        self.inventory = inventory
        self.printer = printer
    }

    private var available: [ShowInventoryItem] { inventory.filter { $0.quantity > 0 } }
    private var filtered: [ShowInventoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return available.filter { item in
            query.isEmpty || [item.card.name, item.card.set, item.card.number,
                item.card.identity.printing, item.card.identity.condition]
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }
    private var selectedIDs: [UUID] { available.compactMap { drafts[$0.id] == nil ? nil : $0.id } }
    private var labelCount: Int { selectedIDs.reduce(0) { $0 + (drafts[$1]?.copies ?? 0) } }

    var body: some View {
        List {
            if available.isEmpty {
                ContentUnavailableView("No Available Inventory", systemImage: "shippingbox",
                    description: Text("Add cards to show inventory before preparing price tags."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(filtered) { item in
                let selected = drafts[item.id] != nil
                Button {
                    if selected {
                        drafts.removeValue(forKey: item.id)
                        confirmedCopies.removeValue(forKey: item.id)
                    } else {
                        drafts[item.id] = PriceTagDraft(item: item)
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.card.name).font(.headline).foregroundStyle(.primary)
                            Text([item.card.set, item.card.number, item.card.identity.condition]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(item.quantity) available")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }.frame(minHeight: 66).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(item.card.name), \(item.quantity) available")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("priceTags.select." + item.id.uuidString)
            }
        }
        .navigationTitle("Price Tags")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name, set, number, or condition")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(printer.isConnected ? "Printer connected" : "Connect your LetraTag 200B")
                        .font(.subheadline.weight(.medium))
                    Text("One label per selected card by default")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Printer") { showingSettings = true }
                    .accessibilityIdentifier("priceTags.printer")
            }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                endEditing()
                showingReview = true
            } label: {
                Text("Review \(labelCount) \(labelCount == 1 ? "Label" : "Labels")")
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(selectedIDs.isEmpty)
                .padding().background(.regularMaterial)
                .accessibilityIdentifier("priceTags.review")
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                LabelPrinterSettingsView(printer: printer, retainConnectionOnDisappear: true)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingSettings = false }.disabled(printer.isPrinting)
                    } }
            }.interactiveDismissDisabled(printer.isPrinting)
        }
        .sheet(isPresented: $showingReview) {
            NavigationStack {
                PriceTagReviewView(draftIDs: selectedIDs, drafts: $drafts,
                    confirmedCopies: $confirmedCopies, needsPrintCheck: $needsPrintCheck, printer: printer)
            }.interactiveDismissDisabled(printer.isPrinting)
        }
        .onChange(of: scenePhase) { _, phase in
            printer.setActive(phase == .active)
        }
        .onDisappear {
            endEditing()
            if showingSettings || showingReview { printer.stopScanning() }
            else { printer.stop() }
        }
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

@MainActor private struct PriceTagReviewView: View {
    let draftIDs: [UUID]
    @Binding var drafts: [UUID: PriceTagDraft]
    @Binding var confirmedCopies: [UUID: Int]
    @Binding var needsPrintCheck: Bool
    let printer: LetraTagPrinter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LabelPrinterSettingsView(printer: printer, retainConnectionOnDisappear: true)
                } label: {
                    Label(printer.isConnected ? "Printer Connected" : "Connect Printer", systemImage: "printer")
                }.disabled(printer.isPrinting)
                Text(printer.status).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(draftIDs, id: \.self) { id in
                    if let draft = drafts[id] {
                        NavigationLink {
                            PriceTagEditorView(draft: Binding(get: { drafts[id] ?? draft }, set: { drafts[id] = $0 }),
                                confirmedCopies: Binding(get: { confirmedCopies[id] ?? 0 }, set: { confirmedCopies[id] = $0 }),
                                needsPrintCheck: $needsPrintCheck, printer: printer)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.cardName).font(.headline)
                                Text("\(draft.priceText ?? "Set asking price") · \(draft.copies) \(draft.copies == 1 ? "label" : "labels")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let confirmed = confirmedCopies[id], confirmed > 0 {
                                    Text("\(confirmed) confirmed by printer").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("priceTags.edit." + id.uuidString)
                    }
                }
            } header: {
                Text("Preview each tag")
            } footer: {
                Text("Open a tag to edit its asking price and copies. Each Print tap sends one label. Printing does not change inventory quantities or saved prices.")
            }
            if needsPrintCheck {
                Section { PrintOutcomeCheck(needsPrintCheck: $needsPrintCheck) }
            }
        }
        .navigationTitle("Review Price Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.disabled(printer.isPrinting)
                .accessibilityIdentifier("priceTags.done")
        } }
    }
}

@MainActor private struct PriceTagEditorView: View {
    @Binding var draft: PriceTagDraft
    @Binding var confirmedCopies: Int
    @Binding var needsPrintCheck: Bool
    let printer: LetraTagPrinter
    @Environment(\.scenePhase) private var scenePhase
    @State private var bitmap: PriceTagBitmap?
    @State private var renderError: String?
    @State private var pendingPrintBaseline: Int?

    private var remainingCopies: Int { max(0, draft.copies - confirmedCopies) }

    var body: some View {
        Form {
            Section {
                Text(draft.cardName).font(.headline)
                LabeledContent("Card number", value: draft.cardNumber.isEmpty ? "—" : draft.cardNumber)
                LabeledContent("Condition", value: draft.condition)
            }
            Section {
                HStack {
                    Text("Asking price")
                    Spacer()
                    Text("USD").foregroundStyle(.secondary)
                    TextField("0.00", text: $draft.askingPriceText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 140)
                        .accessibilityIdentifier("priceTags.askingPrice")
                }
                Stepper("Copies: \(draft.copies)", value: $draft.copies, in: 1...PriceTagDraft.maximumCopies)
                    .accessibilityIdentifier("priceTags.copies")
            } footer: {
                Text("Asking price is for this label only. Changing it starts a new label count.")
            }.disabled(printer.isPrinting)
            Section("Label preview") {
                if let bitmap { PriceTagPreview(bitmap: bitmap) }
                if let error = draft.validationMessage ?? renderError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("priceTags.validation")
                }
            }
            Section {
                LabeledContent("Printer confirmed", value: "\(confirmedCopies) of \(draft.copies)")
                    .accessibilityIdentifier("priceTags.confirmedCopies")
                if printer.isPrinting {
                    ProgressView("Waiting for printer confirmation…")
                    Button("Stop Sending", role: .destructive) { printer.stop(); settlePrint() }
                } else if remainingCopies == 0 {
                    Label("All requested labels confirmed", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if let error = printer.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                if needsPrintCheck { PrintOutcomeCheck(needsPrintCheck: $needsPrintCheck) }
                if !printer.isConnected {
                    NavigationLink("Connect Printer") {
                        LabelPrinterSettingsView(printer: printer, retainConnectionOnDisappear: true)
                    }
                }
            } footer: {
                Text("Only a successful printer response advances this count. If an attempt is interrupted or unconfirmed, check the printer before retrying.")
            }
        }
        .navigationTitle("Edit Price Tag")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(printer.isPrinting)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button {
                guard let bitmap, pendingPrintBaseline == nil else { return }
                pendingPrintBaseline = printer.completedPrintCount
                printer.print(bitmapData: bitmap.packedColumns)
                if !printer.isPrinting { settlePrint() }
            } label: {
                Text(printer.isPrinting ? "Printing…" : "Print One Label")
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
            }.buttonStyle(.borderedProminent)
                .disabled(bitmap == nil || draft.validationMessage != nil || !printer.isConnected || printer.isPrinting || needsPrintCheck || remainingCopies == 0 || scenePhase != .active)
                .padding().background(.regularMaterial)
                .accessibilityIdentifier("priceTags.printOne")
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }.frame(minWidth: 64, minHeight: 44)
        } }
        .onAppear { renderPreview() }
        .onChange(of: draft.askingPriceText) { _, _ in
            confirmedCopies = 0
            renderPreview()
        }
        .onChange(of: printer.completedPrintCount) { _, _ in settlePrint() }
        .onChange(of: printer.isPrinting) { _, printing in
            if !printing { settlePrint() }
        }
        .onChange(of: scenePhase) { _, phase in
            printer.setActive(phase == .active)
            if phase != .active { settlePrint() }
        }
    }

    private func renderPreview() {
        do { bitmap = try PriceTagRenderer.render(draft); renderError = nil }
        catch { bitmap = nil; renderError = error.localizedDescription }
    }

    private func settlePrint() {
        guard let baseline = pendingPrintBaseline else { return }
        if printer.completedPrintCount > baseline {
            confirmedCopies += 1
            pendingPrintBaseline = nil
        } else if !printer.isPrinting {
            needsPrintCheck = true
            pendingPrintBaseline = nil
        }
    }
}

private struct PrintOutcomeCheck: View {
    @Binding var needsPrintCheck: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The last label was not confirmed. Check whether it printed before sending another label; retrying may create a duplicate.")
                .font(.footnote).foregroundStyle(.orange)
            Button("I Checked the Printer") { needsPrintCheck = false }
                .accessibilityIdentifier("priceTags.checkedPrinter")
        }
    }
}

private struct PriceTagPreview: View {
    let bitmap: PriceTagBitmap

    var body: some View {
        Image(uiImage: bitmap.previewImage)
            .interpolation(.none).resizable().scaledToFit()
            .padding(12).frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.4)) }
            .accessibilityLabel("Monochrome label preview")
            .accessibilityIdentifier("priceTags.preview")
    }
}
