import AppKit
import SwiftUI

/// Borderless panel under the status item. Not an `NSPopover`: that brings its own
/// material and arrow, which fight the black, rounded design.
private final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // drawn in SwiftUI
        level = .popUpMenu
        collectionBehavior = [.transient, .moveToActiveSpace]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Borderless panels refuse key status by default, and without it Esc never arrives.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

/// The popover belongs to a menu bar app that is rarely active — its buttons have
/// to react to the very first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Opens, places and closes the popover panel.
final class PopoverController {
    let model = PopoverModel()
    private(set) var isVisible = false
    /// Set while a menu opened from the popover is up, so it does not close under it.
    var isTrackingMenu = false
    /// Keeps the panel open whatever is clicked elsewhere and never takes the
    /// keyboard. For screenshots of the simulated states.
    var pinned = false

    private let panel = PopoverPanel()
    private weak var anchorWindow: NSWindow?
    private weak var hostingView: NSView?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    private var closedAt = Date.distantPast
    /// What the card's height depends on, as of the last fit.
    private var lastShape = ""

    init() {
        panel.onCancel = { [weak self] in self?.close() }
    }

    func toggle(under button: NSStatusBarButton) {
        if isVisible {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            // Otherwise this is the click that just closed it: pressing the item can
            // take the key status away before its action arrives.
            show(under: button)
        }
    }

    func show(under button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        anchorWindow = buttonWindow
        show(below: buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), on: screen)
    }

    /// `anchor` is the status item's frame in screen coordinates.
    func show(below anchor: NSRect, on screen: NSScreen) {
        guard !isVisible else { return }
        isVisible = true
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.savesPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        model.pulses = !model.reduceMotion && !model.savesPower

        // The nub points at the item; the card slides sideways to stay on screen.
        let visible = screen.visibleFrame
        let cardX = min(max(anchor.midX - PopoverLayout.preferredNubX, visible.minX + 8),
                        visible.maxX - 8 - PopoverLayout.width)
        let cardTop = min(anchor.minY, visible.maxY) - PopoverLayout.gap
        model.nubX = min(max(anchor.midX - cardX, PopoverLayout.nubLimit),
                         PopoverLayout.width - PopoverLayout.nubLimit)

        // Built on every open and dropped on close: a hidden hosting view would
        // keep the repeating animations running.
        let hosting = FirstMouseHostingView(rootView: PopoverView(model: model))
        let size = hosting.fittingSize
        panel.contentView = hosting
        hostingView = hosting
        panel.setFrame(NSRect(x: cardX - PopoverLayout.marginSide,
                              y: cardTop + PopoverLayout.marginTop - size.height,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        if pinned {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        startWatching()
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        closedAt = Date()
        lastShape = ""
        stopWatching()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }   // reopened meanwhile
            self.panel.orderOut(nil)
            self.panel.contentView = nil
        })
    }

    /// Nothing is pushed into a closed panel — no view updates, no layout. Only
    /// right before opening it is filled once (`opening`), so it starts up to date.
    func update(_ state: NetworkMonitor.State, updateVersion: String?, opening: Bool = false) {
        guard isVisible || opening else { return }
        model.state = state
        // Every assignment to a published property redraws the popover, changed or
        // not — so the ones that rarely change are only touched when they did.
        let settings = Settings.shared
        if model.monochrome != settings.monochrome { model.monochrome = settings.monochrome }
        if model.interval != settings.interval { model.interval = settings.interval }
        if model.updateVersion != updateVersion { model.updateVersion = updateVersion }

        // Targets come and go and the cause line can wrap. Measuring the layout is
        // the expensive part of an update, so only do it when one of those changed,
        // and once SwiftUI has laid out.
        let shape = "\(state.hosts.count)|\(updateVersion != nil)|\(StatePresenter.subtitle(for: state) ?? "")"
        if shape != lastShape, isVisible {
            lastShape = shape
            DispatchQueue.main.async { [weak self] in self?.fitHeight() }
        }
    }

    /// Screen position for a menu hanging under the settings button.
    var settingsMenuOrigin: NSPoint? {
        guard isVisible else { return nil }
        let cardRight = panel.frame.maxX - PopoverLayout.marginSide
        let cardTop = panel.frame.maxY - PopoverLayout.marginTop
        return NSPoint(x: cardRight - PopoverLayout.inset - PopoverLayout.buttonSize,
                       y: cardTop - PopoverLayout.insetTop - PopoverLayout.buttonSize - 6)
    }

    private func fitHeight() {
        guard isVisible, let hosting = hostingView else { return }
        let height = hosting.fittingSize.height
        guard abs(height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// The card without the transparent margins around it, in window coordinates.
    private var cardRect: NSRect {
        NSRect(x: PopoverLayout.marginSide, y: PopoverLayout.marginBottom,
               width: PopoverLayout.width,
               height: panel.frame.height - PopoverLayout.marginBottom - PopoverLayout.marginTop)
    }

    // MARK: - Closing triggers and the downtime tick

    private func startWatching() {
        // "Down for N s" has to count even when no probe result comes in.
        let ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.model.state.health == .red else { return }
            self.model.objectWillChange.send()
        }
        ticker.tolerance = 0.2   // lets the system batch the wake-up with others
        self.ticker = ticker

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        // Clicks inside this app. The status item is left alone, its action toggles.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self, !self.isTrackingMenu, event.window !== self.anchorWindow else { return event }
            if event.window !== self.panel || !self.cardRect.contains(event.locationInWindow) {
                self.close()
            }
            return event
        }) {
            eventMonitors.append(monitor)
        }

        guard !pinned else { return }
        // Clicks in any other app.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.closeUnlessTrackingMenu()
        }) {
            eventMonitors.append(monitor)
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in self?.closeUnlessTrackingMenu() },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                               queue: .main) { [weak self] _ in self?.closeUnlessTrackingMenu() },
        ]
    }

    private func stopWatching() {
        ticker?.invalidate()
        ticker = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func closeUnlessTrackingMenu() {
        if !isTrackingMenu { close() }
    }

    #if DEBUG
    var panelFrame: NSRect { panel.frame }

    /// Closed means nothing left behind: the SwiftUI view is freed, no timer, no
    /// event monitor.
    var isIdle: Bool {
        hostingView == nil && !panel.isVisible && ticker == nil
            && eventMonitors.isEmpty && observers.isEmpty
    }

    /// Writes what the panel shows to a PNG, on a transparent background. Works
    /// without the Screen Recording permission a real screenshot needs.
    func writeSnapshot(to path: String) {
        guard let view = panel.contentView,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = view.bounds.size   // 2x
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
