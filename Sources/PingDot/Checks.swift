#if DEBUG
import AppKit
import Combine

/// The tests, reachable via `PingDot --check` in a debug build (Scripts/test.sh
/// runs them). XCTest and swift-testing both need Xcode; like the rest of the
/// project this gets by with the Command Line Tools. Never returns.
///
/// Besides the popover's logic it checks what keeps PingDot cheap: a closed
/// popover does no work and holds nothing, an open one redraws once per update.
enum Checks {
    private static var failures = 0

    static func run() -> Never {
        _ = NSApplication.shared
        print("PingDot checks\n")

        section("Data mapping", dataMapping)
        section("Wording", wording)
        section("Simulated states", simulatedStates)
        section("Menu bar dot", menuBarDot)
        section("Popover: closed costs nothing", closedPopover)
        section("Popover: open and close", openPopover)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Logic

    private static func dataMapping() {
        func host(_ rtts: [Double?]) -> HostState {
            HostState(host: "h", recent: rtts.map { Sample(ok: $0 != nil, rtt: $0.map { $0 / 1000 }) })
        }
        // Oldest first. The second target has a shorter history.
        let series = PopoverData.chartSeries([host([10, nil, 30, 8]), host([nil, 5])], count: 4)
        expect(series.count == 4, "chart has one point per sample")
        expect(close(series[3], 5), "the best reply is the fastest one, compared at the newest sample")
        expect(close(series[2], 30), "a lost sample of one target leaves the other's reply")
        expect(series[1] == nil, "nil where every target lost the sample")
        expect(close(series[0], 10), "older than the shorter history: the longer one alone")
        expect(PopoverData.chartSeries([host([7])], count: 3).map { $0 == nil } == [true, true, false],
               "a short history is padded at the old end")
        expect(PopoverData.chartSeries([], count: 20).allSatisfy { $0 == nil }, "no targets, no points")

        expect(PopoverData.rangeLabel(samples: 20, interval: 1) == "20 s", "20 samples at 1 s")
        expect(PopoverData.rangeLabel(samples: 60, interval: 1) == "1 min", "60 samples at 1 s")
        expect(PopoverData.rangeLabel(samples: 20, interval: 0.5) == "10 s", "20 samples at 500 ms")
        expect(PopoverData.rangeLabel(samples: 60, interval: 5) == "5 min", "60 samples at 5 s")

        expect(PopoverData.milliseconds(0.0126) == "13 ms", "whole milliseconds")
        expect(PopoverData.milliseconds(0.0002) == "<1 ms", "never 0 ms")
        expect(PopoverData.title(for: "1.1.1.1") == "Cloudflare", "known resolver gets its name")
        expect(PopoverData.title(for: "example.com") == "example.com", "other targets keep theirs")

        let stats = host([10, nil, 30, nil]).stats(over: PopoverData.tileSamples)
        expect(stats.lossPercent == 50 && close(stats.average.map { $0 * 1000 }, 20), "tile loss and average")
    }

    private static func wording() {
        var state = NetworkMonitor.State()
        state.health = .green
        state.hosts = [HostState(host: "1.1.1.1", recent: [], lastRTT: 0.012)]
        expect(StatePresenter.headline(for: state) == "Internet OK — 12 ms", "tooltip keeps the latency")
        expect(StatePresenter.headline(for: state, includeRTT: false) == "Internet OK",
               "popover headline leaves it to the big number")
        state.linkUp = false
        expect(StatePresenter.headline(for: state) == "No network connection", "link down wins")
        expect(StatePresenter.subtitle(for: state) != nil, "link down has a cause line")
    }

    private static func simulatedStates() {
        for (name, health) in [("ok", Health.green), ("warn", .yellow), ("down", .red)] {
            guard let feed = FakeFeed(environment: ["PINGDOT_FAKE_STATE": name]) else {
                expect(false, "PINGDOT_FAKE_STATE=\(name) is known")
                continue
            }
            let state = feed.state
            expect(state.health == health, "\(name) is \(health)")
            expect(state.hosts.count == 2 && state.hosts.allSatisfy { $0.recent.count == 60 },
                   "\(name) has a full history for two targets")
        }
        expect(FakeFeed(environment: [:]) == nil, "no simulation without the variable")
        expect(FakeFeed(environment: ["PINGDOT_FAKE_STATE": "nonsense"]) == nil, "unknown value is ignored")
    }

    private static func menuBarDot() {
        let healthy = StatusIcon.image(for: .green, monochrome: false)
        expect(healthy.isTemplate, "healthy dot takes the menu bar's own colour")
        expect(!StatusIcon.image(for: .yellow, monochrome: false).isTemplate, "yellow keeps its colour")
        expect(!StatusIcon.image(for: .red, monochrome: false).isTemplate, "red keeps its colour")
        expect(StatusIcon.image(for: .green, monochrome: false) === healthy,
               "the dot is drawn once and reused, not per probe result")
    }

    // MARK: - Popover lifecycle

    private static func closedPopover() {
        let popover = PopoverController()
        var redraws = 0
        let watch = popover.model.objectWillChange.sink { redraws += 1 }
        defer { watch.cancel() }

        var state = NetworkMonitor.State()
        state.health = .green
        for _ in 0..<100 { popover.update(state, updateVersion: nil) }
        expect(redraws == 0, "100 probe results reach a closed popover without a single redraw")
        expect(popover.model.state.health == .unknown, "…and without touching its model")
        expect(popover.isIdle, "a popover that was never opened holds no view, timer or monitor")
    }

    private static func openPopover() {
        guard let screen = NSScreen.main, let feed = FakeFeed(environment: ["PINGDOT_FAKE_STATE": "ok"]) else {
            print("  – skipped: no screen")
            return
        }
        let popover = PopoverController()
        popover.pinned = true   // never takes the keyboard from whoever runs the checks
        var redraws = 0
        let watch = popover.model.objectWillChange.sink { redraws += 1 }
        defer { watch.cancel() }

        var state = feed.state
        // Without a running app nothing drains the pool that holds on to the views.
        autoreleasepool {
            let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 24, height: 24)
            popover.update(state, updateVersion: nil, opening: true)
            popover.show(below: anchor, on: screen)
            spin(0.3)
            expect(popover.isVisible && !popover.isIdle, "opens")
            let frame = popover.panelFrame
            expect(abs(frame.width - (PopoverLayout.width + 2 * PopoverLayout.marginSide)) < 1, "card is as wide as designed")
            expect(screen.visibleFrame.insetBy(dx: -PopoverLayout.marginSide, dy: -PopoverLayout.marginBottom)
                .contains(frame), "card stays on the screen")

            redraws = 0
            popover.update(state, updateVersion: nil)
            expect(redraws == 1, "one probe result is one redraw (got \(redraws))")

            // Two more targets are one more row of tiles: the panel grows downwards.
            state.hosts += state.hosts
            popover.update(state, updateVersion: nil)
            spin(0.3)
            let taller = popover.panelFrame
            expect(taller.height > frame.height + 50, "panel grows with the targets")
            expect(abs(taller.maxY - frame.maxY) < 1, "…and keeps its top edge under the menu bar")

            popover.close()
            expect(!popover.isVisible, "closes")
            spin(0.5)   // the 150 ms fade
        }
        expect(popover.isIdle, "closed: view, timer and event monitors are gone")

        redraws = 0
        popover.update(state, updateVersion: nil)
        expect(redraws == 0, "closed again: updates are dropped")
    }

    // MARK: - Helpers

    private static func section(_ title: String, _ body: () -> Void) {
        print(title)
        body()
    }

    private static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL")  \(what)")
        if !condition { failures += 1 }
    }

    private static func close(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 0.0001 } ?? false
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
