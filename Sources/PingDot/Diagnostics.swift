import Darwin
import Foundation
import Network

/// The slow, cheap side checks that answer "and *where* is it broken?".
///
/// These never drive the dot colour — they only fill the menu, so a hiccup here
/// can never make the main indicator lie.
final class Diagnostics {
    struct Snapshot {
        var gatewayAddress: String?
        var gatewayReachable: Bool?
        /// `false` only after two failed rounds in a row — right after (re)joining a
        /// network the first lookup often fails before DHCP/DNS have settled.
        var dnsWorking: Bool?
        var tlsReachable: Bool?
    }

    private(set) var snapshot = Snapshot()
    var onUpdate: ((Snapshot) -> Void)?

    private let queue = DispatchQueue(label: "tech.schub.pingdot.diagnostics")
    private var timer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()

    /// Kept alive between rounds so we do not rebuild the socket every 10 s.
    private var gatewayPinger: ICMPPinger?
    private var gatewayResultPending = false
    /// Only touched on `queue`. Without a usable path the DNS answer may come from
    /// the resolver cache, so the checks pause instead of showing a stale ✓.
    private var pathSatisfied = true
    private var dnsFailStreak = 0
    private var tlsFailStreak = 0
    private var recheckPending = false

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let gateway = path.gateways.compactMap(Self.ipv4String).first
            let satisfied = path.status == .satisfied
            self.pathSatisfied = satisfied
            self.dnsFailStreak = 0
            self.tlsFailStreak = 0
            DispatchQueue.main.async {
                self.setGateway(gateway)
                if !satisfied {
                    self.snapshot.dnsWorking = nil
                    self.snapshot.tlsReachable = nil
                    self.publish()
                }
            }
            // The network just changed — answer "where is it broken?" now, not in 10 s.
            if satisfied { self.runRound() }
        }
        pathMonitor.start(queue: queue)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.runRound() }
        timer = t
        t.resume()
    }

    /// Run a round now — called when the pings just went down, so the verdict
    /// ("router fine, internet not") does not wait for the 10 s timer.
    func refresh() {
        queue.async { [weak self] in self?.runRound() }
    }

    func stop() {
        pathMonitor.cancel()
        timer?.cancel()
        timer = nil
        gatewayPinger?.stop()
        gatewayPinger = nil
    }

    // MARK: - Gateway

    private func setGateway(_ address: String?) {
        guard address != snapshot.gatewayAddress else { return }
        snapshot.gatewayAddress = address
        snapshot.gatewayReachable = nil
        gatewayPinger?.stop()
        gatewayPinger = nil

        if let address {
            let pinger = ICMPPinger(host: address, interval: 5, timeout: 1.5)
            // Ignore answers still queued from the previous router's pinger.
            pinger.onResult = { [weak self, weak pinger] ok, _ in
                guard let self, let pinger, self.gatewayPinger === pinger else { return }
                self.snapshot.gatewayReachable = ok
                self.publish()
            }
            pinger.onFailure = { [weak self, weak pinger] _ in
                guard let self, let pinger, self.gatewayPinger === pinger else { return }
                self.snapshot.gatewayReachable = nil
                self.publish()
            }
            gatewayPinger = pinger
            pinger.start()
        }
        publish()
    }

    private static func ipv4String(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        if case let .ipv4(address) = host {
            return address.debugDescription.split(separator: "%").first.map(String.init)
        }
        return nil
    }

    // MARK: - DNS + reachability

    private func runRound() {
        guard pathSatisfied else { return }
        let dnsOK = Self.canResolve("www.apple.com", timeout: 4)
        guard pathSatisfied else { return }   // network went away while we waited
        dnsFailStreak = dnsOK ? 0 : dnsFailStreak + 1
        if dnsOK || dnsFailStreak >= 2 {
            DispatchQueue.main.async { [weak self] in
                self?.snapshot.dnsWorking = dnsOK
                self?.publish()
            }
        } else {
            recheckSoon()
        }
        checkTLSReachability()
    }

    /// Confirm a first failure after 3 s instead of the regular 10 s.
    private func recheckSoon() {
        guard !recheckPending else { return }
        recheckPending = true
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.recheckPending = false
            self?.runRound()
        }
    }

    /// `getaddrinfo` can block for a long time, so it runs on its own thread and we
    /// treat "did not answer in time" as a failure.
    private static func canResolve(_ host: String, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Atomic(false)
        Thread.detachNewThread {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, "443", &hints, &info) == 0 {
                result.value = true
                freeaddrinfo(info)
            }
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success && result.value
    }

    private func checkTLSReachability() {
        // A full TLS handshake, not just TCP: captive portals happily accept TCP on
        // 443 to serve their login page, but none can present a valid certificate
        // for www.apple.com. So this only succeeds when the real internet is there.
        let connection = NWConnection(host: "www.apple.com", port: 443, using: .tls)
        var settled = false
        // Runs on `queue` (state handler and the timeout below).
        let finish: (Bool) -> Void = { [weak self] ok in
            guard !settled else { return }
            settled = true
            connection.cancel()
            guard let self, self.pathSatisfied else { return }
            self.tlsFailStreak = ok ? 0 : self.tlsFailStreak + 1
            guard ok || self.tlsFailStreak >= 2 else { return self.recheckSoon() }
            DispatchQueue.main.async {
                self.snapshot.tlsReachable = ok
                self.publish()
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(false) }
    }

    private func publish() {
        let snapshot = self.snapshot
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }
}

/// Minimal box so the resolver thread and the waiter can share one flag.
private final class Atomic<T> {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
