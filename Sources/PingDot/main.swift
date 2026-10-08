import AppKit

// A write to a socket the system has closed must fail with EPIPE, not end the
// app: SIGPIPE's default action quits silently, without a crash report.
signal(SIGPIPE, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
    }
}

// `PingDot --selftest [host …]` runs the probes headless for a few seconds and
// prints what they measured. Handy to check whether ICMP works on a given network
// before blaming the dot. Without arguments it tests the configured targets.
if let flag = CommandLine.arguments.firstIndex(of: "--selftest") {
    let explicit = Array(CommandLine.arguments[(flag + 1)...])
    SelfTest.run(hosts: explicit.isEmpty ? Settings.shared.hosts : explicit)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no main window. Info.plist sets LSUIElement too,
// this makes `swift run` behave the same way.
app.setActivationPolicy(.accessory)
app.run()
