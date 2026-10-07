import Foundation
import Network

enum Health {
    case unknown   // not enough data yet
    case green     // everything fine
    case yellow    // losing packets
    case red       // down
}

/// Why the dot is yellow although the pings alone would say otherwise.
enum Degradation {
    case none
    case pingBlocked   // no ping ever answered on this network, but HTTPS works
    case dnsFailing    // pings fine, name lookups fail
    case webBlocked    // pings fine, HTTPS does not connect (login page, firewall)
}

struct Sample {
    let ok: Bool
    let rtt: TimeInterval?
}

struct Stats {
    var lossPercent: Double
    var average: TimeInterval?
    var minimum: TimeInterval?
    var maximum: TimeInterval?
    var count: Int
}

/// One target being pinged: its own probe, its own history, its own verdict.
struct HostState {
    var host: String
    var recent: [Sample] = []
    var lastRTT: TimeInterval?
    var lastError: String?
    var health: Health = .unknown

    func stats(over count: Int = 60) -> Stats {
        let samples = Array(recent.suffix(count))
        guard !samples.isEmpty else {
            return Stats(lossPercent: 0, average: nil, minimum: nil, maximum: nil, count: 0)
        }
        let lost = samples.filter { !$0.ok }.count
        let times = samples.compactMap(\.rtt)
        return Stats(
            lossPercent: Double(lost) / Double(samples.count) * 100,
            average: times.isEmpty ? nil : times.reduce(0, +) / Double(times.count),
            minimum: times.min(),
            maximum: times.max(),
            count: samples.count
        )
    }
}

/// Owns one probe per target, the rolling histories and the resulting traffic light.
///
/// Several targets exist so a single provider having a bad day cannot make the dot
/// lie about *your* connection: the light only goes red once every target is gone.
final class NetworkMonitor {
    struct State {
        var health: Health = .unknown        // combined verdict — this drives the dot
        var hosts: [HostState] = []
        var linkUp = true
        var interfaceName: String?
        var diagnostics = Diagnostics.Snapshot()
        var degradation = Degradation.none
        var downSince: Date?

        /// Fastest answer across all targets, for the optional menu bar number.
        var bestRTT: TimeInterval? {
            hosts.compactMap(\.lastRTT).min()
        }

        /// Targets that are down while the connection as a whole is fine.
        var unreachableHosts: [String] {
            hosts.filter { $0.health == .red }.map(\.host)
        }
    }

    private static let historyLimit = 120

    private(set) var state = State()
    var onChange: ((State) -> Void)?

