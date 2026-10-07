# Contributing

Bug reports and pull requests are welcome.

- **Bugs:** open an issue and paste the output of *Copy diagnostics* from the
  PingDot menu — it shows what the probes saw. For network-specific problems
  `PingDot --selftest` helps too (see the README).
- **Pull requests:** keep them small and focused. PingDot is deliberately a
  one-question app; features that turn it into a network monitoring suite are
  unlikely to be merged — better open an issue first and let's talk.
- **Build:** `./Scripts/build-app.sh`, no Xcode project needed. Check that
  `swift build -c release` passes without warnings.
- **Privacy:** no analytics, telemetry or third-party SDKs. This is a promise to
  our users, not a missing feature.

By contributing you agree that your contribution is licensed under the MIT license.
