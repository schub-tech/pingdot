import Foundation

/// Headless check of the probe path, reachable via `PingDot --selftest [host …]`.
/// Never returns — it exits the process when done.
enum SelfTest {
    static func run(hosts: [String], samples: Int = 5) -> Never {
        print("PingDot self-test → \(hosts.joined(separator: ", "))\n")

        var results: [String: Bool] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for host in hosts {
            for (method, probe) in [
                ("ICMP", ICMPPinger(host: host, interval: 0.5, timeout: 2) as Probe),
                ("TCP", TCPProbe(host: host, port: 443, interval: 0.5, timeout: 2) as Probe),
            ] {
                let label = "\(host) \(method)"
                group.enter()
                var seen = 0
                var good = 0
                var finished = false

                let finish: (Bool) -> Void = { ok in
                    guard !finished else { return }
                    finished = true
                    let stats = probe.debugStats
                    probe.stop()
                    if !stats.isEmpty { print("  \(label): \(stats)") }
                    lock.lock(); results[label] = ok; lock.unlock()
                    group.leave()
                }

                probe.onResult = { ok, rtt in
                    guard !finished else { return }
                    seen += 1
                    if ok { good += 1 }
                    let time = rtt.map { String(format: "%6.1f ms", $0 * 1000) } ?? "  timeout"
                    print("  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))"
                          + " #\(seen)  \(ok ? "ok  " : "LOST")  \(time)")
                    if seen == samples { finish(good > 0) }
                }
                probe.onFailure = { message in
                    print("  \(label): \(message)")
                    finish(false)
                }
                probe.start()
            }
        }

        group.notify(queue: .main) {
            print("\nSummary:")
            for label in results.keys.sorted() {
                print("  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))"
                      + " \(results[label] == true ? "works" : "no replies")")
            }
            exit(results.values.contains(true) ? 0 : 1)
        }

        // Probe callbacks land on the main queue, so we have to spin the runloop.
        RunLoop.main.run(until: Date().addingTimeInterval(20))
        print("self-test timed out")
        exit(2)
    }
}
