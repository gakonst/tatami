//! Scenario tests for the tree, focus, workspace and multi-monitor failures that the i3 and
//! sway bug trackers hold. Each test cites the reports it answers. As in scenarios.zig
//! the real engine runs against the simulated OS with random faults switched off, so every
//! expectation is exact.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const tree = @import("tree.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const WindowId = engine_module.WindowId;
const Mode = engine_module.Mode;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);
// Monitor preset 1 puts a 2560x1440 display to the right of the laptop.
const external = Rect.init(1728, 38, 2560, 1402);

fn boot(extra_config: []const u8) *sim.Simulator {
    var source: [16 * 1024]u8 = undefined;
    const default = config_module.default_source;
    @memcpy(source[0..default.len], default);
    source[default.len] = '\n';
    @memcpy(source[default.len + 1 ..][0..extra_config.len], extra_config);
    var config: config_module.Config = undefined;
    var buffer: [512]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const ok = config.load(source[0 .. default.len + 1 + extra_config.len], &diagnostics);
    std.debug.assert(ok);
    engine.init(&config);
    simulator.init(&engine, .{ .seed = 1, .faults = false });
    return &simulator;
}

/// Opens a window and lets the OS report it, so that windows appear in the order written.
fn open(os: *sim.Simulator, app: i32, options: sim.Simulator.WindowOptions) WindowId {
    const id = os.window_open(app, options);
    os.advance(1);
    return id;
}

fn frame_of(id: WindowId) Rect {
    return simulator.window_find(id).?.frame;
}

fn expect_frame(expected: Rect, id: WindowId) !void {
    const actual = frame_of(id);
    if (!actual.eql(expected)) {
        std.debug.print("window {d}: expected {any}, found {any}\n", .{ id, expected, actual });
        return error.TestUnexpectedResult;
    }
}

/// Hidden windows wait past a bottom corner of the laptop screen.
fn parked(id: WindowId) bool {
    const frame = frame_of(id);
    return frame.overlap(Rect.init(0, 0, 1728, 1117), .x) <= 1;
}

/// Runs a command built from a format string and returns what the engine answered.
fn run(os: *sim.Simulator, comptime format: []const u8, args: anytype) []const u8 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    os.command_run(text);
    return engine.reply();
}

fn expect_reply(prefix: []const u8, reply: []const u8) !void {
    if (std.mem.startsWith(u8, reply, prefix)) return;
    std.debug.print("expected a reply starting with {s}, found {s}\n", .{ prefix, reply });
    return error.TestUnexpectedResult;
}

/// Every display goes to sleep: the shell reports that there are none. Returns how many
/// effects that had, which the simulated OS has no hand in and so cannot perform.
fn sleep(os: *sim.Simulator) usize {
    const effects = engine.step(.{ .monitors_changed = &.{} }, os.now_ms);
    engine.verify();
    return effects.len;
}

/// The workspace a window belongs to, counting from one as the commands do.
fn workspace_of(id: WindowId) u8 {
    return engine.window_find(id).?.workspace + 1;
}

fn expect_focus(os: *sim.Simulator, id: WindowId) !void {
    try testing.expectEqual(id, engine.focused_window);
    try testing.expectEqual(id, os.focused);
}

// Focus after a window goes away.

// https://github.com/i3/i3/issues/1975
// https://github.com/i3/i3/issues/4963
test "closing the focused window gives focus to the window used before it" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, ghostty, .{});
    const b = open(os, zed, .{});
    const c = open(os, ghostty, .{});
    const d = open(os, ghostty, .{});
    os.settle();
    os.window_click(b);
    os.settle();
    os.window_click(d);
    os.settle();
    // macOS would hand focus to another window of the same application: a or c.
    os.window_close(d);
    os.settle();
    try expect_focus(os, b);
    // A window that closes without focus leaves focus alone.
    os.window_close(a);
    os.settle();
    try expect_focus(os, b);
    os.window_close(b);
    os.settle();
    try expect_focus(os, c);
    try expect_frame(screen, c);
}

// https://github.com/swaywm/sway/issues/2951
// https://github.com/i3/i3/issues/2600
test "closing the last window of a workspace leaves it empty and in view" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, ghostty, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, ghostty, .{});
    os.settle();
    try expect_focus(os, b);
    // macOS focuses the application's other window, which is on the hidden workspace.
    os.window_close(b);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expect(parked(a));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    for (0..3) |_| {
        os.advance(1000);
        os.focus_repeat();
        os.settle();
        try testing.expectEqual(@as(u8, 1), engine.workspace_current());
        try testing.expect(parked(a));
    }
    // The next window opens here, not where the application's other window is.
    const c = open(os, ghostty, .{});
    os.settle();
    try expect_frame(screen, c);
    try testing.expectEqual(@as(u8, 2), workspace_of(c));
    try testing.expect(parked(a));
}

// https://github.com/i3/i3/issues/1975
// https://github.com/swaywm/sway/issues/1077
test "focus returns to the tile used before when a floating dialog closes" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    const dialog = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
    os.settle();
    try expect_focus(os, dialog);
    // The dialog took no tile, and the tiles did not move for it.
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(500, 300, 400, 300), dialog);
    os.window_close(dialog);
    os.settle();
    try expect_focus(os, a);
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
}

