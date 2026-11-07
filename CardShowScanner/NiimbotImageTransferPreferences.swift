import Foundation
import Observation
import CoreFoundation

/// An immutable job-start snapshot. The connected Bluetooth limit can reduce
/// the requested batch size further without changing these saved preferences.
struct NiimbotImageTransferConfiguration: Equatable, Sendable {
    static let maximumFrames = 16
    static let maximumBytes = 256
    static let maximumPacingMilliseconds = 50

    let framesPerWrite: Int
    let byteLimit: Int
    let pacingMilliseconds: Int

    init(framesPerWrite: Int = 2, byteLimit: Int = 64, pacingMilliseconds: Int = 10) {
        self.framesPerWrite = min(Self.maximumFrames, max(1, framesPerWrite))
        self.byteLimit = min(Self.maximumBytes, max(20, byteLimit))
        self.pacingMilliseconds = min(Self.maximumPacingMilliseconds, max(0, pacingMilliseconds))
    }
}

/// Only this tuning namespace is written or reset. Existing printer, label,
/// inventory and diagnostic settings retain their own independent storage.
@MainActor @Observable final class NiimbotImageTransferPreferences {
    static let shared: NiimbotImageTransferPreferences = {
        let arguments = ProcessInfo.processInfo.arguments
        let token = arguments.first(where: { $0.hasPrefix("--show-transactions-fixture-id=") })
            .map { String($0.dropFirst("--show-transactions-fixture-id=".count)) }
        let fixture = arguments.contains("--show-transactions-ui-fixture")
            ? token.flatMap { UUID(uuidString: $0)?.uuidString } : nil
        let prefix = "niimbotAcknowledgedImageTransfer" + (fixture.map { ".fixture." + $0 } ?? "")
        return NiimbotImageTransferPreferences(defaults: .standard, keyPrefix: prefix)
    }()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String
    private var configuration: NiimbotImageTransferConfiguration

    init(defaults: UserDefaults = .standard, keyPrefix: String = "niimbotAcknowledgedImageTransfer") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        configuration = NiimbotImageTransferConfiguration(
            framesPerWrite: Self.readInteger(defaults, key: keyPrefix + ".framesPerWrite", fallback: 2),
            byteLimit: Self.readInteger(defaults, key: keyPrefix + ".byteLimit", fallback: 64),
            pacingMilliseconds: Self.readInteger(defaults, key: keyPrefix + ".pacingMilliseconds", fallback: 10))
    }

    var snapshot: NiimbotImageTransferConfiguration { configuration }

    var framesPerWrite: Int {
        get { configuration.framesPerWrite }
        set { update(framesPerWrite: newValue) }
    }

    var byteLimit: Int {
        get { configuration.byteLimit }
        set { update(byteLimit: newValue) }
    }

    var pacingMilliseconds: Int {
        get { configuration.pacingMilliseconds }
        set { update(pacingMilliseconds: newValue) }
    }

    func reset() {
        configuration = NiimbotImageTransferConfiguration()
        for suffix in ["framesPerWrite", "byteLimit", "pacingMilliseconds"] {
            defaults.removeObject(forKey: keyPrefix + "." + suffix)
        }
    }

    private static func readInteger(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              let integer = Int(value.stringValue), String(integer) == value.stringValue else { return fallback }
        return integer
    }

    private func update(framesPerWrite: Int? = nil, byteLimit: Int? = nil, pacingMilliseconds: Int? = nil) {
        let next = NiimbotImageTransferConfiguration(framesPerWrite: framesPerWrite ?? configuration.framesPerWrite,
            byteLimit: byteLimit ?? configuration.byteLimit,
            pacingMilliseconds: pacingMilliseconds ?? configuration.pacingMilliseconds)
        guard next != configuration else { return }
        configuration = next
        defaults.set(next.framesPerWrite, forKey: keyPrefix + ".framesPerWrite")
        defaults.set(next.byteLimit, forKey: keyPrefix + ".byteLimit")
        defaults.set(next.pacingMilliseconds, forKey: keyPrefix + ".pacingMilliseconds")
    }
}
