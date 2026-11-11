#!/bin/sh
# Installs tatami as the window manager that starts at login: builds it, copies it to
# ~/.local/bin and loads a launchd agent. The first start asks for the Accessibility
# permission and waits until it is granted.
#
# Accessibility is granted to this exact binary. After installing a new build, macOS may
# show tatami as allowed while refusing it: remove tatami from the list and allow it again.
set -eu
cd "$(dirname "$0")/.."

label="xyz.gakonst.tatami"
bin="$HOME/.local/bin/tatami"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/tatami.log"
domain="gui/$(id -u)"

./zig/zig build -Doptimize=ReleaseSafe

launchctl bootout "$domain/$label" 2>/dev/null || true
mkdir -p "$(dirname "$bin")" "$(dirname "$plist")" "$(dirname "$log")"
cp zig-out/bin/tatami "$bin.new"
mv -f "$bin.new" "$bin"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$bin</string><string>start</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$domain" "$plist"
echo "installed $bin, loaded $label; log: $log"
