#!/bin/sh
# Installs tatami as the window manager that starts at login: builds it, copies it to
# ~/.local/bin and loads a launchd agent. The first start asks for the Accessibility
# permission and waits until it is granted.
#
# Accessibility is granted to a signature. An unsigned build is a new signature every
# time, and macOS then shows tatami as allowed while refusing it: remove tatami from the
# list and allow it again. To keep the permission across builds, name a code signing
# identity of yours (security find-identity -v -p codesigning) in TATAMI_SIGN_IDENTITY or
# in ~/.config/tatami/sign-identity; the first signed install needs the permission once
# more, later ones keep it.
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

# A plist that already starts this binary is left as it is: something else, such as a
# Nix configuration, may own it, and would only put its own back.
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