// https://github.com/swaywm/sway/issues/6457
// https://github.com/i3/i3/issues/3096
test "minimizing the focused window gives focus to the one before, restoring gives it back" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    try expect_focus(os, a);
    try expect_frame(screen, a);
    try expect_reply("error: conflict", run(os, "focus {d}", .{b}));
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ b, a }));
    try expect_reply("error: conflict", run(os, "zoom {d}", .{b}));
    try expect_reply("error: conflict", run(os, "float {d}", .{b}));
    os.window_minimize(b, false);
    os.settle();
    try expect_focus(os, b);
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// Empty containers.

// https://github.com/i3/i3/issues/3001
// https://github.com/i3/i3/issues/5238
// https://github.com/swaywm/sway/issues/6116
// https://github.com/swaywm/sway/issues/7945
test "closing windows collapses their splits and the rest fill the screen" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    const d = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 432, 539), c);
    try expect_frame(Rect.init(1296, 578, 432, 539), d);
    try testing.expectEqual(tree.nodes_max - 7, engine.forest.free_count);
    os.window_close(c);
    os.settle();
    try expect_frame(Rect.init(864, 578, 864, 539), d);
    try testing.expectEqual(tree.nodes_max - 5, engine.forest.free_count);
    os.window_close(b);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, d);
    os.window_close(a);
    os.settle();
    try expect_frame(screen, d);
    try testing.expectEqual(tree.nodes_max - 1, engine.forest.free_count);
    os.window_close(d);
    os.settle();
    try testing.expectEqual(tree.nodes_max, engine.forest.free_count);
    try testing.expectEqual(tree.node_none, engine.workspaces[0].root);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
}

// https://github.com/i3/i3/issues/6597
// https://github.com/i3/i3/issues/3229
// https://github.com/i3/i3/issues/2903
// https://github.com/swaywm/sway/issues/6693
test "every layout command is harmless on an empty workspace and on a lone window" {
    const os = boot("");
    const commands = [_][]const u8{
        "focus west",          "focus east --wrap",  "focus next --wrap",
        "focus prev",          "swap north",         "warp south",
        "warp west",           "resize left 50",     "resize right -50",
        "resize top 50",       "resize bottom 50",   "resize width 100",
        "resize height -100",  "resize ratio 30",    "balance",
        "retile",              "rotate 90",          "rotate 270",
        "mirror x-axis",       "mirror y-axis",      "toggle split",
        "toggle zoom-parent",  "toggle zoom-parent", "send-monitor next",
        "focus-monitor next",  "workspace next",     "workspace prev",
        "workspace recent",    "send recent",        "send next --follow",
        "move-floating 10 10", "grid 1:2:0:0:1:1",   "close-others",
        "layout bsp",          "tile",               "zoom --off",
    };
    for (commands) |text| os.command_run(text);
    os.settle();
    try testing.expectEqual(@as(u64, 0), os.frames_set);
    try testing.expectEqual(tree.nodes_max, engine.forest.free_count);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{ .frame = screen });
    os.settle();
    for (commands) |text| os.command_run(text);
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(@as(u64, 0), os.frames_set);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_focus(os, a);
}

// Directional focus.

// https://github.com/i3/i3/issues/1214
// https://github.com/swaywm/sway/issues/3684
// https://github.com/swaywm/sway/issues/4638
test "directional focus prefers the neighbour that was used most recently" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    _ = run(os, "focus {d}", .{b});
    _ = run(os, "focus {d}", .{a});
    os.command_run("focus east");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus south");
    os.command_run("focus west");
    os.command_run("focus east");
    try testing.expectEqual(c, engine.focused_window);
    os.settle();
    try expect_focus(os, c);
}

// https://github.com/i3/i3/issues/2352
// https://github.com/swaywm/sway/issues/6596
// https://github.com/swaywm/sway/issues/5866
test "focus stops at the edge of the layout unless it is told to wrap" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    os.command_run("focus east");
    os.command_run("focus north");
    os.command_run("focus south");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus north --wrap");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus east --wrap");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus west --wrap");
    try testing.expectEqual(b, engine.focused_window);
    os.settle();
    try expect_focus(os, b);
    try testing.expectEqual(sets, os.frames_set);
}

// https://github.com/i3/i3/issues/907
// https://github.com/i3/i3/issues/3661
// https://github.com/swaywm/sway/issues/6845
test "focus next and prev reach floating windows after the tiles" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(600, 300, 500, 400) });
    os.settle();
    _ = run(os, "focus {d}", .{a});
    os.command_run("focus next");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus next");
    try testing.expectEqual(note, engine.focused_window);
    os.command_run("focus next");
    try testing.expectEqual(note, engine.focused_window);
    os.command_run("focus next --wrap");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus prev --wrap");
    try testing.expectEqual(note, engine.focused_window);
    os.command_run("focus prev");
    try testing.expectEqual(b, engine.focused_window);
    os.settle();
    try expect_focus(os, b);
    // The tiles stayed where they were through all of it.
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try expect_frame(Rect.init(600, 300, 500, 400), note);
}

// Resizing.

