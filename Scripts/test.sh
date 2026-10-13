#!/usr/bin/env bash
# Tests PingDot: the logic, and what it costs while it runs. No Xcode needed.
#
#   ./Scripts/test.sh          # checks + CPU measurement (about a minute)
#   ./Scripts/test.sh quick    # checks only
#
# The measurement starts the debug build three times for a few seconds each —
# once as usual, twice with the popover open on simulated states — and fails when
# a run needs more CPU than its budget. A second dot shows up in the menu bar
# meanwhile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Percent of one core, debug build. Measured on an M-series MacBook: about 1.0
# closed, 3 to 4 open, 1.5 open while offline. A release build needs less.
BUDGET_CLOSED=2.0
BUDGET_OPEN=6.0
SETTLE=6     # s to let launch and the open animation pass
WINDOW=15    # s measured

./Scripts/build-app.sh debug >/dev/null
BIN="$ROOT/build/PingDot.app/Contents/MacOS/PingDot"

"$BIN" --check

[ "${1:-}" = quick ] && exit 0

cpu_seconds() {
  ps -o time= -p "$1" | awk -F'[:.]' '{ print $1 * 60 + $2 + $3 / 100 }'
}

failed=0
measure() {   # label, budget, [VAR=value …]
  local label="$1" budget="$2"; shift 2
  env "$@" "$BIN" >/dev/null 2>&1 &
  local pid=$!
  sleep "$SETTLE"
  local before; before=$(cpu_seconds "$pid")
  sleep "$WINDOW"
  local after; after=$(cpu_seconds "$pid")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  local percent; percent=$(echo "($after - $before) / $WINDOW * 100" | bc -l)
  if [ "$(echo "$percent <= $budget" | bc -l)" = 1 ]; then
    printf '  ok    %-28s %5.2f %% CPU (budget %s %%)\n' "$label" "$percent" "$budget"
  else
    printf '  FAIL  %-28s %5.2f %% CPU (budget %s %%)\n' "$label" "$percent" "$budget"
    failed=1
  fi
}

echo
echo "CPU"
measure "popover closed" "$BUDGET_CLOSED" PINGDOT_FAKE_STATE=
measure "popover open, healthy" "$BUDGET_OPEN" PINGDOT_FAKE_STATE=ok
measure "popover open, offline" "$BUDGET_OPEN" PINGDOT_FAKE_STATE=down

[ "$failed" = 0 ] && echo && echo "All within budget."
exit "$failed"
