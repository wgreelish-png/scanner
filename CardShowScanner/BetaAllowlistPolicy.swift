import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Accept only a concrete, public network address before replacing an account's
/// allowlist. Host names, network ranges and interface-scoped addresses are not
/// substitutes for the address detected by the provider for this connection.
struct BetaAllowlistAddress {
    static func canonical(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 45,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) ||
                      (97...102).contains($0) || $0 == 46 || $0 == 58
              }) else { return nil }

        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return publicIPv4(bytes) ? bytes.map(String.init).joined(separator: ".") : nil
        }

        var ipv6 = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        // The mapped spelling must have the same public/private classification
        // and identity as its IPv4 address; never allow a mapped private address.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            let mapped = Array(bytes.suffix(4))
            return publicIPv4(mapped) ? mapped.map(String.init).joined(separator: ".") : nil
        }
        guard publicIPv6(bytes) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let length = socklen_t(buffer.count)
        let result = withUnsafePointer(to: &ipv6) { address in
            inet_ntop(AF_INET6, address, &buffer, length)
        }
        guard result != nil else { return nil }
        return String(cString: buffer).lowercased()
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = canonical(lhs), let right = canonical(rhs) else { return false }
        return left == right
    }

    static func isCurrentSingleton(_ allowedIPs: [String], detectedIP: String) -> Bool {
        allowedIPs.count == 1 && matches(allowedIPs[0], detectedIP)
    }

    private static func publicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2], d = bytes[3]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false } // Carrier-grade NAT.
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        // The two globally reachable anycast assignments are exceptions to the
        // otherwise non-public IETF protocol-assignment subnet.
        if a == 192 && b == 0 && c == 0 && d != 9 && d != 10 { return false }
        if a == 192 && b == 0 && c == 2 { return false } // Documentation.
        if a == 198 && (b == 18 || b == 19) { return false } // Benchmarks.
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }

    private static func publicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16, bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false } // Documentation.
            if bytes[2] == 0 && bytes[3] == 2 && bytes[4] == 0 && bytes[5] == 0 { return false }
            if bytes[2] == 0 && (bytes[3] & 0xf0 == 0x10 || bytes[3] & 0xf0 == 0x20) { return false }
        }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false } // Documentation.
        return true
    }
}

/// The coordinator owns its task and network monitor. This value only decides
/// whether foreground work is due and preserves a failure cooldown across a
/// quick background/foreground transition. It never schedules background work.
struct BetaAllowlistSyncPolicy: Sendable {
    static let checkInterval: TimeInterval = 60
    private(set) var nextCheckAt: Date?
    private(set) var cooldownUntil: Date?

    func isDue(at date: Date, isActive: Bool, enabled: Bool) -> Bool {
        guard isActive, enabled, date.timeIntervalSince1970.isFinite else { return false }
        return (nextCheckAt.map({ date >= $0 }) ?? true) &&
            (cooldownUntil.map({ date >= $0 }) ?? true)
    }

    mutating func recordSuccess(at date: Date) {
        guard date.timeIntervalSince1970.isFinite else { return }
        nextCheckAt = date.addingTimeInterval(Self.checkInterval)
        cooldownUntil = nil
    }

    mutating func recordFailure(at date: Date, retryAfterSeconds: TimeInterval? = nil) {
        guard date.timeIntervalSince1970.isFinite else { return }
        let retry = retryAfterSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        let delay = max(Self.checkInterval, min(retry, 24 * 60 * 60))
        cooldownUntil = date.addingTimeInterval(delay)
        nextCheckAt = cooldownUntil
    }

    mutating func resetForForeground() {
        nextCheckAt = nil
    }
}
