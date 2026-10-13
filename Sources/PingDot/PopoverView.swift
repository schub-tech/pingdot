import SwiftUI

// The popover that opens on a click on the dot. Layout, colours and motion follow
// docs/design/popover/SPEC.md; mockup.html next to it is the visual reference.
// The fixed line heights below are the mockup's CSS line boxes, so the vertical
// rhythm matches although the system font has other metrics than Manrope.

private enum Palette {
    static let stage = Color.black
    static let surface = Color(hex: 0x161616)
    static let surfaceHover = Color(hex: 0x1D1D1D)
    static let buttonHover = Color(hex: 0x222222)
    static let hairline = Color.white.opacity(0.10)
    static let text2 = Color(hex: 0xB3B3B3)
    static let text3 = Color(hex: 0x6B6B6B)
    static let separator = Color(hex: 0x3A3A3A)
    static let green = Color(hex: 0x00C076)
    static let yellow = Color(hex: 0xFFB020)
    static let red = Color(hex: 0xFF4D4D)
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

private enum Motion {
    /// The one curve of the design. No springs.
    static func curve(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
    static let statusFade = Animation.easeInOut(duration: 0.4)
}

/// Green, yellow and red are reserved for status; grey means "not measured".
private enum Tone {
    case green, yellow, red, grey

    init(_ health: Health) {
        switch health {
        case .green: self = .green
        case .yellow: self = .yellow
        case .red: self = .red
        case .unknown: self = .grey
        }
    }

    /// true is green, false is red, nil is grey.
    init(_ ok: Bool?, soft: Bool = false) {
        switch ok {
        case true?: self = .green
        case false?: self = soft ? .yellow : .red
        case nil: self = .grey
        }
    }

    var color: Color {
        switch self {
        case .green: return Palette.green
        case .yellow: return Palette.yellow
        case .red: return Palette.red
        case .grey: return Palette.text3
        }
    }

    /// For "Use symbols instead of colours".
    var mark: String? {
        switch self {
        case .green: return "✓"
        case .yellow: return "!"
        case .red: return "✕"
        case .grey: return nil
        }
    }
}

/// `@State`, spelled out. In the macOS 27 SDK `@State` is a macro whose plugin only
/// ships with Xcode; this keeps the Command Line Tools build ("No Xcode needed").
@propertyWrapper
private struct Local<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
}

private func text(_ size: CGFloat, _ weight: Font.Weight) -> Font {
    .system(size: size * PopoverLayout.scale, weight: weight).monospacedDigit()
}

// Sizes are written as in the mockup and scaled in one place: `22.pt`.
private extension BinaryInteger {
    var pt: CGFloat { CGFloat(self) * PopoverLayout.scale }
}

private extension BinaryFloatingPoint {
    var pt: CGFloat { CGFloat(self) * PopoverLayout.scale }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    /// False for the first frame, then the open and stagger animations run to true.
    /// With reduced motion it starts true: the final state, nothing to animate.
    @Local private var shown: Bool

    init(model: PopoverModel) {
        self.model = model
        _shown = Local(wrappedValue: model.reduceMotion)
    }

