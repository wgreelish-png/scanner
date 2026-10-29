import Foundation

enum PSABarcodeKind: Sendable {
    case qr, code128, manual
}

/// A possible certification identifier, not proof of a card's identity or
/// authenticity. The capture screen always asks the user to confirm this value.
struct PSACertificateCode: Equatable, Hashable, Sendable {
    enum Source: String, Sendable { case psaQR, code128, manual }
    let certificateNumber: String
    let source: Source

    static func parse(_ payload: String, kind: PSABarcodeKind) -> Self? {
        guard payload.utf8.count <= 512 else { return nil }
        switch kind {
        case .manual:
            let value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            return digits(value) ? Self(certificateNumber: value, source: .manual) : nil
        case .code128:
            return digits(payload) ? Self(certificateNumber: payload, source: .code128) : nil
        case .qr:
            guard let components = URLComponents(string: payload),
                  components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(), ["psacard.com", "www.psacard.com"].contains(host),
                  components.user == nil, components.password == nil,
                  components.port == nil || components.port == 443,
                  components.query == nil, components.fragment == nil,
                  !components.percentEncodedPath.contains("%"),
                  !payload.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
            let path = components.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3 || (parts.count == 4 && parts[3].isEmpty),
                  parts[0].isEmpty, parts[1] == "cert", digits(String(parts[2])) else { return nil }
            return Self(certificateNumber: String(parts[2]), source: .psaQR)
        }
    }

    private static func digits(_ text: String) -> Bool {
        // This is a bounded candidate format, not a claim that all numeric
        // barcodes or every PSA label generation use the same encoding.
        (6...12).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) }
    }
}
