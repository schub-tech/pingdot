import Foundation
import Network

/// Fallback probe: time a TCP handshake instead of an ICMP round trip.
///
/// Slower and heavier than ICMP (a fresh connection per probe), but it works on
/// networks that filter ICMP, on IPv6-only networks, and inside the App Sandbox
/// with nothing but the `network.client` entitlement.
final class TCPProbe: Probe {
    private let queue = DispatchQueue(label: "tech.schub.pingdot.tcp")
    private let endpointHost: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let interval: TimeInterval
    private let timeout: TimeInterval

    private var timer: DispatchSourceTimer?
    private var inFlight: [ObjectIdentifier: NWConnection] = [:]

    var onResult: ((Bool, TimeInterval?) -> Void)?
    var onFailure: ((String) -> Void)?
    var debugStats: String { "" }

    init(host: String, port: UInt16 = 443, interval: TimeInterval, timeout: TimeInterval) {
        self.endpointHost = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 443
        self.interval = interval
        self.timeout = timeout
    }

    // Not `stop()` — see `ICMPPinger.deinit`.
    deinit { tearDown() }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.connectOnce() }
        timer = t
        t.resume()
    }

    func stop() {
        queue.sync { tearDown() }
    }

    private func tearDown() {
        timer?.cancel()
        timer = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func connectOnce() {
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout.rounded(.up))
        options.noDelay = true
        let connection = NWConnection(host: endpointHost, port: port,
                                      using: NWParameters(tls: nil, tcp: options))
        let key = ObjectIdentifier(connection)
        inFlight[key] = connection

        let started = DispatchTime.now()
        var settled = false

        let finish: (Bool) -> Void = { [weak self] success in
            guard let self, !settled else { return }
            settled = true
            let rtt = success
                ? Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
                : nil
            self.inFlight.removeValue(forKey: key)?.cancel()
            DispatchQueue.main.async { self.onResult?(success, rtt) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}
