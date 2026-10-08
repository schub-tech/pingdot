import AppKit
import Charts
import SwiftUI

/// The "how was my internet on the train?" window.
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let history: History
    private var window: NSWindow?

    init(history: History) {
        self.history = history
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Connection History"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 360)
            window.contentView = NSHostingView(rootView: HistoryView(history: history))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("ConnectionHistory")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop the window so a closed one does not keep redrawing in the background.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Model for the view

/// One bar on the chart: one or several minutes merged.
private struct Bucket: Identifiable {
    var start: Date
    var end: Date
    var record: MinuteRecord

    var id: Date { start }
    var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }

    enum Quality { case good, unstable, down, unmeasured }

    /// A few red seconds already make a bar yellow; red needs 10 % of the bar.
    var quality: Quality {
        let observed = record.observed
        guard observed > 0 else { return .unmeasured }
        let threshold = max(1, observed / 10)
        if record.down >= threshold { return .down }
        if record.down > 0 || record.unstable >= threshold { return .unstable }
        return .good
    }
}

private enum Span: Int, CaseIterable, Identifiable {
    case hour = 1, sixHours = 6, day = 24

    var id: Int { rawValue }
    var title: String { self == .day ? "24 h" : "\(rawValue) h" }
    var seconds: TimeInterval { TimeInterval(rawValue) * 3600 }
    /// Keeps the chart at no more than ~360 bars.
    var bucketSeconds: TimeInterval { TimeInterval(max(1, rawValue * 60 / 360)) * 60 }
}

private struct Summary {
    var observed = 0
    var good = 0
    var unstable = 0
    var down = 0
    var outages = 0
    var longestOutage = 0      // seconds
    var medianRTT: TimeInterval?
    var lossPercent: Double?

    init(_ minutes: [MinuteRecord]) {
        var probes = 0, lost = 0
        var averages: [TimeInterval] = []
        var run = 0                     // red seconds of the outage in progress
        var previousStart: TimeInterval?

        for minute in minutes {
            observed += minute.observed
            good += minute.good
            unstable += minute.unstable
            down += minute.down
            probes += minute.probes
            lost += minute.lost
            if let average = minute.averageRTT { averages.append(average) }

            // An outage = back-to-back minutes with red seconds in them.
            let continues = previousStart.map { minute.start - $0 == 60 } ?? false
            if minute.down > 0 {
                if run == 0 || !continues { outages += 1; run = 0 }
                run += minute.down
                longestOutage = max(longestOutage, run)
            } else {
                run = 0
            }
            previousStart = minute.start
        }

        if !averages.isEmpty {
            medianRTT = averages.sorted()[averages.count / 2]
        }
        if probes > 0 { lossPercent = Double(lost) / Double(probes) * 100 }
    }

    func percent(_ seconds: Int) -> String {
        guard observed > 0 else { return "–" }
        let value = Double(seconds) / Double(observed) * 100
        return value > 0 && value < 1 ? "<1 %" : "\(Int(value.rounded())) %"
    }
}

// MARK: - View

private struct HistoryView: View {
    @ObservedObject var history: History
    @State private var span: Span = .day
    @State private var hovered: Bucket?

    var body: some View {
        let now = Date()
        let from = now.addingTimeInterval(-span.seconds)
        let minutes = history.minutes.filter { $0.start + 60 > from.timeIntervalSince1970 }
        let buckets = Self.buckets(minutes, size: span.bucketSeconds)
        let summary = Summary(minutes)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                legend
            }

            tiles(summary, span: span)

            Text(readout(hovered))
                .font(.callout.monospacedDigit())
                .foregroundStyle(hovered == nil ? .secondary : .primary)
                .lineLimit(1)

