# Trying and installing tatami

tatami has run live on one Mac for one session. Try it by hand before making it the
window manager that starts at login.

## If option keys type characters

Run `tatami check`. If it says Secure Input is on, macOS is withholding every hot key whose
only modifiers are option and shift (option-f, option-1, option-shift-1) from every
application, and the key types its character instead. Locking and unlocking the screen
usually releases a Secure Input that is stuck. The process `tatami check` names is what
macOS reports, and was seen to follow the frontmost application, so it is not always the
one at fault; `ioreg -l -w 0 | grep SecureInputPID` gave loginwindow at the same time. Hot
keys with cmd or ctrl in them are not affected.

## Try it

```sh
./zig/zig build -Doptimize=ReleaseSafe
./zig-out/bin/tatami check     # permission granted? displays listed?
./zig-out/bin/tatami probe     # what Accessibility reports, and how fast (titles hidden)

# Stop AeroSpace: two window managers would fight over every window.
launchctl bootout gui/$(id -u)/org.nix-community.home.aerospace

./zig-out/bin/tatami start --verbose
```

Go back:

```sh
./zig-out/bin/tatami quit      # or ctrl-c; parked windows return to the screen
./zig-out/bin/tatami rescue    # if anything is still off screen
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.nix-community.home.aerospace.plist
```

The terminal that starts tatami needs Accessibility permission (System Settings > Privacy &
Security > Accessibility).

## Run at login (home-manager)

Not applied anywhere. Accessibility permission is tied to the binary's path, so install the
binary at a path that does not change on every rebuild.

```nix
{ config, ... }:
{
  launchd.agents.tatami = {
    enable = true;
    config = {
      ProgramArguments = [ "${config.home.homeDirectory}/.local/bin/tatami" "start" ];
      RunAtLoad = true;
      KeepAlive = { SuccessfulExit = false; };
      ProcessType = "Interactive";
      StandardOutPath = "/tmp/tatami.log";
      StandardErrorPath = "/tmp/tatami.log";
    };
  };
  # Remove programs.aerospace (or its launchd agent) in the same change.
}
```

`KeepAlive.SuccessfulExit = false` restarts tatami after a crash but not after
`tatami quit`.