    private var state: NetworkMonitor.State { model.state }
    private var tone: Tone { Tone(state.health) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            nub
            card
        }
        .frame(width: PopoverLayout.width)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.94, anchor: UnitPoint(x: model.nubX / PopoverLayout.width, y: 0))
        .offset(y: shown ? 0 : -10.pt)
        .animation(Motion.curve(0.32), value: shown)
        .padding(EdgeInsets(top: PopoverLayout.marginTop, leading: PopoverLayout.marginSide,
                            bottom: PopoverLayout.marginBottom, trailing: PopoverLayout.marginSide))
        .onAppear { shown = true }
    }

    private var nub: some View {
        RoundedRectangle(cornerRadius: 3.pt)
            .fill(Palette.stage)
            .overlay(RoundedRectangle(cornerRadius: 3.pt).strokeBorder(Palette.hairline, lineWidth: 1))
            .frame(width: 14.pt, height: 14.pt)
            .rotationEffect(.degrees(45))
            .offset(x: model.nubX - 7.pt, y: -6.pt)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            hero.padding(.top, 22.pt).rise(shown, 0.06)
            headline.padding(.top, 14.pt).rise(shown, 0.10)
            cause.padding(.top, 4.pt).rise(shown, 0.12)
            LatencyChart(series: PopoverData.chartSeries(state.hosts, count: model.range),
                         color: tone.color, shown: shown, pulses: model.pulses)
                .padding(.top, 20.pt)
                .rise(shown, 0.16)
            rangeRow.padding(.top, 12.pt)
            VStack(spacing: 10.pt) {
                if let version = model.updateVersion { updateRow(version) }
                targets
            }
            .padding(.top, 20.pt)
            .rise(shown, 0.22)
            diagnostics.padding(.top, 10.pt).rise(shown, 0.28)
            CopyPill(action: model.copyDiagnostics).padding(.top, 16.pt).rise(shown, 0.34)
        }
        .padding(EdgeInsets(top: PopoverLayout.insetTop, leading: PopoverLayout.inset,
                            bottom: PopoverLayout.inset, trailing: PopoverLayout.inset))
        .frame(width: PopoverLayout.width)
        .background(
            RoundedRectangle(cornerRadius: 24.pt)
                .fill(Palette.stage)
                .shadow(color: .black.opacity(0.55), radius: 40.pt, y: 30.pt)
        )
        .overlay(RoundedRectangle(cornerRadius: 24.pt).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    // MARK: Top half

    private var statusRow: some View {
        HStack(spacing: 10.pt) {
            StatusDot(tone: tone, monochrome: model.monochrome, pulses: model.pulses)
            Text(statusWord).foregroundColor(.white)
            Text("·").foregroundColor(Palette.separator)
            Text(state.linkUp ? (state.interfaceName ?? "") : "no network")
                .foregroundColor(Palette.text3)
            Spacer(minLength: 0)
            IconButton(glyph: .sliders, label: "Settings", action: model.showSettings)
        }
        .font(text(13, .semibold))
        .lineLimit(1)
        .frame(height: PopoverLayout.buttonSize)
    }

    private var statusWord: String {
        switch state.health {
        case .green: return "Online"
        case .yellow: return "Unstable"
        case .red: return "Offline"
        case .unknown: return "Checking"
        }
    }

    /// The number is the hero: latency while there is a connection, downtime without.
    private var heroValue: (number: String, unit: String) {
        switch state.health {
        case .unknown:
            return ("…", "")
        case .red:
            guard let since = state.downSince else { return ("–", "") }
            return ("\(max(0, Int(Date().timeIntervalSince(since))))", "s down")
        case .green, .yellow:
            guard let rtt = state.bestRTT else { return ("–", "ms") }
            return ("\(Int((rtt * 1000).rounded()))", "ms")
        }
    }

    private var hero: some View {
        let value = heroValue
        return HStack(alignment: .firstTextBaseline, spacing: 8.pt) {
            Text(value.number)
                .font(text(84, .bold))
                .tracking(-0.045 * 84.pt)
                .foregroundColor(.white)
            Text(value.unit)
                .font(text(22, .semibold))
                .foregroundColor(Palette.text3)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)   // hours of downtime are a long number
        .fixedSize(horizontal: false, vertical: true)
        // Line height 0.9: the box ends 6.5 pt below the baseline.
        .alignmentGuide(.bottom) { $0[.firstTextBaseline] + 6.5.pt }
        .frame(maxWidth: .infinity, minHeight: 76.5.pt, maxHeight: 76.5.pt, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value.number) \(value.unit), \(headlineText)")
    }

    private var headlineText: String {
        StatePresenter.headline(for: state, includeRTT: false)
    }

    private var headline: some View {
        Text(headlineText)
            .font(text(17, .bold))
            .foregroundColor(.white)
            .lineLimit(1)
            .frame(height: 23.pt)
            .accessibilityHidden(true)   // read with the hero number
    }

    /// Keeps its height when there is nothing to say, so the layout does not jump.
    private var cause: some View {
        Text(StatePresenter.subtitle(for: state) ?? " ")
            .font(text(13, .regular))
            .lineSpacing(3.pt)
            .foregroundColor(Palette.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 19.pt, alignment: .top)
    }

    private var rangeRow: some View {
        HStack(spacing: 16.pt) {
            Text("Latency, best reply")
                .font(text(12, .semibold))
                .foregroundColor(Palette.text3)
            Spacer(minLength: 0)
            ForEach(PopoverData.ranges, id: \.self) { samples in
                RangeTab(title: PopoverData.rangeLabel(samples: samples, interval: model.interval),
                         active: model.range == samples) { model.range = samples }
            }
        }
        .frame(height: 26.pt)
    }

    // MARK: Bottom half

    private func updateRow(_ version: String) -> some View {
        Button(action: model.openUpdate) {
            Tile(padding: EdgeInsets(top: 11.pt, leading: 14.pt, bottom: 11.pt, trailing: 14.pt)) {
                HStack {
                    Text("Update available").foregroundColor(.white)
                    Spacer(minLength: 8)
                    Text("PingDot \(version)").foregroundColor(Palette.text3)
                }
                .font(text(13, .semibold))
                .lineLimit(1)
            }
        }
        .buttonStyle(PressStyle())
    }

    /// One tile per target, two per row.
    private var targets: some View {
        let hosts = state.hosts
        return VStack(spacing: 10.pt) {
            ForEach(Array(stride(from: 0, to: hosts.count, by: 2)), id: \.self) { first in
                HStack(spacing: 10.pt) {
                    TargetTile(host: hosts[first], animated: !model.savesPower)
                    if first + 1 < hosts.count {
                        TargetTile(host: hosts[first + 1], animated: !model.savesPower)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1.pt)
                    }
                }
            }
        }
    }

    private var diagnostics: some View {
        let checks = state.diagnostics
        // Pings fine but DNS or HTTPS not: yellow, like the dot.
        let soft = state.degradation == .dnsFailing || state.degradation == .webBlocked
        return VStack(spacing: 10.pt) {
            HStack(spacing: 10.pt) {
                DiagnosticTile(glyph: .wifi, label: "Network",
                               value: state.linkUp ? (state.interfaceName ?? "On") : "Off",
                               tone: Tone(state.linkUp), monochrome: model.monochrome)
                DiagnosticTile(glyph: .router, label: "Router", value: routerValue,
                               tone: Tone(checks.gatewayReachable), monochrome: model.monochrome)
            }
            HStack(spacing: 10.pt) {
                DiagnosticTile(glyph: .dns, label: "DNS", value: verdict(checks.dnsWorking),
                               tone: Tone(checks.dnsWorking, soft: soft), monochrome: model.monochrome)
                DiagnosticTile(glyph: .lock, label: "HTTPS", value: verdict(checks.tlsReachable),
                               tone: Tone(checks.tlsReachable, soft: soft), monochrome: model.monochrome)
            }
        }
    }

    private var routerValue: String {
        switch state.diagnostics.gatewayReachable {
        case true?: return state.diagnostics.gatewayRTT.map(PopoverData.milliseconds) ?? "OK"
        case false?: return "Unreachable"
        case nil: return "…"
        }
    }

    private func verdict(_ ok: Bool?) -> String {
        guard let ok else { return "…" }
        return ok ? "OK" : "Failing"
    }
}