// https://github.com/i3/i3/issues/3174
// https://github.com/i3/i3/issues/2608
// https://github.com/swaywm/sway/issues/713
test "resizing at the edge of the layout moves the opposite edge instead" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    // c is at the bottom right: nothing is to its right or below it.
    os.command_run("resize right 100");
    os.settle();
    try expect_frame(Rect.init(0, 38, 764, 1079), a);
    try expect_frame(Rect.init(764, 38, 964, 540), b);
    try expect_frame(Rect.init(764, 578, 964, 539), c);
    os.command_run("resize bottom 40");
    os.settle();
    try expect_frame(Rect.init(764, 38, 964, 500), b);
    try expect_frame(Rect.init(764, 538, 964, 579), c);
    // An edge that a split owns moves alone: only the split between b and c changes.
    os.command_run("resize top 40");
    os.settle();
    try expect_frame(Rect.init(0, 38, 764, 1079), a);
    try expect_frame(Rect.init(764, 38, 964, 540), b);
    try expect_frame(Rect.init(764, 578, 964, 539), c);
}

// https://github.com/i3/i3/issues/3241
// https://github.com/swaywm/sway/issues/6693
test "no resize makes a tile smaller than a tenth of its split" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    const tenth = Rect.init(1555, 38, 173, 1079);
    const rest = Rect.init(0, 38, 1555, 1079);
    os.command_run("resize left 5000");
    os.settle();
    try expect_frame(rest, a);
    try expect_frame(tenth, b);
    os.command_run("resize left 5000");
    os.command_run("resize width -300");
    os.settle();
    try expect_frame(tenth, b);
    os.command_run("balance");
    os.command_run("resize ratio 1");
    os.settle();
    try expect_frame(rest, a);
    try expect_frame(tenth, b);
    os.command_run("resize ratio 99");
    os.settle();
    try expect_frame(Rect.init(0, 38, 173, 1079), a);
    try expect_frame(Rect.init(173, 38, 1555, 1079), b);
    // The same floor holds for a share asked for ahead of time.
    os.command_run("insert south --ratio 1");
    const c = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(173, 38, 1555, 971), b);
    try expect_frame(Rect.init(173, 1009, 1555, 108), c);
}

// https://github.com/i3/i3/issues/5447
// https://github.com/i3/i3/issues/4250
// https://github.com/i3/i3/issues/6410
// https://github.com/swaywm/sway/issues/5883
test "a tile resized with the mouse at the edge of the screen snaps back" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    // The right edge of the right window belongs to no split.
    os.window_drag(b, Rect.init(864, 38, 700, 1079));
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    // Dragged somewhere that is nobody's tile, it comes back as well.
    os.window_drag(b, Rect.init(900, 60, 864, 1079));
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    // A corner moves both of its edges.
    const c = open(os, zed, .{});
    os.settle();
    os.window_drag(c, Rect.init(764, 478, 964, 639));
    os.settle();
    try expect_frame(Rect.init(0, 38, 764, 1079), a);
    try expect_frame(Rect.init(764, 38, 964, 440), b);
    try expect_frame(Rect.init(764, 478, 964, 639), c);
}

// Workspaces.

// https://github.com/i3/i3/issues/927
// https://github.com/i3/i3/issues/776
// https://github.com/swaywm/sway/issues/1518
// https://github.com/swaywm/sway/issues/6976
// https://github.com/swaywm/sway/issues/6081
test "workspace recent goes back and forth between the last two workspaces" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 3");
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace recent");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_focus(os, a);
    os.command_run("workspace recent");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try expect_focus(os, b);
    // Asking for the workspace already shown is not a switch: recent is still workspace 1.
    os.command_run("workspace 3");
    os.command_run("workspace recent");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    // A window sent to the recent workspace arrives there; following it flips recent.
    os.command_run("send recent --follow");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(u8, 3), workspace_of(a));
    try expect_focus(os, a);
    os.command_run("workspace recent");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expect(parked(a) and parked(b));
}

// https://github.com/i3/i3/issues/3923
// https://github.com/i3/i3/issues/2622
// https://github.com/swaywm/sway/issues/2556
test "a workspace remembers which of its windows had focus" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.window_click(b);
    os.settle();
    os.command_run("workspace 2");
    const d = open(os, zed, .{});
    os.settle();
    try expect_focus(os, d);
    os.command_run("workspace 1");
    os.settle();
    try expect_focus(os, b);
    try testing.expect(!parked(a) and !parked(c) and parked(d));
}

// https://github.com/i3/i3/issues/2003
// https://github.com/swaywm/sway/issues/2951
test "sending the last window away leaves its workspace empty and in view" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    try testing.expect(parked(a));
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expectEqual(tree.node_none, engine.workspaces[0].root);
    // With no window to act on, nothing happens and nothing breaks.
    os.command_run("send 3");
    os.command_run("swap east");
    os.command_run("focus west");
    os.focus_repeat();
    os.settle();
    try testing.expect(parked(a));
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    // Cycling skips workspaces without windows, in both directions.
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_focus(os, a);
    try expect_frame(screen, a);
    os.command_run("workspace next");
    os.command_run("workspace prev");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
}

// https://github.com/i3/i3/issues/1975
// https://github.com/swaywm/sway/issues/6818
// https://github.com/swaywm/sway/issues/8292
test "sending the focused window away gives focus to the window used before it" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    os.window_click(c);
    os.settle();
    os.command_run("send 2");
    os.settle();
    try expect_focus(os, a);
    try testing.expect(parked(c));
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    // It joins the other workspace beside the window that had focus there.
    os.command_run("send 2");
    os.settle();
    try expect_focus(os, b);
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(left_half, c);
    try expect_frame(right_half, a);
    try expect_focus(os, a);
}

// Windows that go away in the middle of something.