    private var probes: [Probe] = []
    /// Bumped on every restart. Results already queued by a stopped probe carry
    /// the old value and are dropped — they would otherwise land in the slot of
    /// whichever new target now sits at the same index.
    private var generation = 0
    private let diagnostics = Diagnostics()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "tech.schub.pingdot.path")

    // MARK: - Lifecycle

    func start() {
        // Link state is the one signal that is instant: pull the cable or drop Wi‑Fi
        // and we go red without waiting for a single timeout.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.linkUp = path.status == .satisfied
                // Prefer Wi‑Fi / Ethernet over VPN tunnels (utun…), which show up as `.other`.
                let interfaces = path.availableInterfaces
                self.state.interfaceName = (interfaces.first { $0.type != .other } ?? interfaces.first)?.name
                if !self.state.linkUp {
                    for index in self.state.hosts.indices {
                        self.state.hosts[index].recent.removeAll()
                    }
                }
                self.recompute()
            }
        }
        pathMonitor.start(queue: pathQueue)

        diagnostics.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            self.state.diagnostics = snapshot
            self.recompute()   // DNS / HTTPS results can change the colour
        }
        diagnostics.start()

        restartProbes()

        Settings.shared.onProbeChange = { [weak self] in self?.restartProbes() }
    }

    func stop() {
        probes.forEach { $0.stop() }
        probes.removeAll()
        diagnostics.stop()
        pathMonitor.cancel()
    }

    /// Internal probe counters per target, in `state.hosts` order.
    func probeDebugStats() -> [String] {
        probes.map(\.debugStats)
    }

    /// Tear down and rebuild every probe — after a settings change, or on demand.
    func restartProbes() {
        probes.forEach { $0.stop() }
        probes.removeAll()
        generation += 1
        let current = generation

        let settings = Settings.shared
        state.hosts = settings.hosts.map { HostState(host: $0) }

        for (index, host) in settings.hosts.enumerated() {
            let probe: Probe = settings.probeMode == .icmp
                ? ICMPPinger(host: host, interval: settings.interval, timeout: settings.timeout)
                : TCPProbe(host: host, interval: settings.interval, timeout: settings.timeout)

            probe.onResult = { [weak self] ok, rtt in
                guard let self, self.generation == current else { return }
                self.record(ok: ok, rtt: rtt, at: index)
            }
            probe.onFailure = { [weak self] message in
                guard let self, self.generation == current,
                      self.state.hosts.indices.contains(index) else { return }
                self.state.hosts[index].lastError = message
                self.recompute()
            }
            probes.append(probe)
            probe.start()
        }

        recompute()
    }

    // MARK: - State machine

    private func record(ok: Bool, rtt: TimeInterval?, at index: Int) {
        guard state.hosts.indices.contains(index) else { return }

        state.hosts[index].recent.append(Sample(ok: ok, rtt: rtt))
        let overflow = state.hosts[index].recent.count - Self.historyLimit
        if overflow > 0 { state.hosts[index].recent.removeFirst(overflow) }
        if ok {
            state.hosts[index].lastRTT = rtt
            // A reply means any earlier setup problem (e.g. DNS) has sorted itself out.
            state.hosts[index].lastError = nil
        }
        recompute()
    }

    private func recompute() {
        for index in state.hosts.indices {
            state.hosts[index].health = health(for: state.hosts[index])
        }

        let previous = state.health
        (state.health, state.degradation) = adjustedForDiagnostics(combinedHealth())

        if state.health == .red, previous != .red {
            state.downSince = Date()
            diagnostics.refresh()   // explain *where* it broke without waiting 10 s
        } else if state.health != .red {
            state.downSince = nil
        }

        onChange?(state)
    }

    /// The pings answer "do packets get out?", the diagnostics "do websites work?".
    /// Where they disagree, yellow is the honest colour.
    private func adjustedForDiagnostics(_ health: Health) -> (Health, Degradation) {
        guard state.linkUp else { return (health, .none) }
        let diagnostics = state.diagnostics

        // Office networks often drop ICMP. If not a single ping has ever answered
        // on this network (history is cleared on every link change) while HTTPS
        // works, the internet is fine — red would be a false alarm. A real outage
        // has older successful pings in the history and stays red.
        if health == .red, diagnostics.tlsReachable == true,
           state.hosts.allSatisfy({ !$0.recent.contains(where: \.ok) }) {
            return (.yellow, .pingBlocked)
        }
        if health == .green, diagnostics.dnsWorking == false { return (.yellow, .dnsFailing) }
        if health == .green, diagnostics.tlsReachable == false { return (.yellow, .webBlocked) }
        return (health, .none)
    }

    /// The dot: green as soon as *any* target looks healthy, red only once they all
    /// stopped answering. One unreachable DNS provider is not an internet outage.
    private func combinedHealth() -> Health {
        if !state.linkUp { return .red }

        let healths = state.hosts.map(\.health)
        guard !healths.isEmpty else { return .unknown }
        if healths.contains(.green) { return .green }
        if healths.allSatisfy({ $0 == .unknown }) { return .unknown }
        if healths.allSatisfy({ $0 == .red || $0 == .unknown }) { return .red }
        return .yellow
    }

    private func health(for host: HostState) -> Health {
        if !state.linkUp { return .red }
        if host.lastError != nil && host.recent.isEmpty { return .unknown }

        let settings = Settings.shared
        let samples = host.recent
        guard !samples.isEmpty else { return .unknown }

        // Rule 1: N losses back to back means this target is gone.
        let tail = samples.suffix(settings.redStreak)
        if tail.count == settings.redStreak && tail.allSatisfy({ !$0.ok }) { return .red }

        // Rule 2: the last N probes all good means fine. During the first seconds
        // after launch we accept a shorter run (min. 3) so the dot does not sit on
        // yellow for ten seconds on a perfectly healthy connection.
        let window = samples.suffix(settings.greenWindow)
        if window.count >= min(settings.greenWindow, 3) && window.allSatisfy({ $0.ok }) {
            return .green
        }

        return .yellow
    }
}
