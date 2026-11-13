import Foundation

enum CardImageContext: CaseIterable, Equatable, Sendable {
    case thumbnail, detail
}

/// Display-only catalog artwork quality. Source URLs and saved card records
/// retain their original value; recognition references and printing are separate.
enum CardImageQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, low, high

    static let defaultsKey = "cardImageQuality"
    static let defaultValue: Self = .high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .low: "Low"
        case .high: "High"
        }
    }

    var settingTitle: String {
        switch self {
        case .automatic: title
        case .low: "Low (200px)"
        case .high: "High (400px)"
        }
    }

    func pixelWidth(for context: CardImageContext) -> Int {
        switch self {
        case .automatic: context == .thumbnail ? 200 : 400
        case .low: 200
        case .high: 400
        }
    }

    static func current(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }

    /// Only these known CDN renditions can be selected safely. Other providers,
    /// signed URLs, and non-catalog images keep their original URL.
    func imageURL(_ original: URL?, context: CardImageContext) -> URL? {
        guard let original,
              original.scheme?.lowercased() == "https",
              original.host?.lowercased() == "cdn.tcgtracking.com",
              original.user == nil, original.password == nil, original.port == nil,
              original.query == nil, original.fragment == nil,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return original }
        let path = components.percentEncodedPath
        guard path.range(of: #"^/product/[1-9][0-9]*(?:_[1-9][0-9]*)?_(?:200|400)w\.jpg$"#,
                         options: .regularExpression) != nil else { return original }
        let suffix = path.hasSuffix("_200w.jpg") ? "_200w.jpg" : "_400w.jpg"
        components.percentEncodedPath = String(path.dropLast(suffix.count)) + "_\(pixelWidth(for: context))w.jpg"
        return components.url ?? original
    }
}
