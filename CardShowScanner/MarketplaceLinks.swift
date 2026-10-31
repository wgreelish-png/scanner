import Foundation

/// Product references establish the destination, never a display name, SKU or
/// provider-supplied arbitrary URL. This opens the raw-card product page; the
/// selected printing/condition and current lowest listing are chosen there.
enum MarketplaceLinks {
    static func tcgplayerProduct(_ reference: String) -> URL? {
        let identifier = reference.hasPrefix("p:") ? String(reference.dropFirst(2)) : reference
        guard (1...12).contains(identifier.utf8.count),
              identifier.utf8.allSatisfy({ (48...57).contains($0) }),
              let productID = UInt64(identifier), productID > 0 else { return nil }
        return URL(string: "https://www.tcgplayer.com/product/\(productID)")
    }
}
