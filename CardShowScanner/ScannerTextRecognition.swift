import Foundation
import ImageIO
import Vision

/// Transient, normalized observations from one camera image. Never persisted or
/// written to diagnostics. Vision coordinates have their origin at bottom left.
struct ScannerTextObservation: Sendable, Equatable {
    var text: String
    var confidence: Float
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

protocol ScannerTextRecognizing: Sendable {
    func recognize(_ image: Data) async throws -> [ScannerTextObservation]
}

enum ScannerTextRecognitionFailure: Error {
    case invalidImage
}

/// A single accurate on-device pass, outside the main actor and live frame loop.
struct ScannerTextRecognizer: ScannerTextRecognizing {
    func recognize(_ image: Data) async throws -> [ScannerTextObservation] {
        let operation = ScannerTextVisionOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.start(image, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// The lock protects only cancellation and the currently executing Vision
/// request. Request construction, execution and result access share one queue.
private final class ScannerTextVisionOperation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "scanner.text-recognition", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = request
        lock.unlock()
        pending?.cancel()
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
    }

    func start(_ image: Data, continuation: CheckedContinuation<[ScannerTextObservation], Error>) {
        Self.queue.async { [self] in
            do {
                try checkCancellation()
                // Check compressed bytes and dimensions before image decoding.
                // Canvas-generated JPEGs are already oriented; no Photos access
                // or EXIF-dependent orientation guesses are needed here.
                guard !image.isEmpty, image.count <= 2_000_000,
                      let source = CGImageSourceCreateWithData(image as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) == 1,
                      CGImageSourceGetType(source) as String? == "public.jpeg",
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      (1...2048).contains(width.intValue), (1...2048).contains(height.intValue) else {
                    throw ScannerTextRecognitionFailure.invalidImage
                }
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                recognition.preferBackgroundProcessing = true
                recognition.recognitionLanguages = ["en-US"]
                recognition.usesLanguageCorrection = false
                recognition.minimumTextHeight = 0.008
                lock.lock()
                request = recognition
                let stopped = cancelled
                lock.unlock()
                if stopped { throw CancellationError() }
                try VNImageRequestHandler(data: image, orientation: .up, options: [:]).perform([recognition])
                try checkCancellation()
                let observations = (recognition.results ?? []).prefix(128).compactMap { result -> ScannerTextObservation? in
                    guard let text = result.topCandidates(1).first else { return nil }
                    let box = result.boundingBox
                    return ScannerTextObservation(text: String(text.string.prefix(200)), confidence: text.confidence,
                        x: Double(box.minX), y: Double(box.minY), width: Double(box.width), height: Double(box.height))
                }
                lock.lock(); request = nil; lock.unlock()
                continuation.resume(returning: observations)
            } catch {
                lock.lock()
                request = nil
                let stopped = cancelled
                lock.unlock()
                continuation.resume(throwing: stopped ? CancellationError() : error)
            }
        }
    }
}

struct ScannerTextHint: Equatable, Sendable {
    var name: String
    var number: String
}

/// Conservative layout hints, not a second visual matcher. Titles must be near
/// the top; collector numbers must be below them in the same horizontal region.
/// An unreadable collector number can produce a name-only *suggestion*, never
/// a verified identity. Bare damage/HP numbers are deliberately not collected.
enum ScannerTextHintParser {
    static func hints(from observations: [ScannerTextObservation]) -> [ScannerTextHint] {
        let rows = observations.prefix(128).filter(valid)
        let names = rows.compactMap { row -> (ScannerTextObservation, String)? in
            guard row.y >= 0.52,
                  let name = title(row.text) else { return nil }
            return (row, name)
        }.sorted {
            if abs($0.0.y - $1.0.y) > 0.025 { return $0.0.y > $1.0.y }
            if $0.0.confidence != $1.0.confidence { return $0.0.confidence > $1.0.confidence }
            return $0.0.x < $1.0.x
        }
        let numbers = rows.compactMap { row -> (ScannerTextObservation, String)? in
            guard row.y <= 0.42, let number = collector(row.text) else { return nil }
            return (row, number)
        }
        var hints: [ScannerTextHint] = []
        var seen = Set<String>()
        for (row, name) in names {
            let nearby = numbers.filter {
                let middle = $0.0.x + $0.0.width / 2
                return $0.0.y + $0.0.height < row.y - 0.15 &&
                    middle >= row.x - 0.15 && middle <= min(1, row.x + max(0.45, row.width + 0.18))
            }.sorted {
                // A collector near the lower left of its title is more useful
                // than a code in a neighboring binder pocket.
                let a = abs($0.0.x - row.x), b = abs($1.0.x - row.x)
                if abs(a - b) > 0.03 { return a < b }
                return $0.0.confidence > $1.0.confidence
            }
            let hint = ScannerTextHint(name: name, number: nearby.first?.1 ?? "")
            if seen.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted {
                hints.append(hint)
                if hints.count == 3 { break }
            }
        }
        return hints
    }