            chart(buckets, from: from, to: now)
                .overlay {
                    if minutes.isEmpty {
                        Text("No data yet — PingDot records while it runs.")
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .onChange(of: span) { _ in hovered = nil }
    }

    // MARK: Summary

    private func tiles(_ summary: Summary, span: Span) -> some View {
        let unmeasured = max(0, Int(span.seconds) - summary.observed)
        return HStack(alignment: .top, spacing: 28) {
            tile(summary.percent(summary.good), "good", .green)
            tile(summary.percent(summary.unstable), "unstable", .yellow)
            tile(summary.percent(summary.down), "down", .red)
            tile(summary.outages == 0 ? "none" : "\(summary.outages)×",
                 summary.outages == 0 ? "outages" : "outages, longest \(Self.duration(summary.longestOutage))",
                 nil)
            tile(summary.medianRTT.map(Self.ms) ?? "–", "median latency", nil)
            tile(summary.lossPercent.map { String(format: "%.1f %%", $0) } ?? "–", "packet loss", nil)
            Spacer(minLength: 0)
        }
        .help(unmeasured > 60
              ? "Not measured for \(Self.duration(unmeasured)) — Mac asleep or PingDot not running."
              : "")
    }

    private func tile(_ value: String, _ label: String, _ dot: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([(Color.green, "good"), (.yellow, "unstable"), (.red, "down"),
                     (Color(nsColor: .quaternaryLabelColor), "not measured")], id: \.1) { color, label in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Chart

    /// Latency as a line, the dot's colour as a strip underneath — one chart, so
    /// both share the same time axis.
    private func chart(_ buckets: [Bucket], from: Date, to: Date) -> some View {
        let top = Self.ceiling(for: buckets)
        let strip = top * 0.14
        let points = Self.linePoints(buckets)

        return Chart {
            RectangleMark(xStart: .value("Start", from), xEnd: .value("End", to),
                          yStart: .value("ms", -strip), yEnd: .value("ms", -strip * 0.25))
                .foregroundStyle(Color(nsColor: .quaternaryLabelColor))

            ForEach(buckets) { bucket in
                RectangleMark(xStart: .value("Start", bucket.start), xEnd: .value("End", bucket.end),
                              yStart: .value("ms", -strip), yEnd: .value("ms", -strip * 0.25))
                    .foregroundStyle(Self.color(bucket.quality))
            }

            ForEach(points, id: \.date) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("Latency", min(point.ms, top)),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                if point.isolated {
                    PointMark(x: .value("Time", point.date), y: .value("Latency", min(point.ms, top)))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(12)
                }
            }

            if let hovered {
                RuleMark(x: .value("Time", hovered.middle))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: from...to, range: .plotDimension(endPadding: 14))
        .chartYScale(domain: -strip...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) { Text("\(Int(ms)) ms") }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase else { hovered = nil; return }
                        let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { hovered = nil; return }
                        hovered = buckets.first { $0.start <= date && date < $0.end }
                    }
            }
        }
    }

    private func readout(_ bucket: Bucket?) -> String {
        guard let bucket else { return "Hover over the chart for details." }
        let time = "\(Self.clock(bucket.start))–\(Self.clock(bucket.end))"
        let record = bucket.record
        var parts = [time]
        switch bucket.quality {
        case .good: parts.append("good")
        case .unstable: parts.append("unstable")
        case .down: parts.append("down \(Self.duration(record.down))")
        case .unmeasured: parts.append("not measured")
        }
        if let average = record.averageRTT {
            var latency = "\(Self.ms(average)) avg"
            if let max = record.rttMax { latency += ", max \(Self.ms(max))" }
            parts.append(latency)
        }
        if let loss = record.lossPercent { parts.append(String(format: "%.0f %% loss", loss)) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Data shaping

    private static func buckets(_ minutes: [MinuteRecord], size: TimeInterval) -> [Bucket] {
        var result: [Bucket] = []
        for minute in minutes {
            let start = (minute.start / size).rounded(.down) * size
            if let last = result.last, last.start.timeIntervalSince1970 == start {
                result[result.count - 1].record.merge(minute)
            } else {
                var record = MinuteRecord(start: start)
                record.merge(minute)
                result.append(Bucket(start: Date(timeIntervalSince1970: start),
                                     end: Date(timeIntervalSince1970: start + size),
                                     record: record))
            }
        }
        return result
    }

    private struct LinePoint {
        var date: Date
        var ms: Double
        var segment: Int
        var isolated: Bool
    }

    /// Breaks the line wherever there is no latency (outage, sleep), instead of
    /// drawing a confident straight line across the gap.
    private static func linePoints(_ buckets: [Bucket]) -> [LinePoint] {
        var points: [LinePoint] = []
        var segment = 0
        var previousEnd: Date?
        for bucket in buckets {
            guard let average = bucket.record.averageRTT else { previousEnd = nil; continue }
            if previousEnd != bucket.start { segment += 1 }
            points.append(LinePoint(date: bucket.middle, ms: average * 1000, segment: segment, isolated: false))
            previousEnd = bucket.end
        }
        for index in points.indices {
            let alone = (index == 0 || points[index - 1].segment != points[index].segment)
                && (index == points.count - 1 || points[index + 1].segment != points[index].segment)
            points[index].isolated = alone
        }
        return points
    }

    /// Top of the latency axis: a round number above most values, so a single
    /// 4-second spike does not flatten everything else. Spikes are clipped.
    private static func ceiling(for buckets: [Bucket]) -> Double {
        let values = buckets.compactMap(\.record.averageRTT).map { $0 * 1000 }.sorted()
        guard !values.isEmpty else { return 100 }
        let p95 = values[min(values.count - 1, Int(Double(values.count) * 0.95))]
        let steps: [Double] = [20, 50, 100, 200, 300, 500, 1000, 2000, 5000]
        return steps.first { $0 >= p95 * 1.25 } ?? 5000
    }

    // MARK: Formatting

    private static func color(_ quality: Bucket.Quality) -> Color {
        switch quality {
        case .good: return .green
        case .unstable: return .yellow
        case .down: return .red
        case .unmeasured: return Color(nsColor: .quaternaryLabelColor)
        }
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        return ms < 10 ? String(format: "%.1f ms", ms) : "\(Int(ms.rounded())) ms"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return String(format: "%d h %d min", seconds / 3600, (seconds % 3600) / 60)
    }
}