// MARK: - Motion helpers

private extension View {
    /// The staggered entrance of one section.
    func rise(_ shown: Bool, _ delay: Double) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10.pt)
            .animation(Motion.curve(0.44).delay(delay), value: shown)
    }
}

/// A ring that grows and fades forever. A Core Animation layer, not a SwiftUI
/// animation: the render server moves it, so the app itself sleeps between two
/// probe results instead of redrawing the popover for every frame.
private struct Pulse: NSViewRepresentable {
    let color: Color
    /// Scale at the start, relative to the full size the view is laid out at.
    let from: CGFloat
    let opacity: Float

    func makeNSView(context: Context) -> PulseLayerView {
        PulseLayerView(from: from, opacity: opacity)
    }

    func updateNSView(_ view: PulseLayerView, context: Context) {
        view.setColor(NSColor(color).cgColor)
    }
}

final class PulseLayerView: NSView {
    private let ring = CALayer()
    private let from: CGFloat
    private let startOpacity: Float

    init(from: CGFloat, opacity: Float) {
        self.from = from
        startOpacity = opacity
        super.init(frame: .zero)
        wantsLayer = true
        ring.opacity = 0   // at rest the ring is gone, like at the end of a round
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    func setColor(_ color: CGColor) {
        guard ring.backgroundColor != color else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)   // the status colour cross-fade
        ring.backgroundColor = color
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ring.removeAllAnimations()
        guard window != nil else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startOpacity
        fade.toValue = 0
        let round = CAAnimationGroup()
        round.animations = [scale, fade]
        round.duration = 1.6
        round.timingFunction = CAMediaTimingFunction(name: .easeOut)
        round.repeatCount = .infinity
        ring.add(round, forKey: "pulse")
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Pieces

/// White while all is well — the dot only takes a colour when something is wrong.
private struct StatusDot: View {
    let tone: Tone
    let monochrome: Bool
    let pulses: Bool

    private var color: Color { tone == .green ? .white : tone.color }

    var body: some View {
        ZStack {
            if monochrome, let mark = tone.mark {
                Text(mark).font(text(13, .heavy)).foregroundColor(color).fixedSize()
            } else {
                if pulses {
                    Pulse(color: color, from: 1 / 2.8, opacity: 0.55)
                        .frame(width: (8 * 2.8).pt, height: (8 * 2.8).pt)
                }
                Circle().fill(color).frame(width: 8.pt, height: 8.pt)
            }
        }
        .frame(width: 8.pt, height: 8.pt)
        .animation(Motion.statusFade, value: tone)
        .accessibilityHidden(true)
    }
}

private struct IconButton: View {
    let glyph: Glyph.Kind
    let label: String
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: glyph)
                .stroke(hovering ? Color.white : Palette.text2, style: Glyph.stroke)
                .frame(width: 18.pt, height: 18.pt)
                .frame(width: PopoverLayout.buttonSize, height: PopoverLayout.buttonSize)
                .background(Circle().fill(hovering ? Palette.buttonHover : Palette.surface))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(label)
    }
}

