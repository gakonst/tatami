# Design

## Layers

```
macOS notifications ──► shell (src/macos) ──► event ──► engine.step ──► effects ──► shell ──► macOS
                                                           ▲
                                  simulator (src/sim.zig) ─┘  the same engine, a fake macOS
```

| Layer | Files | Rule |
|---|---|---|
| Engine | `engine.zig`, `tree.zig`, `command.zig`, `config.zig`, `geometry.zig` | Pure. No system calls, no clock, no allocation. Time arrives as an argument. |
| Shell | `macos/shell.zig`, `ax.zig`, `ipc.zig`, `c.zig` | Translates only. Holds no layout state and makes no decisions. |
| Simulator | `sim.zig`, `sim_main.zig`, `scenarios.zig` | Plays macOS, badly, from a seed. |

Everything is single-threaded. The shell runs one CFRunLoop; every callback turns into one
`engine.step` call, whose effects are performed before the next event is read.

## The engine

`step(event, now_ms) -> []Effect`.

Events: monitors changed, app launched / terminated / unresponsive, window appeared /
destroyed / frame applied / frame changed / title changed / minimized / fullscreen / tab
changed / focused, focus reported, command, tick.

Effects: set frame, focus window, close window, warp mouse, exec, query focus, reload, quit.

Layout is a binary space partition per workspace, kept in one static pool of nodes
(`tree.zig`). Tree walks are iterative; nothing recurses.

The rules that make it behave:

| Rule | Value |
|---|---|
| A frame is sent only when the target changed | — |
| Retries when a frame did not take | 2, then the window's own size is accepted |
| Time an app may animate before a wrong frame is corrected | 150 ms |
| Corrections before a window that fights the layout is floated | more than 4 in 3 s |
| Backoff for an app whose Accessibility call timed out | 250 ms doubling to 8 s |
| Title rules keep applying after a window appears | 3 s |
| A window sent away by a rule may not pull focus back for | 1.5 s |
| An unconfirmed focus request expires and focus is asked for again after | 500 ms |
| A parked window that macOS lifts | the lift is remembered per window, never retried |
| A hidden application that repeats the focus it already had | ignored |

Focus is optimistic: a command updates the engine's idea of focus at once and the request to
the OS is queued as pending. An echo confirms it. If the echo never comes, or the window is
destroyed first, the engine asks the OS where focus really is instead of guessing.

## Limits

Static, checked by assertions, and reported in `tatami query stats` when hit.

| What | Limit |
|---|---|
| Windows | 256 |
| Applications | 128 |
| Workspaces | 16 |
| Monitors | 8 |
| Effects per step | 1024 |
| Bindings and rules | see `config.zig` |

## Protocols implemented

| Protocol | Use |
|---|---|
| Accessibility (AXUIElement, AXObserver) | Per app: window created, focused window changed, main window changed. Per window: destroyed, moved, resized, title changed, miniaturized, deminiaturized. Frames are read and written through position and size; focus through main, raise and frontmost. A frame whose size is already right is only moved, which is all a workspace switch needs. |
| Accessibility messaging timeout | 250 ms for every call in the process. An app that hits it is suspended by the engine, so one hung app delays only its own windows. |
| `AXEnhancedUserInterface` | Turned off around a frame change so apps driven by assistive software do not animate it. |
| `_AXUIElementGetWindow` (private) | The window id. The only private call. |
| Carbon hot keys (`RegisterEventHotKey`) | Global bindings without an event tap or Input Monitoring permission. A registered key is consumed, so option-f cannot type "ƒ". Failures are printed, never silent. |
| Carbon application events | Launched, terminated, front switched. |
| Quartz display reconfiguration | Monitors added, removed, rearranged or asleep. Debounced. |
| Mouse | The button state is polled every 30 ms only while a window is being dragged, to tell a drag in progress from a finished one. |
| Secure Input (`IsSecureEventInputEnabled`) | Read at startup and by `tatami check`, with the process that holds it. While it is held, option-only hot keys cannot fire. |
| Unix socket `/tmp/tatami-<uid>.sock` | One line in, one reply out. The client gives up after 2 s; the server reads with a 100 ms timeout. `exec` is refused over the socket. |
| Signals | SIGINT and SIGTERM restore parked windows and quit. On a fatal signal the process replaces itself with `tatami rescue`. |

## The simulator

`tatami-sim <seed> <steps>` drives the real engine with a generated workload: apps and
windows opening and closing, native tabs, dialogs and popups, every command in the language,
monitors plugged and unplugged, minimize, user drags.

Faults it injects:

- Apps that stop answering.
- Windows with a minimum size that never take the frame asked for.
- Windows that move themselves back.
- Windows that animate and report frames on the way.
- Titles that arrive late.
- Windows that macOS lifts by 28, 32 or 40 pixels when they are parked below the screen
  (seen live: the title bar must stay reachable).
- Notifications that are late, duplicated, or about windows that are gone.

After every quiet moment it asserts:

- The engine's picture of every window's frame and minimized state is the real one.
- Every managed window is exactly where the engine wants it, as far as its minimum size
  allows.
- Hidden windows show at most a one pixel sliver.
- Popups are never tracked, and nothing else is missed.
- No window is sent more than two frames for one event.
- Engine focus and OS focus agree, unless the OS-focused window is on a hidden workspace or
  another monitor.
- At the end, with every window closed, nothing is left: no windows, no tree nodes, no focus.

A failing seed replays exactly. `scripts/sim-find.sh first last steps` prints the first
failing seed and the tail of its trace.

## Style

TigerStyle: assertions on arguments and invariants, static allocation only, no recursion,
bounded loops, functions of 70 lines or fewer, lines of 100 columns or fewer, no
dependencies beyond the Zig toolchain.