// https://github.com/i3/i3/issues/246
// https://github.com/i3/i3/issues/2895
// https://github.com/swaywm/sway/issues/7303
// https://github.com/swaywm/sway/issues/8939
test "a window that closes while it is being moved leaves nothing behind" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    // The window is gone, but the notification has not arrived yet.
    os.window_close(c);
    os.command_run("send 2");
    os.settle();
    try testing.expect(engine.window_find(c) == null);
    try testing.expectEqual(tree.node_none, engine.workspaces[1].root);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try expect_focus(os, b);
    os.window_close(b);
    try expect_reply("", run(os, "move {d} left {d} --ratio 30", .{ b, a }));
    _ = run(os, "zoom {d} --on", .{b});
    _ = run(os, "float {d} --bounds 0,0,0.5,0.5", .{b});
    os.window_drag(b, Rect.init(10, 60, 300, 300));
    os.settle();
    try testing.expect(engine.window_find(b) == null);
    try expect_frame(screen, a);
    try expect_focus(os, a);
    try testing.expectEqual(tree.nodes_max - 1, engine.forest.free_count);
    // Once the manager knows, naming the window is an error and changes nothing.
    try expect_reply("error: not-found", run(os, "move {d} left {d}", .{ b, a }));
    try expect_reply("error: not-found", run(os, "swap {d} {d}", .{ a, b }));
    try expect_reply("error: not-found", run(os, "close {d}", .{b}));
}

// Zoom.

// https://github.com/i3/i3/issues/2857
// https://github.com/i3/i3/issues/2570
// https://github.com/i3/i3/issues/1516
test "a zoomed window is still zoomed after its workspace was hidden and shown" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    _ = run(os, "zoom {d} --on", .{a});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a) and parked(b));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(right_half, b);
    try expect_focus(os, a);
    // Sent to another workspace it arrives as an ordinary tile.
    os.command_run("send 2 --follow");
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(engine_module.Zoom.none, engine.window_find(a).?.zoom);
    const c = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
}

// https://github.com/i3/i3/issues/1751
// https://github.com/i3/i3/issues/3912
// https://github.com/swaywm/sway/issues/6202
test "a window that opens beside a zoomed one gets a tile and leaves the zoom alone" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("zoom --on");
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(right_half, b);
    try expect_focus(os, b);
    // Closing the zoomed window gives the whole screen to the one that is left.
    os.window_close(a);
    os.settle();
    try expect_frame(screen, b);
    try testing.expectEqual(engine_module.Zoom.none, engine.window_find(b).?.zoom);
}

// Monitors.

// https://github.com/i3/i3/issues/2883
// https://github.com/i3/i3/issues/2326
// https://github.com/i3/i3/issues/4278
// https://github.com/swaywm/sway/issues/669
// https://github.com/swaywm/sway/issues/3136
test "a monitor that returns shows the workspace it showed and still has its others" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 5");
    const c = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(3000, 300, 500, 400) });
    os.settle();
    try expect_frame(external, c);
    try expect_frame(screen, a);
    os.command_run("focus-monitor 1");
    os.settle();
    try expect_focus(os, a);
    // The laptop is in use, so it keeps showing its workspace; the others wait hidden.
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, a);
    try testing.expect(parked(b) and parked(c) and parked(note));
    try expect_focus(os, a);
    // They can be reached on the screen that is left, floating windows included.
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, b);
    os.command_run("workspace 5");
    os.settle();
    try expect_frame(screen, c);
    try testing.expect(frame_of(note).intersects(screen));
    try testing.expect(parked(a) and parked(b));
    os.command_run("workspace 1");
    os.settle();
    os.monitors_set(1);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, c);
    try testing.expect(frame_of(note).intersects(external));
    try testing.expectEqual(@as(u8, 5), workspace_of(note));
    try testing.expectEqual(@as(u8, 2), workspace_of(b));
    try expect_focus(os, a);
    os.command_run("focus-monitor 2");
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(external, b);
    // Unplugged while it is in use, its workspace comes to the laptop, and on return
    // each display shows what it showed before: the laptop its own workspace again.
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, b);
    try testing.expect(parked(a));
    os.monitors_set(1);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try expect_focus(os, b);
}

// https://github.com/i3/i3/issues/2726
// https://github.com/i3/i3/issues/5517
test "rearranging the displays keeps every workspace on its display" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    // The external display moves to the left of the laptop, which now sits lower.
    os.monitors_set(2);
    os.settle();
    try expect_frame(Rect.init(0, 38, 2560, 1402), b);
    try expect_frame(Rect.init(2560, 361, 1728, 1079), a);
    try expect_focus(os, b);
    // Monitors are numbered from the left, so the numbers trade places with the displays.
    os.command_run("focus-monitor 2");
    os.settle();
    try expect_focus(os, a);
    // Above and below works the same way.
    os.monitors_set(4);
    os.settle();
    try expect_frame(Rect.init(0, 38, 2560, 1402), b);
    try expect_frame(Rect.init(416, 1478, 1728, 1079), a);
    os.command_run("focus north");
    os.settle();
    try expect_focus(os, b);
}

