# Trying and installing tatami

tatami has not run against real windows yet. Try it by hand first, at the Mac, with the
screen unlocked.

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
