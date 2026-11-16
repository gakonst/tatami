#!/bin/sh
# Checks by hand that tatami keeps its windows across the lock screen. While the screen is
# locked, Accessibility reports every window as gone; a manager that believes it forgets
# them all, and the windows of hidden workspaces stay parked off screen.
#
# The check needs the password prompt to show with the display on while the screen is still
# locked: that display change is what used to make tatami read every window. So the screen
# must ask for the password at once (System Settings > Lock Screen, or
# sysadminctl -screenLock immediate -password -), and the display must be woken with a key,
# not Touch ID, and left on the prompt for a few seconds before unlocking.
#
# Usage: scripts/lock-check.sh [path to tatami]. Exits 0 when every window is still followed,
# 1 when some were let go, 2 when the check could not be made.
set -eu
cd "$(dirname "$0")/.."

tatami="${1:-./zig-out/bin/tatami}"
[ -x "$tatami" ] || tatami="$(command -v tatami || true)"
if [ -z "$tatami" ] || [ ! -x "$tatami" ]; then
    echo "no tatami binary: build it, or name it as the first argument" >&2
    exit 2
fi

before="$(mktemp)"
after="$(mktemp)"
ids_after="$(mktemp)"
trap 'rm -f "$before" "$after" "$ids_after"' EXIT

if ! "$tatami" query windows > "$before"; then
    echo "tatami is not running: start it first" >&2
    exit 2
fi
count="$(wc -l < "$before" | tr -d ' ')"
if [ "$count" -eq 0 ]; then
    echo "tatami follows no window: open a few, on more than one workspace" >&2
    exit 2
fi

case "$(sysadminctl -screenLock status 2>&1)" in
    *immediate*) ;;
    *) echo "warning: the screen does not ask for the password at once, so the prompt may" \
            "not show and the check may prove nothing (see the top of this script)" >&2 ;;
esac

start="$(date '+%Y-%m-%d %H:%M:%S')"
echo "tatami follows $count windows."
echo "The display sleeps now. Wait 30 s, wake it with a key (not Touch ID), stay on the"
echo "password prompt for about 10 s, unlock, then come back here."
sleep 2
pmset displaysleepnow
printf 'Press return once the screen is unlocked: '
read -r _
# tatami reads every window again a second after the unlock.
sleep 3

prompt="$(/usr/bin/log show --start "$start" --style compact \
    --predicate 'process == "loginwindow" AND eventMessage CONTAINS "startTimerForUnlockRequest"' \
    2>/dev/null | tail -n +2)"
if [ -z "$prompt" ]; then
    echo "the password prompt never showed: the screen unlocked without it, which proves" \
        "nothing. Make it ask at once and try again." >&2
    exit 2
fi

"$tatami" query windows > "$after"
ids() { cut -f1 "$1" | tr -d ' *' | sort; }
ids "$after" > "$ids_after"
dropped="$(ids "$before" | comm -23 - "$ids_after")"
if [ -z "$dropped" ]; then
    echo "ok: all $count windows are still followed"
    exit 0
fi
echo "let go across the lock:"
for id in $dropped; do
    grep -E "^[ *]?$id	" "$before" | cut -f1,6 | sed 's/^/  /'
done
exit 1