private struct RangeTab: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(text(13, active ? .bold : .medium))
                .foregroundColor(active || hovering ? .white : Palette.text3)
                .frame(height: 26.pt)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Show the last \(title)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The one surface grey, lighter under the pointer.
private struct Tile<Content: View>: View {
    var padding = EdgeInsets(top: 14.pt, leading: 14.pt, bottom: 14.pt, trailing: 14.pt)
    @ViewBuilder let content: Content
    @Local private var hovering = false

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18.pt)
                .fill(hovering ? Palette.surfaceHover : Palette.surface))
            .contentShape(RoundedRectangle(cornerRadius: 18.pt))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct TargetTile: View {
    let host: HostState
    let animated: Bool

    var body: some View {
        let stats = host.stats(over: PopoverData.tileSamples)
        let title = PopoverData.title(for: host.host)
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6.pt) {
                    Text(title)
                    Spacer(minLength: 0)
                    if title != host.host { Text(host.host).layoutPriority(1) }
                }
                .font(text(12, .semibold))
                .foregroundColor(Palette.text3)
                .lineLimit(1)
                .frame(height: 16.5.pt)

                Text(value(stats))
                    .font(text(22, .heavy))
                    .tracking(-0.03 * 22.pt)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(height: 30.pt)
                    .padding(.top, 8.pt)

                bars.padding(.top, 10.pt)

                Text(loss(stats).text)
                    .font(text(12, .semibold))
                    .foregroundColor(loss(stats).color)
                    .frame(height: 16.5.pt)
                    .padding(.top, 8.pt)
                    .animation(Motion.statusFade, value: stats.lossPercent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value(stats)), \(loss(stats).text)")
    }

    private func value(_ stats: Stats) -> String {
        if stats.count == 0 { return "…" }
        return stats.average.map(PopoverData.milliseconds) ?? "no reply"
    }

    private func loss(_ stats: Stats) -> (text: String, color: Color) {
        if stats.count == 0 { return ("no data yet", Palette.text3) }
        let percent = Int(stats.lossPercent.rounded())
        if percent == 0 { return ("no loss", Palette.text3) }
        return ("\(percent) % loss", percent > 50 ? Palette.red : Palette.yellow)
    }

    /// The last 16 samples, newest on the right. Lost ones are short and red.
    private var bars: some View {
        let samples = Array(host.recent.suffix(PopoverData.tileSamples))
        let scale = max(0.030, samples.compactMap(\.rtt).max() ?? 0)
        let empty = PopoverData.tileSamples - samples.count
        return HStack(alignment: .bottom, spacing: 3.pt) {
            ForEach(0..<PopoverData.tileSamples, id: \.self) { slot in
                let sample = slot >= empty ? samples[slot - empty] : nil
                RoundedRectangle(cornerRadius: 2.pt)
                    .fill(barColor(sample))
                    .frame(height: barHeight(sample, scale: scale))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 28.pt, alignment: .bottom)
        .animation(animated ? Motion.curve(0.35) : nil, value: samples.map { $0.ok ? $0.rtt ?? 0 : -1 })
    }

    private func barHeight(_ sample: Sample?, scale: TimeInterval) -> CGFloat {
        guard let sample else { return 0 }
        guard sample.ok, let rtt = sample.rtt else { return 4.pt }
        return (8 + rtt / scale * 20).pt
    }

    private func barColor(_ sample: Sample?) -> Color {
        guard let sample else { return .clear }
        return sample.ok ? Color.white.opacity(0.85) : Palette.red
    }
}