// https://github.com/i3/i3/issues/4035
// https://github.com/i3/i3/issues/5927
// https://github.com/i3/i3/issues/3938
// https://github.com/swaywm/sway/issues/5198
// https://github.com/swaywm/sway/issues/8829
test "displays that sleep and wake leave the layout and focus as they were" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 3");
    const c = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    try testing.expectEqual(@as(usize, 0), sleep(os));
    // Commands are ignored meanwhile, and nothing moves.
    os.command_run("workspace 1");
    os.command_run("send 2");
    os.command_run("toggle float");
    os.advance(5000);
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try expect_frame(screen, c);
    try testing.expect(parked(a) and parked(b));
    try expect_focus(os, c);
    // Nobody was floated or given up on while the screens were dark.
    for ([_]WindowId{ a, b, c }) |id| {
        try testing.expectEqual(Mode.tiled, engine.window_find(id).?.mode);
        try testing.expect(!engine.window_find(id).?.frozen);
    }
}

// https://github.com/swaywm/sway/issues/1123
// https://github.com/swaywm/sway/issues/3234
// https://github.com/i3/i3/issues/926
test "a window that opens while every display is asleep joins the workspace in use" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 3");
    const b = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(@as(usize, 0), sleep(os));
    const c = open(os, zed, .{});
    os.settle();
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(u8, 3), workspace_of(c));
    try expect_frame(left_half, b);
    try expect_frame(right_half, c);
    try testing.expect(parked(a));
    try expect_focus(os, c);
}

// https://github.com/i3/i3/issues/2180
// https://github.com/i3/i3/issues/6396
// https://github.com/swaywm/sway/issues/5174
test "showing a workspace that another monitor shows moves focus there" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    try testing.expectEqual(@as(u8, 2), workspace_of(b));
    os.command_run("workspace 1");
    os.settle();
    try expect_focus(os, a);
    os.command_run("workspace 2");
    os.settle();
    try expect_focus(os, b);
    // Naming a window on the other monitor does the same.
    _ = run(os, "focus {d}", .{a});
    os.settle();
    try expect_focus(os, a);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try testing.expectEqual(sets, os.frames_set);
    // With --wrap focus crosses to the next monitor before it wraps on its own.
    os.command_run("focus east --wrap");
    os.settle();
    try expect_focus(os, b);
    os.command_run("focus east --wrap");
    os.settle();
    try expect_focus(os, b);
    try testing.expectEqual(sets, os.frames_set);
}

// Floating windows and monitors.

// https://github.com/i3/i3/issues/3902
// https://github.com/i3/i3/issues/2661
// https://github.com/swaywm/sway/issues/5691
test "a floating window sent to another monitor keeps its place on the screen" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    os.command_run("send-monitor 2 --follow");
    os.settle();
    try expect_frame(Rect.init(2928, 100, 400, 300), note);
    try expect_focus(os, note);
    try expect_frame(screen, a);
    // A spot that the smaller screen does not have stops at its edge.
    os.command_run("move-floating 1000 0");
    os.settle();
    try expect_frame(Rect.init(3928, 100, 400, 300), note);
    os.command_run("send-monitor 1 --follow");
    os.settle();
    try expect_frame(Rect.init(1328, 100, 400, 300), note);
    try testing.expectEqual(@as(u8, 1), workspace_of(note));
}

// https://github.com/i3/i3/issues/3567
// https://github.com/i3/i3/issues/5427
test "a floating window dragged to another monitor belongs to the workspace shown there" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    try testing.expectEqual(@as(u8, 1), workspace_of(note));
    const there = Rect.init(2500, 300, 400, 300);
    os.window_drag(note, there);
    os.settle();
    try expect_frame(there, note);
    try testing.expectEqual(@as(u8, 2), workspace_of(note));
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    // Hiding the workspace it came from no longer hides it.
    os.command_run("focus-monitor 1");
    os.settle();
    os.command_run("workspace 4");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(there, note);
}

// https://github.com/i3/i3/issues/3902
// https://github.com/i3/i3/issues/6075
test "move-floating onto another monitor hands the window to the workspace shown there" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    os.command_run("move-floating 1000 0");
    os.settle();
    const there = Rect.init(2200, 100, 400, 300);
    try expect_frame(there, note);
    try testing.expectEqual(@as(u8, 2), workspace_of(note));
    try expect_focus(os, note);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    os.command_run("focus-monitor 1");
    os.settle();
    os.command_run("workspace 4");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(there, note);
}

// https://github.com/i3/i3/issues/1910
// https://github.com/i3/i3/issues/1739
// https://github.com/swaywm/sway/issues/4604
test "move-floating cannot carry a window off every screen" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    // Part of it may hang over the edge.
    os.command_run("move-floating 400 0");
    os.settle();
    try expect_frame(Rect.init(1600, 100, 400, 300), note);
    // Past the edge altogether it comes back to the middle instead of being lost.
    os.command_run("move-floating 5000 -3000");
    os.settle();
    try expect_frame(Rect.init(664, 427, 400, 300), note);
    try expect_frame(screen, a);
}

// https://github.com/i3/i3/issues/5797
// https://github.com/i3/i3/issues/5069
// https://github.com/swaywm/sway/issues/2846
test "a tile dragged onto a monitor with no tiles moves to the workspace shown there" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, a);
    os.window_drag(b, Rect.init(2400, 200, 864, 1079));
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try testing.expectEqual(@as(u8, 2), workspace_of(b));
    try expect_focus(os, b);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    // Onto a tile over there it takes half of that tile's place, as before.
    os.window_drag(a, Rect.init(2400, 200, 1728, 1079));
    os.settle();
    try testing.expectEqual(@as(u8, 2), workspace_of(a));
    try testing.expectEqual(external.w, frame_of(a).w + frame_of(b).w);
}

