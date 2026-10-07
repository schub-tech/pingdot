#!/usr/bin/env bash
# Ships PingDot. Two lanes, run from a clean working tree:
#
#   ./Scripts/release.sh github 0.1.0     # Developer ID → notarize → GitHub release + Homebrew cask
#   ./Scripts/release.sh appstore 0.1.0   # Apple Distribution → .pkg → App Store Connect
#
# The version is optional; without it the version in Info.plist ships as is. The
# build number goes up by one on every run (App Store Connect rejects repeats).
# Local on purpose, no CI: the signing keys never leave this Mac.
#
# One-time setup (certificates, profile, .release.env): docs/RUNBOOK.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LANE="${1:-}"
VERSION="${2:-}"
case "$LANE" in github|appstore) ;; *) echo "usage: $0 github|appstore [version]" >&2; exit 64 ;; esac

die() { echo "✗ $*" >&2; exit 1; }

[ -f .release.env ] && source .release.env
: "${TEAM_ID:?set TEAM_ID in .release.env}"
: "${ASC_KEY_ID:?set ASC_KEY_ID in .release.env}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in .release.env}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$ASC_KEY_PATH" ] || die "App Store Connect API key not found at $ASC_KEY_PATH"

git diff --quiet && git diff --cached --quiet || die "working tree not clean — commit or stash first"

# --- version ---------------------------------------------------------------
PLIST=Resources/Info.plist
plist() { /usr/libexec/PlistBuddy "$@" "$PLIST"; }
[ -n "$VERSION" ] && plist -c "Set :CFBundleShortVersionString $VERSION"
VERSION="$(plist -c 'Print :CFBundleShortVersionString')"
BUILD=$(( $(plist -c 'Print :CFBundleVersion') + 1 ))
plist -c "Set :CFBundleVersion $BUILD"
echo "→ PingDot $VERSION ($BUILD), lane: $LANE"

# Release notes = the CHANGELOG section of this version.
NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## \\[?" v "\\]?( |$)" { on = 1; next }
  on && /^## / { exit }
  on { print }' CHANGELOG.md)"
[ -n "$NOTES" ] || die "no '## $VERSION' section in CHANGELOG.md"

commit() {
  git add "$@"
  git commit -q -m "Release $VERSION ($BUILD, $LANE)"
}

# --- GitHub: Developer ID + notarization -----------------------------------
if [ "$LANE" = github ]; then
  SIGN_ID="${DEVELOPER_ID:-Developer ID Application}" ./Scripts/build-app.sh release

  ZIP="build/PingDot-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent build/PingDot.app "$ZIP"
  echo "→ notarizing (takes a few minutes)"
  xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --wait
  xcrun stapler staple build/PingDot.app
  # Zip again so the download carries the stapled ticket (works offline).
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent build/PingDot.app "$ZIP"
  spctl --assess --type execute -vv build/PingDot.app

  SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" -e '/^# Template/d' \
    packaging/homebrew/pingdot.rb.in > packaging/homebrew/pingdot.rb

  commit "$PLIST" packaging/homebrew/pingdot.rb
  git tag -a "v$VERSION" -m "PingDot $VERSION"
  git push -q origin HEAD "v$VERSION"
  gh release create "v$VERSION" "$ZIP" --title "PingDot $VERSION" --notes "$NOTES"

  echo "✓ GitHub release v$VERSION"
  echo "  Homebrew: copy packaging/homebrew/pingdot.rb to schub-tech/homebrew-tap/Casks/"
fi

# --- App Store: sandboxed build, installer package, upload -----------------
if [ "$LANE" = appstore ]; then
  PROFILE="${PROFILE:-Resources/PingDot.provisionprofile}"
  [ -f "$PROFILE" ] || die "provisioning profile missing: $PROFILE (see docs/RUNBOOK.md)"

  # Outside Xcode nobody adds the identifiers the profile is matched against.
  ENT="build/appstore.entitlements"
  mkdir -p build
  cp Resources/PingDot.entitlements "$ENT"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $TEAM_ID.tech.schub.pingdot" \
    -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENT"

  APP_STORE=1 SIGN_ID="${DISTRIBUTION_ID:-Apple Distribution}" ENTITLEMENTS="$ENT" PROFILE="$PROFILE" \
    ./Scripts/build-app.sh release
  # The App Store forbids other update channels — make sure the checker is gone.
  if strings build/PingDot.app/Contents/MacOS/PingDot | grep -q api.github.com; then
    die "update checker found in the App Store build"
  fi

  PKG="build/PingDot-$VERSION.pkg"
  productbuild --component build/PingDot.app /Applications \
    --sign "${INSTALLER_ID:-3rd Party Mac Developer Installer}" "$PKG"

  echo "→ uploading to App Store Connect"
  xcrun altool --upload-app --type macos -f "$PKG" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

  commit "$PLIST"
  git push -q origin HEAD

  echo "✓ uploaded $VERSION ($BUILD) — pick the build in App Store Connect and submit for review"
fi
