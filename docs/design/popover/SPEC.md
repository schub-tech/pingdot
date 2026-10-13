# PingDot popover redesign

Replace the plain `NSMenu` that opens on click with a custom, animated popover.
The visual reference is [`mockup.html`](mockup.html) in this folder: open it in a
browser, click the dot in the fake menu bar to replay the open animation, and use
*Simulate state* to switch between healthy, unstable and offline.

The look follows a Trade Republic style system: black stage, one surface grey,
numbers as the hero, green / yellow / red only for status, white pill as the
primary action, calm motion without bounce.

## 1. Architecture

**Window.** Use a custom borderless `NSPanel` positioned under the status item,
not `NSPopover`. `NSPopover` draws its own material background and arrow, which
fights the black, 24 pt rounded design. Panel setup:

- `styleMask: [.borderless, .nonactivatingPanel]`, `isOpaque = false`,
  `backgroundColor = .clear`, `hasShadow = false` (the shadow is drawn in SwiftUI),
  `level = .popUpMenu`, `collectionBehavior = [.transient, .moveToActiveSpace]`.
- Content is an `NSHostingView` with the SwiftUI `PopoverView`.
- Position: top edge 6 pt below the menu bar, the nub centred under the status
  item button, the panel kept inside the visible frame of the screen the item is on.
- Close on: second click on the item, `Esc`, a click outside (global
  `NSEvent` monitor for left and right mouse down), and when the app resigns active.

**Old menu stays.** Right click or control click on the status item still opens the
existing `NSMenu` built in `StatusItemController.rebuildMenu()`, so Settings, About
and Quit remain reachable. The settings button in the popover pops up the existing
Settings submenu (`settingsMenu(_:)`) anchored at that button via
`NSMenu.popUp(positioning:at:in:)`.

**View model.** Add `PopoverModel: ObservableObject` that holds the latest
`NetworkMonitor.State`. `StatusItemController.render(_:)` already runs on every
probe result; push the state into the model there. Move `headline(for:)` and
`subtitle(for:)` into a small presenter type so the tooltip and the popover share
them.

## 2. Data mapping

Everything in the mockup maps to data that already exists, except the router
latency (see section 3). Do not invent values the backend does not measure.

| Element | Source |
|---|---|
| Status dot and word | `state.health`: green "Online", yellow "Unstable", red "Offline", unknown "Checking" |
| Label next to it | `state.interfaceName`, or "no network" when `!state.linkUp` |
| Hero number | green and yellow: `state.bestRTT` in whole ms. Red: seconds since `state.downSince`, unit "s down". Unknown: "…" |
| Headline | `headline(for:)`, but without the RTT suffix for green, because the RTT is now the hero number |
| Cause line | `subtitle(for:)`. When nil, keep the line's height so the layout does not jump |
| Chart | Best RTT per sample index across all hosts (`min` of the `rtt` of samples that are `ok`), nil when all hosts lost that sample. `HostState.recent` keeps up to 120 samples |
| Range tabs | 20, 40, 60 samples. Label them in time: samples × `Settings.interval` (1 s default gives 20 s, 40 s, 1 min) |
| Max label | Top of the y scale: `max(40 ms, highest value) × 1.15` |
| Target tiles | One tile per entry in `state.hosts`, two per row, more rows for more hosts |
| Tile title | Friendly name for known resolvers (1.1.1.1 Cloudflare, 8.8.8.8 Google, 9.9.9.9 Quad9), else the host string. Address on the right, hidden when it equals the title |
| Tile value | `stats(over: 16).average`, "no reply" when nil |
| Tile bars | Last 16 samples. Received: height `8 + rtt / max(30 ms, max rtt) × 20` pt, white 85 %. Lost: 4 pt, red |
| Tile loss | `stats(over: 16).lossPercent`. 0: "no loss" in grey. Up to 50 %: yellow. Above: red |
| Network tile | `state.linkUp`, value `state.interfaceName` or "Off" |
| Router tile | `diagnostics.gatewayReachable`, value `gatewayRTT` in ms (new), "Unreachable" when false |
| DNS tile | `diagnostics.dnsWorking`: true "OK", false "Failing", nil "…" |
| HTTPS tile | `diagnostics.tlsReachable`: true "OK", false "Failing", nil "…" |
| Update line | Keep the existing "Update available" entry as a small row above the tiles when `updates.availableVersion` is set |
| Pill | Existing `copyDiagnostics()`. Label turns into "Copied" for 1.6 s |

Tile colours: true is green, false is red, nil is grey. Exception: DNS or HTTPS
false while the pings are healthy (`degradation` is `.dnsFailing` or `.webBlocked`)
uses yellow, matching the yellow dot.

## 3. Backend change: router latency

`Diagnostics` pings the router every 5 s but drops the RTT. Keep it:

- Add `var gatewayRTT: TimeInterval?` to `Diagnostics.Snapshot`.
- In `setGateway(_:)`, inside `pinger.onResult`, set `snapshot.gatewayRTT = ok ? rtt : nil`.
- Reset it to nil when the gateway changes and in `onFailure`.

Nothing else in the backend changes. DNS stays a yes / no check, there is no
per hop path measurement, and there is no pause feature in this scope.

