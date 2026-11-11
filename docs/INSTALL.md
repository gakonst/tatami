# Trying and installing tatami

tatami has run live on one Mac for one session. Try it by hand before making it the
window manager that starts at login.

## If option keys type characters

Run `tatami check`. If it says Secure Input is on, macOS is withholding every character key
bound with only option or option-shift (option-f, option-1, option-shift-1) from every
application, tatami and AeroSpace alike, and the key types its character instead. Keys
bound with cmd or ctrl, and arrow keys, are not affected.

When the holder is loginwindow, it is a macOS bug, seen on 26.3.1: at every lock screen
loginwindow takes Secure Input eight to ten times and gives it back once, so it stays on
for as long as loginwindow lives. Locking and unlocking again adds to it. Only logging out
and in again, or restarting, clears it, and the next lock screen brings it back. The log
shows it:

```sh
/usr/bin/log show --last 1h --predicate \
  'process == "loginwindow" AND eventMessage CONTAINS "CGSSetSecureEventInput"'
```

When the holder is another application, leave its password field or quit it.

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

## Run at login

```sh
./scripts/install.sh      # build, copy to ~/.local/bin/tatami, load the launchd agent
./scripts/uninstall.sh    # stop it, bring parked windows back, remove both
```

The first start asks for the Accessibility permission and waits; once tatami is allowed
in System Settings > Privacy & Security > Accessibility it starts by itself. The log is
`~/Library/Logs/tatami.log`.

- After a crash launchd starts it again, once parked windows are back on screen. After
  `tatami quit` it stays stopped until
  `launchctl kickstart gui/$(id -u)/xyz.gakonst.tatami`.
- The permission belongs to the exact binary. After installing a new build macOS may list
  tatami as allowed and still refuse it: remove it from the list and allow it again.

## Run at login (home-manager)

The same agent as a home-manager module. Not applied anywhere. Install the binary at a
path that does not change on every rebuild, for the reason above.

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
