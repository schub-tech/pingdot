#!/usr/bin/env bash
# Builds build/PingDot.app from the SwiftPM package. No Xcode needed.
#
#   ./Scripts/build-app.sh            # release build, ad-hoc signed
#   ./Scripts/build-app.sh debug      # debug build
#   SIGN_ID="Developer ID Application" ./Scripts/build-app.sh
#
# Release builds are universal (Apple silicon + Intel). Scripts/release.sh sets
# APP_STORE, ENTITLEMENTS and PROFILE for the App Store build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
OUT="$ROOT/build/PingDot.app"
# The repo may live in an iCloud-synced folder, where Finder info can reappear on
# the bundle at any moment and make codesign fail. Assemble and sign outside of it.
WORK="$(mktemp -d /tmp/pingdot-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/PingDot.app"
SIGN_ID="${SIGN_ID:--}"   # "-" = ad-hoc
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/Resources/PingDot.entitlements}"
PROFILE="${PROFILE:-}"    # embedded.provisionprofile, App Store only

ARCHS=()
[ "$CONFIG" = release ] && ARCHS=(--arch arm64 --arch x86_64)
# APP_STORE=1 compiles out everything the App Store does not allow (update check).
[ "${APP_STORE:-0}" = 1 ] && ARCHS+=(-Xswiftc -DAPP_STORE)
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/PingDot"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "→ rendering app icon"
  swift "$ROOT/Scripts/make-icon.swift" >/dev/null
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PingDot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -n "$PROFILE" ] && cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# Copied files can bring extended attributes along, which codesign refuses to sign.
xattr -cr "$APP"

# Ad-hoc builds stay unsandboxed on purpose: the sandbox needs a real signing
# identity, and ICMP is what we want to exercise locally.
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP"
fi

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ditto --noextattr --norsrc "$APP" "$OUT"

echo "✓ $OUT"
echo "  open $OUT        # run it"
echo "  cp -R $OUT /Applications/   # install"
