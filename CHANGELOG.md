# Changelog

## 0.1.0 — unreleased

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