// https://github.com/i3/i3/issues/4035
// https://github.com/i3/i3/issues/5927
// https://github.com/swaywm/sway/issues/3270
test "displays that sleep and wake show the workspaces they showed" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 6");
    const c = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    os.command_run("workspace 4");
    os.settle();
    const sets = os.frames_set;
    try testing.expectEqual(@as(usize, 0), sleep(os));
    try testing.expectEqual(@as(u8, 3), engine.workspace_current());
    os.advance(60_000);
    os.monitors_set(1);
    os.settle();
    // The laptop shows its empty workspace and is the monitor in use, as before.
    try testing.expectEqual(@as(u8, 3), engine.workspace_current());
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try expect_frame(external, c);
    try testing.expect(parked(a));
    try testing.expectEqual(@as(u8, 2), workspace_of(b));
    try testing.expectEqual(sets, os.frames_set);
}

// Focus requests that are overtaken.

// https://github.com/i3/i3/issues/4366
// https://github.com/i3/i3/issues/2622
// https://github.com/i3/i3/issues/2081
test "the late echo of a focus request does not undo the switch made after it" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, zed, .{});
    os.settle();
    try expect_focus(os, b);
    // Two key presses in a row: workspace 1, then the empty workspace 3. The OS confirms
    // the focus that the first one asked for after the second one was handled.
    os.command_run("workspace 1");
    os.command_run("workspace 3");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expect(parked(a) and parked(b));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    // The same when the window is sent away right after it was given focus.
    os.command_run("workspace 2");
    os.settle();
    try expect_focus(os, b);
    os.command_run("workspace 1");
    os.command_run("send 4");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(@as(u8, 4), workspace_of(a));
    try testing.expect(parked(a) and parked(b));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    // Going there on purpose still works, and the echo then confirms it.
    os.command_run("workspace 4");
    os.settle();
    try expect_focus(os, a);
    try expect_frame(screen, a);
}

// https://github.com/i3/i3/issues/2328
// https://github.com/i3/i3/issues/6396
test "the late echo of a focus request does not pull focus back from an empty monitor" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 5");
    os.settle();
    try testing.expect(!parked(a) and frame_of(b).x >= external.right() - 1);
    // To the laptop and straight back to the external display, which shows nothing.
    os.command_run("focus-monitor 1");
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(@as(u8, 4), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    // The next window opens on the monitor that was chosen.
    const c = open(os, zed, .{});
    os.settle();
    try expect_frame(external, c);
    try expect_frame(screen, a);
}

// Floating.

// https://github.com/swaywm/sway/issues/3079
// https://github.com/i3/i3/issues/2539
test "a window floated while its application is hung floats where its tile is" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const b = open(os, slack, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a) and parked(b));
    // The workspace comes back while Slack does not answer: its window is still parked.
    os.app_hang(slack, 2000);
    os.command_run("workspace 1");
    os.advance(1);
    try testing.expect(parked(b));
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("toggle float");
    os.advance(5000);
    os.settle();
    try testing.expectEqual(Mode.floating, engine.window_find(b).?.mode);
    try expect_frame(right_half, b);
    try expect_frame(screen, a);
}

// Commands that name their windows.

// https://github.com/i3/i3/issues/1767
// https://github.com/i3/i3/issues/3689
test "move does not spend the place that insert keeps for the next window" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
    os.settle();
    _ = run(os, "focus {d}", .{a});
    os.command_run("insert west --ratio 25");
    _ = run(os, "move {d} below {d}", .{ b, a });
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 540), a);
    try expect_frame(Rect.init(0, 578, 1728, 539), b);
    const c = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(0, 38, 432, 540), c);
    try expect_frame(Rect.init(432, 38, 1296, 540), a);
    try expect_frame(Rect.init(0, 578, 1728, 539), b);
}

// https://github.com/i3/i3/issues/1053
// https://github.com/i3/i3/issues/1326
// https://github.com/i3/i3/issues/3688
// https://github.com/swaywm/sway/issues/6818
test "move rearranges siblings, follows focus across workspaces and refuses nonsense" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    // Two halves of one split trade sides, then stack, without leaving a hole.
    _ = run(os, "move {d} right {d}", .{ a, b });
    os.settle();
    try expect_frame(left_half, b);
    try expect_frame(right_half, a);
    _ = run(os, "move {d} above {d} --ratio 25", .{ a, b });
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 270), a);
    try expect_frame(Rect.init(0, 308, 1728, 809), b);
    try testing.expectEqual(tree.nodes_max - 3, engine.forest.free_count);
    try expect_reply("error: bad-request", run(os, "move {d} left {d}", .{ a, a }));
    try expect_reply("error: not-found", run(os, "move left {d}", .{@as(u32, 9999)}));
    // The focused window takes focus and the view along to the anchor's workspace.
    os.command_run("workspace 2");
    const c = open(os, zed, .{});
    os.settle();
    try expect_focus(os, c);
    _ = run(os, "move left {d}", .{a});
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_focus(os, c);
    try expect_frame(Rect.init(0, 38, 864, 270), c);
    try expect_frame(Rect.init(864, 38, 864, 270), a);
    try testing.expectEqual(tree.node_none, engine.workspaces[1].root);
}

