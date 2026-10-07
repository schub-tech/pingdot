#!/usr/bin/env bash
# Builds the app and packs it into build/PingDot.zip for copying to another Mac.
#
# `ditto` (not `zip`) because it preserves the bundle structure and the code
# signature — a plain `zip` can break the signature and macOS then refuses to
# launch the app at all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/Scripts/build-app.sh" "${1:-release}"

ZIP="$ROOT/build/PingDot.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/PingDot.app" "$ZIP"

echo
echo "✓ $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo
echo "On the other Mac, after unzipping:"
echo "  xattr -dr com.apple.quarantine /Applications/PingDot.app"
echo "(ad-hoc signed builds are not notarised, so Gatekeeper blocks them otherwise)"
