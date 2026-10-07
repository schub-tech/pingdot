import Darwin
import Foundation

/// A long-lived ICMP echo pinger.
///
/// Uses an unprivileged ICMP datagram socket (`SOCK_DGRAM`/`IPPROTO_ICMP`), the same
/// trick Apple's SimplePing uses — no root, no `setuid`, no subprocess per ping.
/// One socket stays open for the lifetime of the pinger, so a probe costs a single
/// `sendto` and the reply arrives on a dispatch read source. That is what keeps the
/// dot responsive: no process spawn, no parsing, no polling.
///
/// IPv4 only. For IPv6-only networks (or networks that drop ICMP) use `TCPProbe`.
final class ICMPPinger: Probe {
    private let queue = DispatchQueue(label: "tech.schub.pingdot.icmp")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?

    private var sequence: UInt16 = 0
    private var pending: [UInt16: DispatchTime] = [:]
    private var isStopped = false
    private var isResolving = false

    /// Random per-pinger token echoed back in the payload. Lets us ignore replies
    /// that belong to another socket (or another app) without relying on the ICMP
    /// identifier (an unbound datagram ICMP socket receives every echo reply that
    /// reaches the host).
    private let token: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }

    /// ICMP identifier. The kernel does *not* rewrite it on Darwin datagram ICMP
    /// sockets, so whatever we put here goes on the wire. It must be non-zero:
    /// NATs treat the identifier like a port, and some (iPhone Personal Hotspot,
    /// carrier NAT64) drop or mis-map echo requests with identifier 0 — the
    /// classic symptom being "PingDot says 100 % loss while `ping` works". Use the
    /// PID like `ping` does, with a random fallback so it can never be 0.
    private let identifier: UInt16 = {
        let pid = UInt16(truncatingIfNeeded: getpid())
        return pid != 0 ? pid : UInt16.random(in: 1...UInt16.max)
    }()

    private let host: String
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private var address = sockaddr_in()

    /// Hostnames get looked up again every so often — a DHCP lease or a DNS change
    /// can move `fritz.box` or a company proxy to a new address.
    private let isLiteralAddress: Bool
    private static let reresolveInterval: TimeInterval = 60
    private static let retryResolveInterval: TimeInterval = 5

    /// Counters for "Copy diagnostics". An unbound datagram ICMP socket receives
    /// *every* echo reply that reaches this host, so `received` vs. `matched`
    /// tells apart "replies never arrive" (network/NAT) from "replies arrive but
    /// we drop them" (a bug in here) — see `debugStats`.
    private var sentCount = 0
    private var sendErrorCount = 0
    private var lastSendError: String?
    private var receivedCount = 0       // datagrams read from the socket
    private var ignoredTypeCount = 0    // not an echo reply / too short
    private var lastIgnored: String?    // "type/code/len" of the last such packet
    private var foreignCount = 0        // echo reply, but someone else's token
    private var lateCount = 0           // our token, but sequence already timed out
    private var matchedCount = 0

    var debugStats: String {
        queue.sync {
            var parts = ["sent \(sentCount)"]
            if sendErrorCount > 0 {
                parts.append("send errors \(sendErrorCount) (last: \(lastSendError ?? "?"))")
            }
            parts.append("rx \(receivedCount)")
            parts.append("matched \(matchedCount)")
            if foreignCount > 0 { parts.append("foreign \(foreignCount)") }
            if lateCount > 0 { parts.append("late \(lateCount)") }
            if ignoredTypeCount > 0 {
                parts.append("other-type \(ignoredTypeCount) (last: \(lastIgnored ?? "?"))")
            }
            return "id \(identifier), " + parts.joined(separator: ", ")
        }
    }

    /// `(success, roundTripTime)` — delivered on the main queue.
    var onResult: ((Bool, TimeInterval?) -> Void)?
    /// Fatal setup problem (bad host, socket refused). Delivered on the main queue.
    var onFailure: ((String) -> Void)?

    init(host: String, interval: TimeInterval, timeout: TimeInterval) {
        self.host = host
        self.interval = interval
        self.timeout = timeout
        var probe = in_addr()
        self.isLiteralAddress = inet_pton(AF_INET, host, &probe) == 1
    }

    // Not `stop()`: the last reference can be dropped by a block running on `queue`
    // itself, and a `queue.sync` from there traps. Nothing else can touch the
    // state any more at this point, so tearing down directly is safe.
    deinit { tearDown() }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.resolve() }
    }

    func stop() {
        queue.sync { tearDown() }
    }

    private func tearDown() {
        isStopped = true
        timer?.cancel()
        timer = nil
        pending.removeAll()

        if let source = readSource {
            // The source's cancel handler owns the fd — don't close it twice.
            readSource = nil
            source.cancel()
            fd = -1
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// `getaddrinfo` can block for half a minute when DNS is down, so it never runs
    /// on `queue` — otherwise `stop()` (called from the main thread on every
    /// settings change) would wait for it and freeze the menu.
    private func resolve() {
        guard !isStopped, !isResolving else { return }
        isResolving = true
        let host = self.host
        let queue = self.queue
        DispatchQueue.global(qos: .utility).async {
            let resolved = Self.resolveIPv4(host)
            queue.async { [weak self] in self?.didResolve(resolved) }
        }
    }

    private func didResolve(_ resolved: sockaddr_in?) {
        isResolving = false
        guard !isStopped else { return }

        guard let resolved else {
            // Keep pinging the last known address if there is one; either way try
            // again soon, so a target added while DNS was down comes back by itself.
            if fd < 0 { report(failure: "Cannot resolve “\(host)”") }
            scheduleResolve(after: Self.retryResolveInterval)
            return
        }

        address = resolved
        if fd < 0 { openSocket() }
        if !isLiteralAddress { scheduleResolve(after: Self.reresolveInterval) }
    }

    private func scheduleResolve(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.resolve() }
    }

    private func openSocket() {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socketFD >= 0 else {
            report(failure: "ICMP socket unavailable (\(String(cString: strerror(errno)))) — switch to TCP mode")
            return
        }
        fd = socketFD

        // Non-blocking: the read source tells us when data is there, we never want
        // recvfrom to park the queue.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainSocket() }
        source.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        readSource = source
        source.resume()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.sendOne() }
        timer = t
        t.resume()
    }

    // MARK: - Sending

    private func sendOne() {
        guard fd >= 0 else { return }
        sequence &+= 1
        let seq = sequence
        let packet = makeEchoRequest(sequence: seq)

        pending[seq] = .now()

        let sent: Int = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &address) { addrPtr -> Int in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sent < 0 {
            // No route to host, interface down, … — that is a loss, not a crash.
            sendErrorCount += 1
            lastSendError = "\(String(cString: strerror(errno))) [\(errno)]"
            pending.removeValue(forKey: seq)
            report(success: false, rtt: nil)
            return
        }
        sentCount += 1

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.pending.removeValue(forKey: seq) != nil else { return }
            self.report(success: false, rtt: nil)
        }
    }

    private func makeEchoRequest(sequence: UInt16) -> Data {
        var packet = Data(capacity: 8 + 32)
        packet.append(8)            // type: echo request
        packet.append(0)            // code
        packet.append(contentsOf: [0, 0]) // checksum placeholder
        packet.append(UInt8(identifier >> 8))   // identifier — must be non-zero
        packet.append(UInt8(identifier & 0xFF))
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xFF))
        packet.append(contentsOf: token)
        packet.append(contentsOf: (UInt8(token.count)..<32).map { $0 }) // filler

        let sum = Self.checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    // MARK: - Receiving

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { fromPtr -> Int in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            if n <= 0 { return }  // EAGAIN — nothing left to read
            receivedCount += 1
            handle(bytes: Array(buffer[0..<n]))
        }
    }

    private func handle(bytes: [UInt8]) {
        // Darwin hands us the IP header even on datagram ICMP sockets, so skip it
        // when it is there.
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 0x0F) * 4
        }
        guard bytes.count >= offset + 8 + token.count, bytes[offset] == 0 else {
            ignoredTypeCount += 1   // not an echo reply (0), or truncated
            let type = bytes.count > offset ? "\(bytes[offset])" : "?"
            let code = bytes.count > offset + 1 ? "\(bytes[offset + 1])" : "?"
            lastIgnored = "type \(type) code \(code) len \(bytes.count)"
            return
        }

        let seq = UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        let payload = Array(bytes[(offset + 8)..<(offset + 8 + token.count)])
        guard payload == token else {
            foreignCount += 1       // another pinger's / another app's reply
            return
        }

        guard let sentAt = pending.removeValue(forKey: seq) else {
            lateCount += 1          // already timed out, or a duplicate
            return
        }
        matchedCount += 1
        let rtt = Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1e9
        report(success: true, rtt: rtt)
    }

    // MARK: - Helpers

    private func report(success: Bool, rtt: TimeInterval?) {
        DispatchQueue.main.async { [weak self] in self?.onResult?(success, rtt) }
    }

    private func report(failure: String) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(failure) }
    }

    private static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = data.startIndex
        while index < data.endIndex - 1 {
            sum += UInt32(UInt16(data[index]) << 8 | UInt16(data[index + 1]))
            index += 2
        }
        if index < data.endIndex {
            sum += UInt32(UInt16(data[index]) << 8)
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    static func resolveIPv4(_ host: String) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        // Literal address? Then we are done without touching DNS.
        if inet_pton(AF_INET, host, &addr.sin_addr) == 1 { return addr }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        guard let sa = first.pointee.ai_addr else { return nil }
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr.sin_addr = $0.pointee.sin_addr }
        return addr
    }
}
