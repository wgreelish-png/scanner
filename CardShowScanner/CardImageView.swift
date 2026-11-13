import SwiftUI

/// One preference-aware artwork loader for card-display surfaces. It changes
/// only the requested rendition, preserving each caller's layout and placeholder.
struct CardImageView<Content: View>: View {
    let url: URL?
    private let content: (AsyncImagePhase) -> Content
    @AppStorage(CardImageQuality.defaultsKey) private var storedQuality = CardImageQuality.defaultValue.rawValue

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        let quality = CardImageQuality(rawValue: storedQuality) ?? .defaultValue
        AsyncImage(url: quality.imageURL(url), content: content)
    }
}