private struct DiagnosticTile: View {
    let glyph: Glyph.Kind
    let label: String
    let value: String
    let tone: Tone
    let monochrome: Bool

    var body: some View {
        Tile {
            HStack(spacing: 12.pt) {
                Glyph(kind: glyph)
                    .stroke(tone.color, style: Glyph.stroke)
                    .frame(width: 18.pt, height: 18.pt)
                    .frame(width: 36.pt, height: 36.pt)
                    .background(RoundedRectangle(cornerRadius: 12.pt)
                        .fill(tone == .grey ? Color.white.opacity(0.06) : tone.color.opacity(0.14)))
                    .animation(Motion.statusFade, value: tone)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(text(12, .semibold))
                        .foregroundColor(Palette.text3)
                        .frame(height: 16.5.pt)
                    Text(shownValue)
                        .font(text(14, .bold))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.8)   // "Unreachable" is a tight fit
                        .frame(height: 19.5.pt)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    /// With symbols instead of colours, no verdict relies on the icon's colour.
    private var shownValue: String {
        guard monochrome, tone != .grey else { return value }
        return "\(value) \(tone == .green ? "✓" : "✕")"
    }
}

private struct CopyPill: View {
    let action: () -> Void
    @Local private var copied = false
    @Local private var hovering = false

    var body: some View {
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            Text(copied ? "Copied" : "Copy diagnostics")
                .font(text(14, .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: 46.pt, maxHeight: 46.pt)
                .background(Capsule()
                    .fill(Color(white: hovering ? 0.92 : 1))
                    .shadow(color: .black.opacity(0.55), radius: 15.pt, y: 8.pt))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Chart

/// Best reply over the chosen range. Decorative for VoiceOver — the hero number
/// and the headline say the same.
private struct LatencyChart: View {
    let series: [Double?]
    let color: Color
    let shown: Bool
    let pulses: Bool

    private static let size = CGSize(width: PopoverLayout.contentWidth, height: 96.pt)

    var body: some View {
        let plot = Plot(series: series, size: Self.size)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 90.5.pt))
                path.addLine(to: CGPoint(x: Self.size.width, y: 90.5.pt))
            }
            .stroke(Color.white.opacity(0.08), lineWidth: 1)

            // Drawn once on open; the live updates afterwards just replace the path.
            plot.line
                .trim(from: 0, to: shown ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 2.pt, lineCap: .round, lineJoin: .round,
                                                  dash: plot.isEmpty ? [3.pt, 6.pt] : []))
                .animation(Motion.curve(1.2).delay(0.16), value: shown)

            if pulses {
                Pulse(color: color, from: 0.4 / 1.7, opacity: 0.5)
                    .frame(width: (18 * 1.7).pt, height: (18 * 1.7).pt)
                    .position(plot.end)
            }
            Circle().fill(color).frame(width: 7.pt, height: 7.pt).position(plot.end)

            Text("\(Int(plot.top.rounded())) ms")
                .font(text(11, .semibold))
                .foregroundColor(Palette.text3)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(Motion.statusFade, value: color)
        .accessibilityHidden(true)
    }

    private struct Plot {
        var line = Path()
        var end: CGPoint
        /// Top of the y scale in ms.
        let top: Double
        let isEmpty: Bool

        init(series: [Double?], size: CGSize) {
            let values = series.compactMap { $0 }
            let floor = size.height - 6.pt
            let inset = 4.pt
            top = max(40, values.max() ?? 0) * 1.15
            isEmpty = values.isEmpty
            end = CGPoint(x: size.width - inset, y: floor)

            guard !values.isEmpty else {
                line.move(to: CGPoint(x: inset, y: floor))
                line.addLine(to: end)
                return
            }
            var penDown = false
            for (index, value) in series.enumerated() {
                guard let value else { penDown = false; continue }
                let point = CGPoint(
                    x: inset + CGFloat(index) * (size.width - 2 * inset) / CGFloat(max(series.count - 1, 1)),
                    y: floor - CGFloat(value / top) * (size.height - 18.pt))
                if penDown {
                    line.addLine(to: point)
                } else {
                    line.move(to: point)
                    line.addLine(to: point)   // a lone reply between two losses stays visible
                }
                penDown = true
                end = point
            }
            // The newest sample was lost: park the dot on the floor.
            if series.last ?? nil == nil { end = CGPoint(x: size.width - inset, y: floor) }
        }
    }
}

// MARK: - Icons

/// The mockup's line icons, on its 24 unit grid.
private struct Glyph: Shape {
    enum Kind { case sliders, wifi, router, dns, lock }
    let kind: Kind

