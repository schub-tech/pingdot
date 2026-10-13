#if DEBUG
import Foundation

/// `PINGDOT_FAKE_STATE=ok|warn|down` (debug builds only) replaces the monitor with
/// simulated states, to look at every state of the popover without breaking the
/// network. The numbers mirror docs/design/popover/mockup.html.
final class FakeFeed {
    enum Mode: String {
        case ok, warn, down
    }

    private let mode: Mode
    private let started = Date()
    private var histories: [[Sample]]
    private var timer: Timer?
    var onChange: ((NetworkMonitor.State) -> Void)?

    private static let hosts = ["1.1.1.1", "8.8.8.8"]
    private static let baselines: [Double] = [11, 14]

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let mode = environment["PINGDOT_FAKE_STATE"].flatMap(Mode.init) else { return nil }
        self.mode = mode
        histories = Self.baselines.map { base in (0..<60).map { _ in Self.sample(mode, base: base) } }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for index in self.histories.indices {
                self.histories[index].append(Self.sample(self.mode, base: Self.baselines[index]))
                self.histories[index].removeFirst()
            }
            self.onChange?(self.state)
        }
    }

    var state: NetworkMonitor.State {
        var state = NetworkMonitor.State()
        state.hosts = zip(Self.hosts, histories).map { host, history in
            var entry = HostState(host: host, recent: history)
            entry.lastRTT = history.last(where: \.ok)?.rtt
            entry.health = [.ok: Health.green, .warn: .yellow, .down: .red][mode]!
            return entry
        }
        state.interfaceName = "en0"
        state.diagnostics.gatewayAddress = "192.168.1.1"
        switch mode {
        case .ok:
            state.health = .green
            state.diagnostics.gatewayReachable = true
            state.diagnostics.gatewayRTT = 0.002
            state.diagnostics.dnsWorking = true
            state.diagnostics.tlsReachable = true
        case .warn:
            state.health = .yellow
            state.degradation = .dnsFailing
            state.diagnostics.gatewayReachable = true
            state.diagnostics.gatewayRTT = 0.003
            state.diagnostics.dnsWorking = false
            state.diagnostics.tlsReachable = true
        case .down:
            state.health = .red
            state.linkUp = false
            state.interfaceName = nil
            state.diagnostics.gatewayReachable = false
            state.downSince = started.addingTimeInterval(-12)
        }
        return state
    }

    private static func sample(_ mode: Mode, base: Double) -> Sample {
        switch mode {
        case .down:
            return Sample(ok: false, rtt: nil)
        case .warn:
            if Double.random(in: 0..<1) < 0.28 { return Sample(ok: false, rtt: nil) }
            return Sample(ok: true, rtt: Double.random(in: 40..<180).rounded() / 1000)
        case .ok:
            var value = base + Double.random(in: 0..<6)
            if Double.random(in: 0..<1) < 0.07 { value += Double.random(in: 10..<22) }
            return Sample(ok: true, rtt: value.rounded() / 1000)
        }
    }
}
#endif
