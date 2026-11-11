# tatami

A tiling window manager for macOS, written from scratch in Zig. No dependencies: the only
thing the build needs is the pinned Zig toolchain, and the binary links only system
frameworks.

It exists because AeroSpace kept hanging, looping and re-tiling windows it should have left
alone. See [docs/COMPLAINTS.md](docs/COMPLAINTS.md) for each complaint and the behaviour
that answers it.

## Status

| Part | State |
|---|---|
| Engine (layout, focus, workspaces, rules) | Verified by unit tests, scenario tests and a deterministic simulator |
| macOS shell (Accessibility, hot keys, displays, IPC) | Starts, adopts apps, registers all hot keys, answers the CLI. **Not yet run against real windows.** |

Do not replace your window manager with it before trying it by hand: see
[docs/INSTALL.md](docs/INSTALL.md).

## Design in one paragraph

The window manager is a pure state machine: `engine.step(event, now) -> effects`. It never
blocks, allocates or calls the operating system. A thin shell turns macOS notifications into
events and performs the effects. Because the engine is pure, the simulator can drive it
through millions of events with a hostile fake macOS (apps that hang, refuse frames, move
themselves, report late or twice) and check after every quiet moment that every window is
exactly where the engine says it should be. See [docs/DESIGN.md](docs/DESIGN.md).

## Build

```sh
./zig/download.sh                       # Zig 0.17.1, checksummed, into ./zig
./zig/zig build -Doptimize=ReleaseSafe  # zig-out/bin/tatami and zig-out/bin/tatami-sim
./zig/zig build test --summary all      # unit and scenario tests
./scripts/sim-find.sh 1 3000 5000       # seeds 1..3000, 5000 steps each
```

Apple Silicon macOS only.

## Use

```sh
tatami check            # permission, configuration, displays
tatami probe            # what Accessibility reports for every window, and how fast
tatami start --verbose  # run in the foreground
tatami focus west       # any command from the config also works from the CLI
tatami query windows    # windows | workspaces | monitors | focus | stats
tatami reload           # re-read the config; a file with errors is rejected as a whole
tatami quit             # brings every parked window back, then exits
tatami rescue           # the same, without a running daemon
tatami bench            # engine latency per command
tatami default-config   # print the built-in configuration
```

The configuration is one file, `~/.config/tatami/tatami.conf`. Without it the built-in
[src/default.conf](src/default.conf) applies: the yabai/skhd bindings, with option-N to
switch workspace and option-shift-N to send a window there.

## What it does not do

- No binding modes (AeroSpace's "service" mode). `retile` is on ctrl-alt-cmd-t.
- No window borders, opacity, topmost or picture-in-picture: those need SIP disabled.
- Hot keys do not repeat while held.
- Workspaces are virtual: hidden windows are parked in a corner, as in AeroSpace. Native
  Spaces are left alone.
