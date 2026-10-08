# Changelog

## Unreleased

- *Connection history…* in the menu: the last 1, 6 or 24 hours as a chart —
  latency, and when the connection was good, unstable or down. Hover for the
  details of any minute. "How was the Wi‑Fi on the train?" now has an answer.
  The history stays on your Mac (one small file, older than 24 hours is deleted).

## 0.1.2 — 2026-10-08

- Fix: PingDot quit without a word when the network changed (Wi‑Fi switch,
  hotspot, VPN). Writing to a ping socket the system had closed raised SIGPIPE;
  the app now ignores it and opens a fresh socket.

## 0.1.1 — 2026-10-08

- The ping socket is connected to its target. The App Store build no longer
  needs the network server entitlement, and replies to other apps' pings no
  longer reach PingDot.

## 0.1.0 — 2026-10-07

First public release.

- Menu bar dot: green / yellow / red from ICMP pings, with TCP connect as a
  fallback for networks that block ping.
- Several targets in parallel (1.1.1.1 + 8.8.8.8 by default); red only once all
  of them are gone.
- Diagnostics in the menu: network interface, router, DNS, HTTPS — plus a
  plain-language verdict and *Copy diagnostics*.
- Yellow when pings get through but DNS or HTTPS fail; networks that block ping
  but reach the web show yellow with a hint to switch to TCP, not red.
- Hostname targets are looked up again every minute and retried while DNS is down.
- GitHub/Homebrew version: daily check for a newer release (can be turned off).
- Universal build (Apple silicon and Intel), macOS 13 or later.
