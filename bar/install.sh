#!/bin/sh
# Builds tatami-bar, copies it to ~/.local/bin and loads a launchd agent that starts it at
# login. Optional: tatami works without it. Needs the Swift compiler from the Xcode command
# line tools (xcode-select --install); tatami itself still needs only Zig.
#
# Clicking a menu-bar app in the bar uses the Accessibility permission. As with tatami, it
# survives rebuilds only when the binary is signed: the identity is taken from
# TATAMI_SIGN_IDENTITY or ~/.config/tatami/sign-identity.
set -eu
cd "$(dirname "$0")/.."

label="xyz.gakonst.tatami-bar"
bin="$HOME/.local/bin/tatami-bar"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/tatami-bar.log"
domain="gui/$(id -u)"

mkdir -p zig-out/bin "$(dirname "$bin")" "$(dirname "$plist")" "$(dirname "$log")"
swiftc -O -o zig-out/bin/tatami-bar bar/tatami-bar.swift

launchctl bootout "$domain/$label" 2>/dev/null || true
cp zig-out/bin/tatami-bar "$bin.new"
identity="${TATAMI_SIGN_IDENTITY:-}"
if [ -z "$identity" ] && [ -f "$HOME/.config/tatami/sign-identity" ]; then
    identity="$(cat "$HOME/.config/tatami/sign-identity")"
fi
if [ -n "$identity" ]; then
    codesign --force --sign "$identity" --identifier "$label" "$bin.new"
    echo "signed as $label with: $identity"
else
    echo "not signed: the Accessibility permission will not survive the next build"
fi
mv -f "$bin.new" "$bin"
"$bin" check || true

if [ -f "$plist" ] && grep -q "<string>$bin</string>" "$plist"; then
    launchctl bootstrap "$domain" "$plist"
    echo "installed $bin, reloaded $label from the plist that was there; log: $log"
    exit 0
fi

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$bin</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
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
