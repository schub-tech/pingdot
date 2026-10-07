# Release runbook

PingDot ships through two lanes from the same code:

| Lane | Signing | Sandbox | Goes to |
|---|---|---|---|
| `github` | Developer ID, notarized | yes | GitHub release → Homebrew cask |
| `appstore` | Apple Distribution | yes | App Store Connect → review |

The GitHub build contains a daily update check against the GitHub releases API
(`UpdateChecker.swift`). The App Store build is compiled with `-D APP_STORE`,
which removes it — App Store apps must not offer another update channel.
`release.sh appstore` refuses to continue if `api.github.com` is still in the
binary.

Both run locally via `Scripts/release.sh` — no CI, so the signing keys never
leave the Mac.

## One-time setup

1. **Certificates** (developer.apple.com → Certificates; Developer ID can only be
   created by the Account Holder). Create them *after* the membership runs under
   Schuon Technologies GmbH — the name is baked into the certificate and shows up
   in Gatekeeper:
   - Developer ID Application
   - Apple Distribution
   - Mac Installer Distribution
2. **App ID:** register `tech.schub.pingdot` (macOS, no capabilities).
3. **Provisioning profile:** Distribution → Mac App Store Connect, App ID
   `tech.schub.pingdot`, the Apple Distribution certificate. Download it to
   `Resources/PingDot.provisionprofile` (gitignored).
4. **App Store Connect:** new macOS app — name *PingDot*, bundle ID
   `tech.schub.pingdot`, SKU `pingdot`, primary language English. Category
   Utilities, price free, privacy "Data Not Collected", privacy policy URL →
   `PRIVACY_POLICY.md` (or the landing page).
5. **`.release.env`:** copy `.release.env.example` and fill in team ID and the App
   Store Connect API key (the `.p8` lives in `~/.private_keys/`).
6. **Homebrew tap:** public repo `schub-tech/homebrew-tap` with a `Casks/` folder.
   Users then run `brew install schub-tech/tap/pingdot`. The official
   `homebrew/cask` only accepts reasonably well-known repos — revisit once the
   repo has some stars.

**Certificates in use (created 2026-10-07):** Developer ID Application and Mac
Installer Distribution run under Schuon Technologies GmbH. The Developer ID
certificate expires **2027-02-01** — renew it before then (already notarized
downloads keep working). Apple Distribution is the older one from 2026-09-13
(name of the individual account, invisible to users); profile
"PingDot Mac App Store" is valid until 2027-09-13.

## Before every release

- `swift build -c release` without warnings.
- `./.build/release/PingDot --selftest` shows ICMP and TCP working.
- Sandboxed ICMP still works: build with a real identity
  (`SIGN_ID="Apple Development" ./Scripts/build-app.sh`) and run
  `build/PingDot.app/Contents/MacOS/PingDot --selftest 1.1.1.1` — ICMP must say
  "works". Without `com.apple.security.network.server` the replies never arrive.
- Click through the menu once: targets, method switch, Copy diagnostics, About.
- Add a `## <version>` section to `CHANGELOG.md` — it becomes the release notes.

## Release

```sh
./Scripts/release.sh github 0.1.0     # tag, GitHub release, updates packaging/homebrew/pingdot.rb
./Scripts/release.sh appstore 0.1.0   # uploads the .pkg to App Store Connect
```

Then copy `packaging/homebrew/pingdot.rb` into the tap repo, and in App Store
Connect pick the uploaded build and submit it for review.

## App Review notes

Paste this into *App Review Information → Notes*:

> PingDot shows internet connectivity as a dot in the menu bar. It sends ICMP
> echo requests over an unprivileged datagram socket (SOCK_DGRAM / IPPROTO_ICMP).
> Inside the App Sandbox, receiving the echo replies on that socket requires
> com.apple.security.network.server. PingDot does not open a listening port and
> does not accept incoming connections.
