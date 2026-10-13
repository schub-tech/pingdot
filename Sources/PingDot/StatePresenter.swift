import Foundation

/// Turns a monitor state into the words shown to the user. Shared by the tooltip,
/// the menu, the popover and "Copy diagnostics", so they can never disagree.
enum StatePresenter {
    /// The popover passes `includeRTT: false` — there the latency is the big number.
    static func headline(for state: NetworkMonitor.State, includeRTT: Bool = true) -> String {
        if !state.linkUp { return "No network connection" }
        switch state.health {
        case .green:
            if includeRTT, let rtt = state.bestRTT { return "Internet OK — \(format(rtt))" }
            return "Internet OK"
        case .yellow:
            switch state.degradation {
            case .pingBlocked: return "Internet OK — ping is blocked here"
            case .dnsFailing: return "DNS is failing"
            case .webBlocked: return "Websites unreachable"
            case .none: return "Unstable — losing packets"
            }
        case .red:
            if let since = state.downSince {
                return "Internet down for \(duration(since: since))"
            }
            return "Internet down"
        case .unknown:
            return "Checking…"
        }
    }

    /// The line under the headline: either what is broken, or which single target
    /// is unhappy while the connection as a whole is fine.
    static func subtitle(for state: NetworkMonitor.State) -> String? {
        // The diagnostics verdicts assume a network to diagnose.
        if !state.linkUp { return "Wi‑Fi is off or the cable is unplugged" }

        switch state.degradation {
        case .pingBlocked: return "Switch Settings → Method to TCP connect"
        case .dnsFailing: return "Websites won't load, but ping gets through"
        case .webBlocked: return "Ping works, HTTPS doesn't — Wi‑Fi login page or firewall?"
        case .none: break
        }

        if state.health == .red {
            switch state.diagnostics.gatewayReachable {
            case false?: return "Router unreachable — check Wi‑Fi / cable"
            case true?: return "Router reachable, internet not — provider outage or Wi‑Fi login page?"
            case nil: break
            }
        }

        let unreachable = state.unreachableHosts
        if state.health == .green && !unreachable.isEmpty {
            return "\(unreachable.joined(separator: ", ")) unreachable — but you are online"
        }

        // A setup problem (bad hostname, no ICMP socket) is worth surfacing.
        if let error = state.hosts.compactMap(\.lastError).first,
           state.hosts.allSatisfy({ $0.recent.isEmpty }) {
            return error
        }
        return nil
    }

    static func format(_ rtt: TimeInterval) -> String {
        let ms = rtt * 1000
        return ms < 10 ? String(format: "%.1f ms", ms) : "\(Int(ms.rounded())) ms"
    }

    static func duration(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return String(format: "%d h %d min", seconds / 3600, (seconds % 3600) / 60)
    }
}
