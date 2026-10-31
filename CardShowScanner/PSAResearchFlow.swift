import SwiftUI

/// Slab research is read-only. Catalog identity remains an explicit user choice.
struct PSAResearchFlow: View {
    @State private var certificate = PSAResearchModel()
    @State private var search = ManualCardSearchModel(game: "Pokémon")
    @State private var certificateText = ""
    @State private var inputError: String?
    @State private var showingScanner = false
    @State private var pendingCaptureCode: PSACertificateCode?
    @State private var hasEditedSearch = false
    @State private var match: PSACatalogMatch?

    var body: some View {
        Form {
            Section("PSA label") {
                Button("Scan PSA Barcode or QR", systemImage: "barcode.viewfinder") {
                    pendingCaptureCode = nil; showingScanner = true
                }
                    .buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("psa.scan")
                TextField("Certificate number", text: $certificateText)
                    .keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("psa.certificate")
                Button("Look Up Certificate") { acceptTypedCertificate() }
                    .disabled(certificate.loading).accessibilityIdentifier("psa.lookup")
                if let inputError { Text(inputError).font(.caption).foregroundStyle(.orange) }
                Text("Confirm the number on the label. Certificate metadata and catalog matching are separate from card recognition.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            certificateSection
            Section("Find the catalog card") {
                Picker("Game", selection: Binding(get: { search.game }, set: { search.changeGame($0) })) {
                    ForEach(CatalogOptions.games, id: \.self) { Text($0) }
                }
                TextField("Name, number or set", text: Binding(get: { search.query }, set: {
                    hasEditedSearch = true; search.updateQuery($0)
                }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("psa.catalogSearch")
                Text("Choose the exact catalog card, then confirm its printing and language. Searching does not add inventory or change a saved price.")
                    .font(.caption).foregroundStyle(.secondary)
                if search.isSearching { ProgressView("Searching catalog…") }
                if let error = search.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if !search.isSearching && !search.query.isEmpty && search.results.isEmpty && search.error == nil {
                    Text("No saved catalog matches. Refine the name or number, or refresh this game’s database in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(search.results) { card in
                    Button { match = PSACatalogMatch(card: card, metadata: certificate.metadata) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            PSAResearchArtwork(url: card.imageURL).frame(width: 85, height: 118)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(card.name).font(.headline)
                                Text(card.set).font(.subheadline)
                                Text(card.number).font(.caption)
                                Text("Review match").font(.caption).foregroundStyle(.tint)
                            }.foregroundStyle(.primary)
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.borderless).accessibilityIdentifier("psa.match." + card.identity.productID)
                }
            }
            Section {
                NavigationLink("Research Connection") { ResearchConnectionView() }
                Text("The research server needs a configured, authorized PSA certificate adapter for automatic metadata lookup. Manual catalog search remains available when lookup has no result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Research a PSA Slab").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingScanner, onDismiss: {
                guard let code = pendingCaptureCode else { return }
                pendingCaptureCode = nil; certificateText = code.certificateNumber; inputError = nil
                beginLookup(code)
            }) {
                PSABarcodeScannerView { code in
                    pendingCaptureCode = code; showingScanner = false
                }
            }
            .navigationDestination(item: $match) { selection in
                PSACatalogMatchView(match: selection)
            }
            .onChange(of: certificate.metadata) { _, metadata in
                if let metadata, !hasEditedSearch { search.updateQuery(metadata.suggestedSearch) }
            }
            .onChange(of: certificateText) { _, value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines) != certificate.certificateNumber {
                    certificate.clear()
                }
            }
            .onDisappear { certificate.cancel(); search.cancel() }
            .onAppear {
                if !search.query.isEmpty { search.load() }
            }
    }

    @ViewBuilder private var certificateSection: some View {
        if certificate.loading {
            Section { ProgressView("Looking up certificate…") }
        } else if let metadata = certificate.metadata {
            Section("Certification record") {
                LabeledContent("Certificate", value: metadata.certificateNumber)
                Text(metadata.name).font(.headline)
                if let set = metadata.set { LabeledContent("Set", value: set) }
                if let year = metadata.year { LabeledContent("Year", value: year) }
                if let number = metadata.number { LabeledContent("Card number", value: number) }
                if let printing = metadata.printing { LabeledContent("Printing", value: printing) }
                if let language = metadata.language { LabeledContent("Language", value: language) }
                LabeledContent("Card grade", value: metadata.grader + " " + metadata.grade)
                if let qualifiers = metadata.qualifiers, !qualifiers.isEmpty {
                    LabeledContent("Qualifiers", value: qualifiers.joined(separator: ", "))
                }
                if let grade = metadata.autographGrade { LabeledContent("Autograph grade", value: grade) }
                LabeledContent("Metadata source", value: metadata.source)
                Text("Confirm the card below against the label before opening research.").font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("psa.metadata")
        } else if let message = certificate.message {
            Section("Certificate lookup") {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("Retry Certificate Lookup") { certificate.retry() }.disabled(certificate.certificateNumber.isEmpty)
            }.accessibilityIdentifier("psa.lookupStatus")
        }
    }
    private func acceptTypedCertificate() {
        guard let code = PSACertificateCode.parse(certificateText, kind: .manual) else {
            inputError = PSACertificateFailure.invalidCertificate.errorDescription; return
        }
        certificateText = code.certificateNumber; inputError = nil; beginLookup(code)
    }
    private func beginLookup(_ code: PSACertificateCode) {
        hasEditedSearch = false; search.updateQuery(""); certificate.accept(code)
    }
}

private struct PSACatalogMatch: Identifiable, Hashable {
    let id = UUID()
    let card: CardCandidate
    let metadata: PSACertificateMetadata?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct PSACatalogMatchView: View {
    let match: PSACatalogMatch
    @State private var card: CardCandidate
    @State private var showingResearch = false
    init(match: PSACatalogMatch) {
        self.match = match
        var card = match.card
        card.marketPrice = nil; card.marketPriceMetadata = nil; card.identity.skuID = nil
        if let printing = match.metadata?.printing?.trimmingCharacters(in: .whitespacesAndNewlines), !printing.isEmpty {
            // Retain the certificate finish on this confirmation-only copy even
            // when the cached catalog does not list it. Research still requires
            // an exact returned variant before showing a value.
            if !card.printings.contains(printing) { card.printings.append(printing) }
            card.identity.printing = printing
        }
        if let language = match.metadata?.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            card.identity.language = language
        }
        _card = State(initialValue: card)
    }
    var body: some View {
        Form {
            Section {
                PSAResearchArtwork(url: card.imageURL).frame(maxWidth: .infinity).frame(height: 260)
                Text(card.name).font(.title3.bold())
                LabeledContent("Set", value: card.set)
                LabeledContent("Card number", value: card.number)
                LabeledContent("Catalog reference", value: card.identity.productID)
            }
            Section("Confirm the match") {
                Picker("Printing", selection: $card.identity.printing) {
                    ForEach(Array(Set(card.printings + [card.identity.printing])).sorted(), id: \.self) { Text($0) }
                }.pickerStyle(.menu)
                TextField("Language", text: $card.identity.language).autocorrectionDisabled()
                if let metadata = match.metadata {
                    LabeledContent("Certificate", value: metadata.certificateNumber)
                    if let printing = metadata.printing { LabeledContent("Certificate printing", value: printing) }
                    if let language = metadata.language { LabeledContent("Certificate language", value: language) }
                    LabeledContent("Card grade", value: "PSA " + metadata.researchGrade)
                    if let autograph = metadata.autographGrade { LabeledContent("Autograph grade", value: autograph) }
                } else {
                    Text("Certificate metadata is unavailable. Choose a returned PSA grade on the research screen after checking the slab label.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Research lists returned variants and exact grades. A qualified card grade is kept distinct; an autograph grade is not used as the card grade.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Confirm Match & View Research") { showingResearch = true }
                    .accessibilityIdentifier("psa.confirmMatch")
            }
        }.navigationTitle("Confirm Catalog Card").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingResearch) {
                CardResearchView(card: card, initialSection: .graded,
                                 grader: "PSA", grade: match.metadata?.researchGrade ?? "")
            }
    }
}

private struct PSAResearchArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }.accessibilityLabel("Card artwork")
    }
}
