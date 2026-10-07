import Foundation

/// Everything the user can tweak. Backed by UserDefaults so it survives restarts.
final class Settings {
    static let shared = Settings()

    enum ProbeMode: String {
        case icmp   // real ICMP echo, closest to `ping`
        case tcp    // TCP connect, works even where ICMP is filtered
    }

    private let defaults = UserDefaults.standard

    /// Offered in the menu. Anything else goes through "Custom…".
    static let suggestedHosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]

    private enum Key {
        static let hosts = "hosts"
        static let probeMode = "probeMode"
        static let interval = "intervalSeconds"
        static let timeout = "timeoutSeconds"
        static let greenWindow = "greenWindow"
        static let redStreak = "redStreak"
        static let showLatency = "showLatency"
        static let monochrome = "monochrome"
        static let checkForUpdates = "checkForUpdates"
    }

    private init() {
        defaults.register(defaults: [
            Key.hosts: ["1.1.1.1", "8.8.8.8"],
            Key.probeMode: ProbeMode.icmp.rawValue,
            Key.interval: 1.0,
            Key.timeout: 2.0,
            Key.greenWindow: 10,
            Key.redStreak: 3,
            Key.showLatency: false,
            Key.monochrome: false,
            Key.checkForUpdates: true,
        ])
    }

    /// Called when a change requires tearing down and rebuilding the probe.
    /// Purely cosmetic settings deliberately do not fire this — restarting would
    /// throw away the ping history for nothing.
    var onProbeChange: (() -> Void)?

    private func set(_ value: Any, _ key: String, restartProbe: Bool) {
        defaults.set(value, forKey: key)
        if restartProbe { onProbeChange?() }
    }

    /// Every target is pinged in parallel. Never empty — falling back to a single
    /// default beats a dot that measures nothing.
    var hosts: [String] {
        get {
            let stored = (defaults.array(forKey: Key.hosts) as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return stored.isEmpty ? ["1.1.1.1"] : stored
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            set(cleaned.isEmpty ? ["1.1.1.1"] : cleaned, Key.hosts, restartProbe: true)
        }
    }

    func toggleHost(_ host: String) {
        var current = hosts
        if let index = current.firstIndex(of: host) {
            guard current.count > 1 else { return }  // keep at least one target
            current.remove(at: index)
        } else {
            current.append(host)
        }
        hosts = current
    }

    var probeMode: ProbeMode {
        get { ProbeMode(rawValue: defaults.string(forKey: Key.probeMode) ?? "") ?? .icmp }
        set { set(newValue.rawValue, Key.probeMode, restartProbe: true) }
    }

    /// Seconds between two probes.
    var interval: TimeInterval {
        get { clamp(defaults.double(forKey: Key.interval), 0.25, 10) }
        set { set(newValue, Key.interval, restartProbe: true) }
    }

    /// How long a single probe may take before it counts as lost.
    var timeout: TimeInterval {
        get { clamp(defaults.double(forKey: Key.timeout), 0.25, 10) }
        set { set(newValue, Key.timeout, restartProbe: true) }
    }

    /// All of the last N probes must be good for green.
    var greenWindow: Int {
        get { Int(clamp(Double(defaults.integer(forKey: Key.greenWindow)), 1, 60)) }
        set { set(newValue, Key.greenWindow, restartProbe: false) }
    }

    /// This many consecutive losses turn the dot red.
    var redStreak: Int {
        get { Int(clamp(Double(defaults.integer(forKey: Key.redStreak)), 1, 30)) }
        set { set(newValue, Key.redStreak, restartProbe: false) }
    }

    /// Show the round-trip time next to the dot.
    var showLatency: Bool {
        get { defaults.bool(forKey: Key.showLatency) }
        set { set(newValue, Key.showLatency, restartProbe: false) }
    }

    /// Draw symbols instead of colours (colour-blind friendly, follows the menu bar tint).
    var monochrome: Bool {
        get { defaults.bool(forKey: Key.monochrome) }
        set { set(newValue, Key.monochrome, restartProbe: false) }
    }

    /// Daily look at GitHub for a newer release (GitHub / Homebrew build only).
    var checkForUpdates: Bool {
        get { defaults.bool(forKey: Key.checkForUpdates) }
        set { set(newValue, Key.checkForUpdates, restartProbe: false) }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isFinite ? Swift.min(Swift.max(v, lo), hi) : lo
    }
}
