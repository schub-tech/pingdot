import AppKit

/// Draws the menu bar dot.
enum StatusIcon {
    static func color(for health: Health) -> NSColor {
        switch health {
        case .green: return NSColor.systemGreen
        case .yellow: return NSColor.systemYellow
        case .red: return NSColor.systemRed
        case .unknown: return NSColor.tertiaryLabelColor
        }
    }

    /// Cached — `render` runs on every probe result, there is no point in
    /// re-rasterising the same dot once a second.
    private static var cache: [String: NSImage] = [:]

    static func image(for health: Health, monochrome: Bool) -> NSImage {
        let key = "\(health)-\(monochrome)"
        if let cached = cache[key] { return cached }
        let image = monochrome ? symbolImage(for: health) : dotImage(for: health)
        cache[key] = image
        return image
    }

    private static func dotImage(for health: Health) -> NSImage {
        let side: CGFloat = 16
        let diameter: CGFloat = 11
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let rect = NSRect(x: (side - diameter) / 2, y: (side - diameter) / 2,
                              width: diameter, height: diameter)
            color(for: health).setFill()
            NSBezierPath(ovalIn: rect).fill()

            // A hairline keeps the dot readable against a bright wallpaper in the
            // translucent menu bar.
            NSColor.black.withAlphaComponent(0.18).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Colour-blind friendly variant: distinct glyphs, tinted by the system.
    private static func symbolImage(for health: Health) -> NSImage {
        switch health {
        case .green: return template(named: "checkmark.circle.fill", fallback: "✓")
        case .yellow: return template(named: "exclamationmark.circle.fill", fallback: "!")
        case .red: return template(named: "xmark.circle.fill", fallback: "✕")
        case .unknown: return template(named: "questionmark.circle", fallback: "?")
        }
    }

    private static func template(named name: String, fallback: String) -> NSImage {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            (fallback as NSString).draw(in: rect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 12)
            ])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The last N results as a row of coloured dots, for the menu.
    static func sparkline(_ samples: [Sample], limit: Int = 20) -> NSAttributedString {
        let slice = samples.suffix(limit)
        let line = NSMutableAttributedString()
        guard !slice.isEmpty else {
            return NSAttributedString(string: "no data yet", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        for sample in slice {
            line.append(NSAttributedString(string: sample.ok ? "\u{25CF}" : "\u{25CB}", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: sample.ok ? NSColor.systemGreen : NSColor.systemRed,
            ]))
        }
        return line
    }
}