    /// 1.8 units at the 18 pt the icons are drawn at, before scaling.
    static let stroke = StrokeStyle(lineWidth: 1.35 * PopoverLayout.scale, lineCap: .round, lineJoin: .round)

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .sliders:
            line(&p, 4, 6, 14, 6); line(&p, 18, 6, 20, 6)
            line(&p, 4, 12, 8, 12); line(&p, 12, 12, 20, 12)
            line(&p, 4, 18, 16, 18)
            knob(&p, 16, 6); knob(&p, 10, 12); knob(&p, 18, 18)
        case .wifi:
            arc(&p, from: 2, to: 22, y: 9, radius: 15)
            arc(&p, from: 5, to: 19, y: 12.5, radius: 10)
            arc(&p, from: 8.5, to: 15.5, y: 16, radius: 5)
            dot(&p, 12, 19.5)
        case .router:
            box(&p, 3, 13, 18, 7)
            dot(&p, 7, 16.5); dot(&p, 11, 16.5)
            line(&p, 15, 13, 15, 8)
            arc(&p, from: 12, to: 18, y: 6, radius: 4.5)
        case .dns:
            box(&p, 3, 4, 18, 7); box(&p, 3, 13, 18, 7)
            dot(&p, 7, 7.5); dot(&p, 7, 16.5)
        case .lock:
            box(&p, 5, 11, 14, 10)
            p.move(to: CGPoint(x: 8, y: 11))
            p.addLine(to: CGPoint(x: 8, y: 7))
            arc(&p, from: 8, to: 16, y: 7, radius: 4, continuing: true)
            p.addLine(to: CGPoint(x: 16, y: 11))
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }

    private func line(_ p: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
    }

    private func dot(_ p: inout Path, _ x: CGFloat, _ y: CGFloat) {
        line(&p, x, y, x + 0.01, y)
    }

    private func knob(_ p: inout Path, _ x: CGFloat, _ y: CGFloat) {
        p.addEllipse(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
    }

    private func box(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: 2, height: 2))
    }

    /// An arc over the top between two points on the same height (SVG `a r r 0 0 1`).
    private func arc(_ p: inout Path, from x1: CGFloat, to x2: CGFloat, y: CGFloat,
                     radius: CGFloat, continuing: Bool = false) {
        let half = (x2 - x1) / 2
        let center = CGPoint(x: x1 + half, y: y + (radius * radius - half * half).squareRoot())
        let spread = asin(min(1, half / radius))
        let steps = 20
        for step in 0...steps {
            let angle = -CGFloat.pi / 2 - spread + 2 * spread * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if step == 0 && !continuing { p.move(to: point) } else { p.addLine(to: point) }
        }
    }
}
