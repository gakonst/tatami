#!/bin/sh
# Stops any running tatami instance (and temporarily unloads the launchd agent if
# active), runs the local build in the foreground, and re-bootstraps launchd on exit.
set -eu
cd "$(dirname "$0")/.."

label="xyz.gakonst.tatami"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
was_loaded=0

if [ -f "$plist" ] && launchctl print "$domain/$label" >/dev/null 2>&1; then
    was_loaded=1
fi

restore() {
    if [ "$was_loaded" -eq 1 ] && [ -f "$plist" ]; then
        launchctl bootstrap "$domain" "$plist" 2>/dev/null || true
    fi
}

trap restore EXIT
trap 'exit 0' INT TERM

./zig-out/bin/tatami quit >/dev/null 2>&1 || true
if [ "$was_loaded" -eq 1 ]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
fi

./zig-out/bin/tatami start --verbose