    private static func valid(_ row: ScannerTextObservation) -> Bool {
        guard row.confidence.isFinite, (0.25...1).contains(row.confidence),
              !row.text.isEmpty, row.text.count <= 200,
              [row.x, row.y, row.width, row.height].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              row.width > 0, row.height > 0, row.x + row.width <= 1.001, row.y + row.height <= 1.001 else { return false }
        return true
    }

    private static func title(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*(?:HP\s*\d{1,4}|\d{1,4}\s*HP)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "★☆•·")))
        guard (3...64).contains(value.count), value.split(separator: " ").count <= 8,
              value.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 3,
              !value.contains("$"), !value.contains("/"),
              value.range(of: #"\b(?:for|during|opponent|weakness|resistance|evolves)\b"#,
                options: [.regularExpression, .caseInsensitive]) == nil,
              value.range(of: #"^(?:trainer|basic|stage\s*[0-9]*|supporter|stadium|item|ability|pokemon|pokémon)$"#,
                options: [.regularExpression, .caseInsensitive]) == nil,
              value.range(of: #"^[\p{L}\p{N}\s'’.,:!&()\-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func collector(_ raw: String) -> String? {
        let text = raw.uppercased()
        let patterns = [#"(?<![A-Z0-9])(?:[A-Z]{0,3}[0-9]{1,4})\s*/\s*(?:[A-Z]{0,3}[0-9]{2,4})(?![A-Z0-9])"#,
                        #"(?<![A-Z0-9])[A-Z0-9]{2,8}-[A-Z]{2}[0-9]{2,4}(?![A-Z0-9])"#]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return text[range].replacingOccurrences(of: " ", with: "")
            }
        }
        return nil
    }
}

struct ScannerTextCatalogMatcher: Sendable {
    private let catalog: any CardCatalogSearching
    init(catalog: any CardCatalogSearching = CachedCardCatalog.shared) { self.catalog = catalog }

    func candidates(from observations: [ScannerTextObservation], game: String) async throws -> [CardCandidate] {
        try Task.checkCancellation()
        let hints = ScannerTextHintParser.hints(from: observations)
        var matches: [CardCandidate] = []
        var seen = Set<String>()
        func append(_ cards: [CardCandidate]) {
            for var card in cards.prefix(5) where matches.count < 5 {
                guard card.identity.game == game, seen.insert(card.identity.productID).inserted else { continue }
                // Catalog hints must not inherit old quotes/SKUs or look like a
                // measured visual probability. Review resolves the printing.
                card.confidence = 0
                card.requiresPrintingSelection = true
                card.identity.skuID = nil
                card.marketPrice = nil
                card.marketPriceMetadata = nil
                card.printingQuotes = nil
                matches.append(card)
            }
        }
        // Prefer the combined identity before spending the bounded fallback
        // searches on title-only suggestions. Never search a number by itself.
        for hint in hints where !hint.number.isEmpty {
            try Task.checkCancellation()
            append(try await catalog.search(hint.name, game: game, limit: 5,
                filters: CardCatalogFilters(number: hint.number)))
            try Task.checkCancellation()
            if matches.count == 5 { return matches }
        }
        if !matches.isEmpty { return matches }
        for hint in hints {
            try Task.checkCancellation()
            append(try await catalog.search(hint.name, game: game, limit: 5))
            try Task.checkCancellation()
            if matches.count == 5 { break }
        }
        return matches
    }
}
