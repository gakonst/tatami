#!/bin/sh
# Stops tatami and removes its launchd agent and binary. Parked windows come back first.
set -eu
label="xyz.gakonst.tatami"
bin="$HOME/.local/bin/tatami"
[ -x "$bin" ] && "$bin" quit >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
[ -x "$bin" ] && "$bin" rescue >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$bin"
echo "removed $label"
