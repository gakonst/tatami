# What tatami takes from Rex

[Rex](https://www.superlogical.com/rex/docs/automate/cli) is a terminal multiplexer, not a
window manager, but its model is the same shape as ours: a session holds windows (tabs), a
window holds a layout of blocks, and every command names the things it acts on. This is
every part of its documented command line, server API, actions, key bindings and events
that manages a layout, and what tatami does with it. Read from its docs on 2026-11-11.

How the two models line up:

| Rex | tatami |
| --- | --- |
| block (a pane) | window |
| window (a tab) | workspace |
| floating layer | floating window |
| session | the whole desktop; there is one |
| client | does not exist: the manager draws nothing |

## Taken

| Rex | tatami | Notes |
| --- | --- | --- |
| Targets: an id, a label or a position (`-b`, `-w`) | `<window>` is an id, a label or `focused`; `<workspace>` is a number or a label | A label that fits several windows changes nothing and says so. No id suffixes: window ids are short numbers. |
| `rex block rename`, `rex window rename` | `label [<window>] <name>`, `label-workspace <name>`, each with `--clear` | Labels start with a letter and match without regard to case. |
| `rex focus <direction> [--wrap]` | `focus <direction> [--wrap]` | Without `--wrap` focus stops at the edge, or crosses to the next monitor. |
| `rex focus next/prev [--wrap]`, `session.focus_next_pane` | `focus next/prev [--wrap]` | Layout order: tiles, each split's first half before its second, then floating windows. |
| `rex focus <target>`, `session.focus_block` | `focus <window>` | Shows the window's workspace if it is hidden. |
| `rex zoom [block] [--on/--off]` | `zoom [<window>] [--on/--off]` | The same zoom as `toggle zoom-fullscreen`; naming a window focuses it first, as in Rex. |
| `rex move [block] <direction> <anchor> [--ratio]`, `session.move_block` | `move [<window>] <direction> <anchor> [--ratio <percent>]` | Across workspaces too; a floating window joins the layout; focus follows the window if it had it. |
| `rex swap <block> <other>` | `swap <window> <window>` | Only the two trade places. Both must be tiled and on one workspace. |
| `rex split --split <direction> --ratio`, `session.new_split` | `insert <direction> [--ratio <percent>]` | We do not start programs in a split; this says where the next window goes and its share. |
| `session.new_split` with a split as the anchor | `warp <direction>` with nobody on that side | The window spans the whole side. |
| `session.resize_pane` (a ratio) | `resize ratio <percent>` | The focused window's share of its split. |
| `pane.resize` (direction, amount) | `resize left/right/top/bottom <pixels>` | Already there. |
| `pane.balance` | `balance` | Already there. |
| `pane.float`, `session.float_block` with bounds | `float [<window>] [--bounds x,y,w,h]`, `tile [<window>]` | Bounds are fractions of the workspace, as in Rex. |
| `session.resize_layer` | `float --bounds`, `grid`, `move-floating` | |
| `rex block close <block>`, `pane.close_others` | `close [<window>]`, `close-others` | |
| `pane.move_to_tab`, `pane.move_to_new_tab` | `send <workspace>`, `send new` | Already there; workspaces can now be named by label. |
| `rex window focus <window/next/prev>` | `workspace <workspace>` | Already there. |
| `rex ls`, `block ls`, `window ls` with `--json` | `query windows/workspaces/monitors/focus/stats [--json]` | JSON strings are escaped; a title cut mid-character ends in question marks. |
| `rex block inspect` | `query window [<window>] [--json]` | |
| `session.view` and its revision | `query tree [--json]` | Splits, shares and windows of every workspace in use. The revision goes up by one for each step that changes anything a query can show. |
| `rex keymap` | `query bindings [--json]`, `query modes [--json]` | As the configuration wrote them. |
| `rex actions`, `rex api list` | `query commands [--json]`, `tatami help` | |
| `rex events [--json]` | `tatami events [--json]` | See below. |
| `rex wait <target> [--for]` | `tatami wait <window> [--for <seconds>]` | Returns 0 when the window has closed, 1 when the time ran out. |
| Exit statuses | The same | 0 done, 1 failed, 2 not a command, 3 no such window or workspace (or several), 4 the manager is not running. Errors go to stderr. |
| Key modes (`client.mode.enter`) | `bind mode:<name>` and `mode <name>` | Already there, from zwm. |
| `rex config check`, `rex config reload` | `tatami check`, `reload` | Already there. A file with errors is rejected whole. |

## Events

`tatami events` prints one line for everything that changes, until it is interrupted or the
manager stops. Up to eight can follow at once. A follower that reads too slowly to take a
line whole is dropped rather than waited for.

| Line | With `--json` | When |
| --- | --- | --- |
| `window_created <id>` | `{"type":"window_created","window":186}` | A window is taken on. |
| `window_closed <id>` | `{"type":"window_closed","window":186}` | A window is gone. |
| `focus_changed <id>` | `{"type":"focus_changed","window":186}` | Focus moved; 0 or `null` when no window has it. |
| `workspace_changed <n>` | `{"type":"workspace_changed","workspace":2}` | Another workspace is in use. |
| `view_changed <revision>` | `{"type":"view_changed","revision":57}` | Anything a query can show changed. Ask `query tree` for it. |
| `mode_changed <name>` | `{"type":"mode_changed","mode":"service"}` | The set of key bindings changed. |
| `config_reloaded` | `{"type":"config_reloaded"}` | The configuration was read again. |
| `secure_input_on`, `secure_input_off` | `{"type":"secure_input_on"}` | Secure Input was taken or given back. While it is on, hot keys with only option or option-shift do not fire. |
| `overflow` | `{"type":"overflow"}` | One step changed more than 15 things: query again. |

Events carry ids, never titles.

## Not taken

- **Key sequences** (`ctrl+b>c`), **one-shot modes** (`once`) and Escape leaving a mode. They
  fit our hot keys and are worth doing; not done yet.
- **Exclusive modes**, which swallow every key the mode does not bind. Hot keys cannot do
  that; it would take an event tap, which Secure Input turns off.
- **Minimizing floating layers** (`pane.minimize_floating`, `session.set_layer_state`). Hiding
  floating windows on a workspace that is showing would park them the way hidden
  workspaces do, and that state runs through most of the engine. macOS has its own
  minimize, which we follow.
- **Raising and lowering layers.** Accessibility can raise a window and cannot lower one.
  `focus <window>` raises.
- **Swapping windows across workspaces.** `move` and `send` cross workspaces; `swap` does not.
- **Reordering tabs and sessions** (`window move`, `session move`). Workspaces are numbers.
- **Declaring a whole layout** (`session.create` with a layout). We place windows that
  applications open; we do not start them.
- **Everything about terminals, clients and servers**: send, capture, run, hosts, Tailscale,
  the Lua API, the program status protocol.