// https://github.com/i3/i3/issues/917
// https://github.com/i3/i3/issues/3259
// https://github.com/i3/i3/issues/3930
// https://github.com/i3/i3/issues/3280
test "swap refuses windows that are not two tiles of one workspace" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
    os.settle();
    const sets = os.frames_set;
    try expect_reply("error: conflict", run(os, "swap {d} {d}", .{ a, note }));
    _ = run(os, "focus {d}", .{b});
    os.command_run("send 2");
    os.settle();
    try expect_reply("error: conflict", run(os, "swap {d} {d}", .{ a, b }));
    os.settle();
    try expect_frame(screen, a);
    try testing.expect(parked(b));
    try testing.expectEqual(sets + 2, os.frames_set);
    // A zoomed window keeps its zoom through a swap: the zoom belongs to the window.
    _ = run(os, "move {d} right {d}", .{ b, a });
    _ = run(os, "zoom {d} --on", .{a});
    _ = run(os, "swap {d} {d}", .{ a, b });
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(left_half, b);
    _ = run(os, "zoom {d} --off", .{a});
    os.settle();
    try expect_frame(right_half, a);
    // By direction at the edge of the layout nothing trades places.
    os.command_run("swap east");
    os.command_run("warp east");
    os.command_run("swap north");
    os.settle();
    try expect_frame(right_half, a);
    try expect_frame(left_half, b);
}

// https://github.com/i3/i3/issues/2597
// https://github.com/i3/i3/issues/266
// https://github.com/swaywm/sway/issues/3236
test "a label goes where its window goes and ends with it" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    _ = run(os, "label {d} editor", .{a});
    _ = run(os, "focus editor", .{});
    os.command_run("send 4");
    os.settle();
    try expect_focus(os, b);
    try expect_reply("", run(os, "float editor --bounds 0.5,0,0.5,1", .{}));
    try expect_reply("", run(os, "tile editor", .{}));
    try expect_reply("", run(os, "focus editor", .{}));
    os.settle();
    try testing.expectEqual(@as(u8, 3), engine.workspace_current());
    try expect_focus(os, a);
    try expect_frame(screen, a);
    try expect_reply("", run(os, "move editor left {d}", .{b}));
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    os.window_close(a);
    os.settle();
    try expect_reply("error: not-found", run(os, "focus editor", .{}));
    try expect_reply("", run(os, "label {d} editor", .{b}));
    try expect_reply("", run(os, "zoom editor --on", .{}));
    try expect_reply("id=", run(os, "query window editor", .{}));
}

// https://github.com/i3/i3/issues/3208
test "a workspace that does not exist is an error, not a silent nothing" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    try expect_reply("error: not-found", run(os, "workspace 17", .{}));
    try expect_reply("error: not-found", run(os, "send 200 --follow", .{}));
    try expect_reply("error: not-found", run(os, "workspace mail", .{}));
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(screen, a);
    try expect_reply("", run(os, "send 16 --follow", .{}));
    os.settle();
    try testing.expectEqual(@as(u8, 15), engine.workspace_current());
    try expect_focus(os, a);
}

// Sticky windows.

// https://github.com/i3/i3/issues/11
// https://github.com/i3/i3/issues/3075
// https://github.com/i3/i3/issues/1924
test "a sticky window does not make the workspace it is seen on count as used" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const note = open(os, zed, .{ .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    os.command_run("toggle sticky");
    os.settle();
    const place = frame_of(note);
    os.command_run("workspace 3");
    os.settle();
    try expect_frame(place, note);
    try testing.expectEqual(@as(u8, 3), workspace_of(note));
    // Cycling finds the one workspace with real windows and then has nowhere else to go.
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(screen, a);
    os.command_run("workspace next");
    os.command_run("workspace prev");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(place, note);
    // Sent away on purpose it stops being sticky and leaves with the rest.
    _ = run(os, "focus {d}", .{note});
    os.command_run("send 2");
    os.command_run("workspace 5");
    os.settle();
    try testing.expect(parked(note) and parked(a));
}

// More of the same families.

// https://github.com/i3/i3/issues/2383
// https://github.com/i3/i3/issues/2072
// https://github.com/i3/i3/issues/3732
// https://github.com/swaywm/sway/issues/6750
test "workspace next and prev step over empty workspaces and wrap around" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 3");
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 9");
    const c = open(os, zed, .{});
    os.settle();
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_focus(os, a);
    os.command_run("workspace prev");
    os.settle();
    try testing.expectEqual(@as(u8, 8), engine.workspace_current());
    try expect_focus(os, c);
    os.command_run("workspace prev");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try expect_focus(os, b);
    // A new workspace is the lowest one without windows, and a window can be sent there.
    os.command_run("send new --follow");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_focus(os, b);
    try expect_frame(screen, b);
    try testing.expect(parked(a) and parked(c));
}

// https://github.com/i3/i3/issues/4366
// https://github.com/i3/i3/issues/1207
test "switching workspaces faster than the windows move ends with every window in place" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    for (0..5) |_| {
        os.command_run("workspace 1");
        os.command_run("workspace 2");
    }
    os.command_run("workspace recent");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expect(parked(c));
    try expect_focus(os, b);
    // At most one frame for each window for each switch.
    try testing.expect(os.frames_set - sets <= 11 * 3);
}