## 4. Visual tokens

| Token | Value | Use |
|---|---|---|
| stage | `#000000` | Popover background, nub |
| surface | `#161616` | Tiles, icon buttons |
| surface hover | `#1D1D1D` | Tile hover |
| hairline | white 10 % | Popover border |
| text | `#FFFFFF` | Primary |
| text 2 | `#B3B3B3` | Cause line, status row |
| text 3 | `#6B6B6B` | Labels, units, inactive tabs |
| green | `#00C076` | Healthy |
| yellow | `#FFB020` | Unstable |
| red | `#FF4D4D` | Down, lost pings |
| icon well | status colour at 14 %, grey states white 6 % | Diagnostic icon background |

**Type.** The design system font is Manrope. For v1 use the system font (SF Pro)
with `.monospacedDigit()` everywhere numbers appear; it ships with macOS and needs
no build script change. Weights: 800 maps to `.heavy`, 700 to `.bold`, 600 to
`.semibold`. Bundling Manrope (OFL licence) can follow later.

| Element | Size / weight | Notes |
|---|---|---|
| Hero number | 84 / bold, tracking −0.045 em, line height 0.9 | Unit 22 / semibold, text 3, baseline aligned, 8 pt gap |
| Headline | 17 / bold | 14 pt below hero |
| Cause | 13 / regular, text 2, line height 1.45 | 4 pt below headline |
| Status row | 13 / semibold | Dot 8 pt |
| Section labels | 12 / semibold, text 3 | |
| Tabs | 13, active bold white, inactive medium text 3 | No underline, contrast only |
| Tile value | 22 / heavy, tracking −0.03 em | |
| Diagnostic value | 14 / bold | |
| Pill | 14 / bold, black on white | |

**Layout.** Width 380 pt. Padding 22 top, 20 sides and bottom. Corner radius 24.
Border 1 pt hairline. Shadow black 55 %, radius 80, y 30. Nub 14 pt square rotated
45°, radius 3. Settings button 36 pt circle. Chart 338 × 96 pt, 2 pt line, end dot
3.5 pt with halo. Tiles radius 18, padding 14, 10 pt gaps, two columns. Diagnostic
icon well 36 pt, radius 12. Pill 46 pt high, fully round, shadow black 55 % radius
30 y 8. Spacing between sections: chart 20 below cause, tabs row 12 below chart,
targets 20 below tabs, diagnostics 10 below targets, pill 16 below diagnostics.

## 5. Motion

One curve everywhere: `timingCurve(0.2, 0.8, 0.2, 1)`. No springs with bounce.

| Moment | Animation |
|---|---|
| Open | Whole panel: opacity 0 to 1, scale 0.94 to 1, y −10 to 0, 320 ms, anchored at the nub |
| Stagger | Each section: opacity 0 to 1, y 10 to 0, 440 ms. Delays: hero 60, headline 100, cause 120, chart 160, targets 220, diagnostics 280, pill 340 ms |
| Chart on open | `trim(from: 0, to: p)` with p 0 to 1 over 1.2 s, starting at 160 ms. Live updates afterwards are not animated |
| Live dot | Ring behind the dot: scale 1 to 2.8, opacity 0.55 to 0, 1.6 s ease out, forever |
| Chart end dot | Halo: scale 0.4 to 1.7, opacity 0.5 to 0, 1.6 s ease out, forever |
| Bars | Height changes 350 ms |
| Status colour | All status colours cross fade in 400 ms |
| Press | Scale 0.97 on pill and buttons |
| Close | Opacity to 0 in 150 ms |

**Reduced motion.** When `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
is on, skip open, stagger, draw and pulse animations and show the final state.

**Cost.** Repeating animations run only while the panel is visible. Idle CPU with
the panel closed must stay where it is today (about 0.2 %).

## 6. Interaction and accessibility

- Left click on the status item toggles the panel. Right click or control click opens the old menu.
- Hover: tiles lighten to surface hover, the pill darkens to brightness 0.92, icon buttons lighten.
- "Use symbols instead of colours" (`Settings.monochrome`): the status dot shows ✓, ! or ✕ and every diagnostic tile shows a ✓ or ✕ next to its value, so no state relies on colour alone.
- Every control is a real button with a VoiceOver label. The chart is decorative; expose the hero number and headline as the accessible summary.

## 7. Copy

Keep the app's English strings from `headline(for:)` and `subtitle(for:)`. The
design exploration on the canvas used German placeholder copy; that was not a
request to localise.

## 8. Acceptance

1. `./Scripts/build-app.sh && open build/PingDot.app` builds and runs on macOS 13+.
2. Add a debug only switch, for example the environment variable
   `PINGDOT_FAKE_STATE=ok|warn|down`, that feeds simulated states into the model.
   Use it to screenshot all three states and compare them side by side with
   `mockup.html`.
3. No regressions: menu bar icon and latency text, tooltip, the old menu on right
   click, all settings, Copy diagnostics, Launch at login, update check.
4. Closed panel: no timers or animations running.
5. Add a line to `CHANGELOG.md`.

Out of scope: the "path" variant (Mac, router, internet chain), DNS timing,
provider hop detection, a pause button.
