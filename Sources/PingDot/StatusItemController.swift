import AppKit
import ServiceManagement

/// The menu bar item: the dot itself plus the drop-down with the details.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = NetworkMonitor()
    private let menu = NSMenu()

    // Kept around so an open menu can be refreshed in place instead of rebuilt —
    // swapping items out from under an open menu makes it flicker.
    private var menuIsOpen = false
    private weak var headerItem: NSMenuItem?
    private weak var subtitleItem: NSMenuItem?
    private var hostRowItems: [(spark: NSMenuItem, stats: NSMenuItem)] = []
    private var diagnosticItems: [NSMenuItem] = []
    #if !APP_STORE
    private let updates = UpdateChecker()
    #endif

    func install() {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        menu.delegate = self
        statusItem.menu = menu

        monitor.onChange = { [weak self] state in self?.render(state) }
        monitor.start()
        render(monitor.state)

        #if !APP_STORE
        // The menu is rebuilt on every open, so the next open shows the line.
        updates.start()
        #endif
    }

    // MARK: - Menu bar button

    private func render(_ state: NetworkMonitor.State) {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(for: state.health, monochrome: Settings.shared.monochrome)

        if Settings.shared.showLatency, state.health != .red, let rtt = state.bestRTT {
            button.title = " \(Int((rtt * 1000).rounded())) ms"
        } else {
            button.title = ""
        }

        button.toolTip = [headline(for: state), subtitle(for: state)]
            .compactMap { $0 }
            .joined(separator: " — ")

        if menuIsOpen { refreshLiveItems(state) }
    }

    /// Update the handful of items that change every second while the menu is open.
    private func refreshLiveItems(_ state: NetworkMonitor.State) {
        headerItem?.title = headline(for: state)
        headerItem?.image = StatusIcon.image(for: state.health, monochrome: Settings.shared.monochrome)
        let sub = subtitle(for: state) ?? ""
        subtitleItem?.attributedTitle = secondaryText(sub)
        subtitleItem?.isHidden = sub.isEmpty

        let checks = diagnosticChecks(state)
        if diagnosticItems.count == checks.count {
            for (item, fresh) in zip(diagnosticItems, checks) {
                item.attributedTitle = fresh.attributedTitle
            }
        }

        guard hostRowItems.count == state.hosts.count else { return }
        for (index, host) in state.hosts.enumerated() {
            hostRowItems[index].spark.attributedTitle = hostSparkline(host)
            hostRowItems[index].stats.attributedTitle = secondaryText(statsLine(host))
        }
    }

    private func headline(for state: NetworkMonitor.State) -> String {
        if !state.linkUp { return "No network connection" }
        switch state.health {
        case .green:
            if let rtt = state.bestRTT { return "Internet OK — \(format(rtt))" }
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
    private func subtitle(for state: NetworkMonitor.State) -> String? {
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

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }  // submenus rebuild with the root
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = false }
    }

    private func rebuildMenu() {
        let state = monitor.state
        let settings = Settings.shared
        menu.removeAllItems()
        hostRowItems.removeAll()

        // Headline with the dot repeated, so the state is obvious once the menu
        // covers the icon.
        let header = NSMenuItem(title: headline(for: state), action: nil, keyEquivalent: "")
        header.image = StatusIcon.image(for: state.health, monochrome: settings.monochrome)
        header.isEnabled = false
        menu.addItem(header)
        headerItem = header

        let subText = subtitle(for: state) ?? ""
        let sub = disabled(subText, secondary: true)
        sub.isHidden = subText.isEmpty
        menu.addItem(sub)
        subtitleItem = sub

        #if !APP_STORE
        if let version = updates.availableVersion {
            menu.addItem(item("Update available: PingDot \(version)…", #selector(openReleasePage)))
        }
        #endif

        menu.addItem(.separator())

        // One block per target.
        for host in state.hosts {
            let spark = NSMenuItem()
            spark.attributedTitle = hostSparkline(host)
            spark.isEnabled = false
            menu.addItem(spark)

            let stats = disabled(statsLine(host), secondary: true)
            menu.addItem(stats)

            hostRowItems.append((spark, stats))
        }

        menu.addItem(.separator())

        // Where is it broken?
        menu.addItem(disabled("Diagnostics", secondary: true))
        diagnosticItems = diagnosticChecks(state)
        diagnosticItems.forEach(menu.addItem)

        menu.addItem(.separator())
        menu.addItem(item("Copy diagnostics", #selector(copyDiagnostics)))
        menu.addItem(item("Restart monitoring", #selector(restart)))

        menu.addItem(.separator())
        menu.addItem(settingsMenu(settings))

        menu.addItem(.separator())
        menu.addItem(item("About PingDot", #selector(showAbout)))
        menu.addItem(NSMenuItem(title: "Quit PingDot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func settingsMenu(_ settings: Settings) -> NSMenuItem {
        let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        // Targets — several can be active at once.
        let hostItem = NSMenuItem(title: "Targets", action: nil, keyEquivalent: "")
        let hostMenu = NSMenu()
        let active = settings.hosts
        for host in Settings.suggestedHosts {
            let entry = item(host, #selector(toggleHost(_:)))
            entry.representedObject = host
            entry.state = active.contains(host) ? .on : .off
            hostMenu.addItem(entry)
        }
        // Anything the user typed in that is not one of the suggestions.
        for host in active where !Settings.suggestedHosts.contains(host) {
            let entry = item(host, #selector(toggleHost(_:)))
            entry.representedObject = host
            entry.state = .on
            hostMenu.addItem(entry)
        }
        hostMenu.addItem(.separator())
        hostMenu.addItem(item("Add target…", #selector(addCustomHost)))
        hostItem.submenu = hostMenu
        submenu.addItem(hostItem)

        // Probe interval
        let intervalItem = NSMenuItem(title: "Check every", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for seconds in [0.5, 1.0, 2.0, 5.0] {
            let entry = item(seconds < 1 ? "\(Int(seconds * 1000)) ms" : "\(Int(seconds)) s",
                             #selector(pickInterval(_:)))
            entry.representedObject = seconds
            entry.state = abs(settings.interval - seconds) < 0.01 ? .on : .off
            intervalMenu.addItem(entry)
        }
        intervalItem.submenu = intervalMenu
        submenu.addItem(intervalItem)

        // Probe method
        let methodItem = NSMenuItem(title: "Method", action: nil, keyEquivalent: "")
        let methodMenu = NSMenu()
        for (title, mode) in [("ICMP ping", Settings.ProbeMode.icmp), ("TCP connect", .tcp)] {
            let entry = item(title, #selector(pickMode(_:)))
            entry.representedObject = mode.rawValue
            entry.state = settings.probeMode == mode ? .on : .off
            methodMenu.addItem(entry)
        }
        methodItem.submenu = methodMenu
        submenu.addItem(methodItem)

        submenu.addItem(.separator())

        let latency = item("Show latency in menu bar", #selector(toggleLatency))
        latency.state = settings.showLatency ? .on : .off
        submenu.addItem(latency)

        let mono = item("Use symbols instead of colours", #selector(toggleMonochrome))
        mono.state = settings.monochrome ? .on : .off
        submenu.addItem(mono)

        let login = item("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu.addItem(login)

        #if !APP_STORE
        let updateCheck = item("Check for updates", #selector(toggleUpdateCheck))
        updateCheck.state = settings.checkForUpdates ? .on : .off
        submenu.addItem(updateCheck)
        #endif

        root.submenu = submenu
        return root
    }

    // MARK: - Rendering helpers

    /// The four "where is it broken?" rows — rebuilt on every update so an open
    /// menu never shows a stale ✓.
    private func diagnosticChecks(_ state: NetworkMonitor.State) -> [NSMenuItem] {
        let diagnostics = state.diagnostics
        return [
            check("Network interface", detail: state.linkUp ? state.interfaceName : nil, ok: state.linkUp),
            check("Router", detail: diagnostics.gatewayAddress, ok: diagnostics.gatewayReachable),
            check("DNS", detail: nil, ok: diagnostics.dnsWorking),
            check("HTTPS", detail: "www.apple.com", ok: diagnostics.tlsReachable),
        ]
    }

    /// `1.1.1.1   ●●●●●●●●○●` — target name plus its own history.
    private func hostSparkline(_ host: HostState) -> NSAttributedString {
        let line = NSMutableAttributedString(string: host.host.padding(toLength: max(host.host.count, 9),
                                                                      withPad: " ", startingAt: 0) + "  ",
                                             attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: host.health == .red ? NSColor.systemRed : NSColor.labelColor,
        ])
        line.append(StatusIcon.sparkline(host.recent, limit: 16))
        return line
    }

    private func statsLine(_ host: HostState) -> String {
        let stats = host.stats()
        guard stats.count > 0 else { return "           waiting for first reply…" }
        var parts: [String] = []
        if let average = stats.average { parts.append("avg \(format(average))") }
        if let minimum = stats.minimum, let maximum = stats.maximum {
            parts.append("min \(format(minimum)) / max \(format(maximum))")
        }
        parts.append(String(format: "loss %.0f%%", stats.lossPercent))
        return "           " + parts.joined(separator: "  ·  ")
    }

    // MARK: - Menu item factories

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func disabled(_ title: String, secondary: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        if secondary { entry.attributedTitle = secondaryText(title) }
        return entry
    }

    private func secondaryText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// `ok == nil` means "not measured yet".
    private func check(_ title: String, detail: String?, ok: Bool?) -> NSMenuItem {
        let mark = ok == nil ? "…" : (ok! ? "✓" : "✕")
        var text = "  \(mark)  \(title)"
        if let detail { text += "  (\(detail))" }
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        let color: NSColor = ok == nil ? .secondaryLabelColor : (ok! ? .labelColor : .systemRed)
        entry.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.systemFontSize - 1),
            .foregroundColor: color,
        ])
        return entry
    }

    // MARK: - Actions

    @objc private func toggleHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        Settings.shared.toggleHost(host)
    }

    @objc private func addCustomHost() {
        let alert = NSAlert()
        alert.messageText = "Add ping target"
        alert.informativeText = "Hostname or IP address to check in parallel."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !Settings.shared.hosts.contains(value) else { return }
            Settings.shared.hosts = Settings.shared.hosts + [value]
        }
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        Settings.shared.interval = seconds
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Settings.ProbeMode(rawValue: raw) else { return }
        Settings.shared.probeMode = mode
    }

    @objc private func toggleLatency() {
        Settings.shared.showLatency.toggle()
        render(monitor.state)
    }

    @objc private func toggleMonochrome() {
        Settings.shared.monochrome.toggle()
        render(monitor.state)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nThis usually works only once PingDot lives in /Applications."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    #if !APP_STORE
    @objc private func openReleasePage() {
        NSWorkspace.shared.open(UpdateChecker.releasesPage)
    }

    @objc private func toggleUpdateCheck() {
        Settings.shared.checkForUpdates.toggle()
        Settings.shared.checkForUpdates ? updates.start() : updates.stop()
    }
    #endif

    @objc private func showAbout() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "Made by Schub in Munich\n", attributes: base)
        var link = base
        link[.link] = Self.websiteURL
        credits.append(NSAttributedString(string: "schub.tech/labs/pingdot", attributes: link))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static let websiteURL = URL(string: "https://www.schub.tech/labs/pingdot/")!

    @objc private func restart() {
        monitor.restartProbes()
    }

    @objc private func copyDiagnostics() {
        let state = monitor.state
        let settings = Settings.shared
        let diagnostics = state.diagnostics

        var lines = [
            "PingDot diagnostics — \(ISO8601DateFormatter().string(from: Date()))",
            "State: \(headline(for: state))",
        ]
        if let subtitle = subtitle(for: state) { lines.append("Note: \(subtitle)") }
        lines.append("Method: \(settings.probeMode == .icmp ? "ICMP" : "TCP")"
                     + " every \(settings.interval) s (timeout \(settings.timeout) s)")
        lines.append("")

        let probeStats = monitor.probeDebugStats()
        for (index, host) in state.hosts.enumerated() {
            let stats = host.stats()
            var line = "\(host.host): \(host.health)"
            if stats.count > 0 {
                line += ", \(stats.count) samples, loss \(String(format: "%.1f", stats.lossPercent)) %"
                if let average = stats.average { line += ", avg \(format(average))" }
                if let minimum = stats.minimum, let maximum = stats.maximum {
                    line += ", min \(format(minimum)), max \(format(maximum))"
                }
            }
            if let error = host.lastError { line += ", error: \(error)" }
            lines.append(line)
            if probeStats.indices.contains(index), !probeStats[index].isEmpty {
                lines.append("    probe: \(probeStats[index])")
            }
        }

        lines.append("")
        lines.append("Interface: \(state.interfaceName ?? "none") (link \(state.linkUp ? "up" : "down"))")
        lines.append("Router: \(diagnostics.gatewayAddress ?? "unknown") \(mark(diagnostics.gatewayReachable))")
        lines.append("DNS: \(mark(diagnostics.dnsWorking))")
        lines.append("HTTPS www.apple.com: \(mark(diagnostics.tlsReachable))")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func mark(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "ok" : "FAIL"
    }

    // MARK: - Formatting

    private func format(_ rtt: TimeInterval) -> String {
        let ms = rtt * 1000
        return ms < 10 ? String(format: "%.1f ms", ms) : "\(Int(ms.rounded())) ms"
    }

    private func duration(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return String(format: "%d h %d min", seconds / 3600, (seconds % 3600) / 60)
    }
}
