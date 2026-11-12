#!/bin/sh
# Stops tatami-bar and removes what bar/install.sh installed. Leaves bar.conf alone.
set -u
label="xyz.gakonst.tatami-bar"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/tatami-bar"
echo "removed tatami-bar"