// https://github.com/i3/i3/issues/4180
// https://github.com/i3/i3/issues/4489
// https://github.com/swaywm/sway/issues/487
// https://github.com/swaywm/sway/issues/6450
test "a floating window comes back from a hidden workspace exactly where it was" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const place = Rect.init(700, 250, 520, 410);
    const note = open(os, zed, .{ .kind = .dialog, .frame = place });
    os.settle();
    const sets = os.frames_set;
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a) and parked(note));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(place, note);
    try expect_frame(screen, a);
    try testing.expectEqual(sets + 4, os.frames_set);
    try expect_focus(os, note);
    // Tiled and floated again it floats where its tile was, and the tree lost nothing.
    os.command_run("toggle float");
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, note);
    os.command_run("toggle float");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(right_half, note);
    try testing.expectEqual(tree.nodes_max - 1, engine.forest.free_count);
}

// https://github.com/i3/i3/issues/2421
// https://github.com/i3/i3/issues/6597
// https://github.com/i3/i3/issues/1484
// https://github.com/swaywm/sway/issues/3991
test "floating the only tile and tiling it again leaves a sound layout" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    // With no window at all the commands that need one do nothing.
    const commands = [_][]const u8{
        "toggle float",           "float",     "float --bounds 0,0,0.5,0.5", "toggle sticky",
        "toggle zoom-fullscreen", "zoom --on", "close",                      "send 2",
        "label lonely",           "swap west", "layout float",               "layout bsp",
    };
    for (commands) |text| os.command_run(text);
    try expect_reply("error: not-found", run(os, "move left {d}", .{@as(u32, 100)}));
    os.settle();
    try testing.expectEqual(@as(u64, 0), os.frames_set);
    const a = open(os, zed, .{ .frame = screen });
    os.settle();
    os.command_run("toggle float");
    os.settle();
    try testing.expectEqual(tree.node_none, engine.workspaces[0].root);
    try testing.expectEqual(Mode.floating, engine.window_find(a).?.mode);
    try expect_frame(screen, a);
    os.command_run("float --bounds 0.5,0.5,0.5,0.5");
    os.settle();
    try expect_frame(Rect.init(864, 577, 864, 539), a);
    os.command_run("layout bsp");
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(tree.nodes_max - 1, engine.forest.free_count);
    try expect_focus(os, a);
}

// https://github.com/i3/i3/issues/1627
// https://github.com/i3/i3/issues/1098
// https://github.com/swaywm/sway/issues/8939
test "changing a window between tiled and floating in the middle of a drag is safe" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    // The mouse is resizing the tile when it is floated: it floats where the mouse put it.
    const dragged = Rect.init(964, 38, 764, 1079);
    os.window_drag(b, dragged);
    os.command_run("toggle float");
    os.settle();
    try testing.expectEqual(Mode.floating, engine.window_find(b).?.mode);
    try expect_frame(dragged, b);
    try expect_frame(screen, a);
    // The mouse is moving the floating window when it is tiled: it becomes a tile, and
    // the two tiles still share the whole screen between them.
    os.window_drag(b, Rect.init(1000, 100, 764, 1079));
    os.command_run("toggle float");
    os.settle();
    try testing.expectEqual(Mode.tiled, engine.window_find(b).?.mode);
    try testing.expectEqual(screen.w, frame_of(a).w + frame_of(b).w);
    try testing.expectEqual(screen.h, frame_of(a).h);
    try testing.expectEqual(screen.h, frame_of(b).h);
    try testing.expectEqual(tree.nodes_max - 3, engine.forest.free_count);
}

// Parking.

// https://github.com/i3/i3/issues/3795
// https://github.com/i3/i3/issues/2086
// https://github.com/swaywm/sway/issues/8205
test "a wide window whose tile sat at the height of its parking spot parks out of sight" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("insert south --ratio 10");
    const b = open(os, zed, .{});
    os.settle();
    // The window never gets narrower than 1200, and macOS keeps 108 pixels of it on screen:
    // parked, its top ends up exactly where the top of its tile is.
    const wide = open(os, zed, .{ .min_w = 1200, .title_bar = 108 });
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 971), a);
    try expect_frame(Rect.init(0, 1009, 864, 108), b);
    try expect_frame(Rect.init(864, 1009, 1200, 108), wide);
    // The external display is to the right, so the laptop parks its windows on the left.
    const hidden = Rect.init(-1199, 1009, 1200, 108);
    for (0..3) |_| {
        os.command_run("workspace 4");
        os.advance(1000);
        try expect_frame(hidden, wide);
        os.command_run("workspace 1");
        os.advance(1000);
        try expect_frame(Rect.init(864, 1009, 1200, 108), wide);
    }
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 971), a);
    try expect_focus(os, wide);
}

// Where a new window goes.

// https://github.com/i3/i3/issues/1767
// https://github.com/i3/i3/issues/3661
test "a window that opens while a floating window has focus splits the tile used last" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
    os.settle();
    try expect_focus(os, note);
    const d = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(0, 38, 864, 540), a);
    try expect_frame(Rect.init(0, 578, 864, 539), d);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
    // The floating window itself, tiled, goes beside the tile used last as well.
    _ = run(os, "focus {d}", .{b});
    _ = run(os, "focus {d}", .{note});
    os.command_run("tile");
    os.settle();
    try expect_frame(Rect.init(864, 38, 432, 540), b);
    try expect_frame(Rect.init(1296, 38, 432, 540), note);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
}
