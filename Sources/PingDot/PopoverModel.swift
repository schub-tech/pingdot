import Foundation

/// What the popover shows. `StatusItemController.render(_:)` pushes the latest
/// state in here while the panel is open.
final class PopoverModel: ObservableObject {
    @Published var state = NetworkMonitor.State()
    @Published var monochrome = false
    /// Seconds between two samples, to label the range tabs in time.
    @Published var interval: TimeInterval = 1
    @Published var updateVersion: String?
    /// Samples shown in the chart: 20, 40 or 60.
    @Published var range = 60

    /// Fixed per opening, set before the view is built.
    var reduceMotion = false
    /// The repeating rings. Off with reduced motion and in Low Power Mode.
    var pulses = true
    /// Low Power Mode: the bars jump to their new height instead of gliding.
    var savesPower = false
    /// Where the nub sits, from the card's left edge.
    var nubX = PopoverLayout.preferredNubX

    var copyDiagnostics: () -> Void = {}
    var showSettings: () -> Void = {}
    var openUpdate: () -> Void = {}
}

/// Geometry shared by the SwiftUI view and the panel that hosts it.
enum PopoverLayout {
    /// The whole popover relative to the mockup. Every size, font and distance
    /// follows this one factor.
    static let scale: CGFloat = 0.8
    /// Card width before scaling. The mockup has 380; the chart and the tiles take
    /// whatever is left between the paddings.
    static let designWidth: CGFloat = 412

    static let width = designWidth * scale
    static let preferredNubX = width * 0.56
    /// From the menu bar to the card's top edge; the nub fills most of it.
    static let gap = 10 * scale
    /// Transparent room around the card for the shadow, the nub and the open
    /// animation — the panel itself has no shadow.
    static let marginTop = 20 * scale
    static let marginSide = 90 * scale
    static let marginBottom = 120 * scale
    /// Border plus padding, down to the settings button.
    static let inset = 21 * scale
    static let insetTop = 23 * scale
    static let buttonSize = 36 * scale
    /// How close the nub may get to the card's rounded corners.
    static let nubLimit = 34 * scale
    /// What the chart gets: the card without border and padding.
    static let contentWidth = width - 2 * inset
}

/// The derived values of the data mapping in docs/design/popover/SPEC.md.
enum PopoverData {
    static let ranges = [20, 40, 60]
    static let tileSamples = 16

    private static let resolvers = ["1.1.1.1": "Cloudflare", "8.8.8.8": "Google", "9.9.9.9": "Quad9"]

    static func title(for host: String) -> String {
        resolvers[host] ?? host
    }

    /// Best reply per sample across all targets in ms, oldest first, nil where every
    /// target lost that sample. Histories differ in length, so they are aligned at
    /// the newest sample; missing older ones are nil.
    static func chartSeries(_ hosts: [HostState], count: Int) -> [Double?] {
        (0..<count).map { position in
            let back = count - 1 - position
            let replies = hosts.compactMap { host -> TimeInterval? in
                let index = host.recent.count - 1 - back
                guard index >= 0, host.recent[index].ok else { return nil }
                return host.recent[index].rtt
            }
            return replies.min().map { $0 * 1000 }
        }
    }

    /// `20 s`, `40 s`, `1 min` at the default interval.
    static func rangeLabel(samples: Int, interval: TimeInterval) -> String {
        let seconds = Double(samples) * interval
        if seconds < 60 { return "\(trimmed(seconds)) s" }
        return "\(trimmed(seconds / 60)) min"
    }

    static func milliseconds(_ rtt: TimeInterval) -> String {
        let ms = Int((rtt * 1000).rounded())
        return ms < 1 ? "<1 ms" : "\(ms) ms"
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
