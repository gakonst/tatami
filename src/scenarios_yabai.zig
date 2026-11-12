//! Scenario tests for the failures that users of yabai and skhd reported and that could
//! also bite this window manager. Each test names the behaviour and cites the reports.
//! They run the real engine against the simulated OS with random faults switched off, so
//! every expectation is exact.
//!
//! A few reports are about things the simulator has no call for: displays that all go to
//! sleep, a display list of our own, native fullscreen, an application that moves its own
//! window once. Those tests hand the event to the engine themselves with inject(), which
//! then performs the engine's answer through the simulator. The last tests need no
//! simulated OS at all and drive the engine or the configuration parser directly.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const WindowId = engine_module.WindowId;
const MonitorInfo = engine_module.MonitorInfo;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const laptop = Rect.init(0, 0, 1728, 1117);
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);
// The external display of the simulator's second arrangement, to the right of the laptop.
const external = Rect.init(1728, 0, 2560, 1440);
const external_screen = Rect.init(1728, 38, 2560, 1402);

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

/// Whether at most a one pixel sliver of the window shows on the display.
fn parked_on(id: WindowId, whole: Rect) bool {
    const frame = frame_of(id);
    return frame.overlap(whole, .x) <= 1 or frame.overlap(whole, .y) <= 1;
}

fn parked(id: WindowId) bool {
    return parked_on(id, laptop);
}

/// Runs a command built from a format string and returns what the engine answered.
fn run(os: *sim.Simulator, comptime format: []const u8, args: anytype) []const u8 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    os.command_run(text);
    return engine.reply();
}

fn workspace_of(id: WindowId) u8 {
    return engine.window_find(id).?.workspace;
}

fn mode_of(id: WindowId) engine_module.Mode {
    return engine.window_find(id).?.mode;
}

/// A display as the simulator describes them: a 38 pixel menu bar and nothing else.
fn display(id: u32, x: i32, y: i32, w: i32, h: i32, main: bool) MonitorInfo {
    return .{
        .display = id,
        .frame = Rect.init(x, y, w, h),
        .visible = Rect.init(x, y + 38, w, h - 38),
        .main = main,
    };
}

const Performed = union(enum) { frame: struct { id: WindowId, frame: Rect }, focus: WindowId };

/// Hands the engine an event that the simulator has no call for, and performs the answer
/// the way the simulated OS would with faults off: every window takes its frame at once,
/// focus goes where it is sent, and a question about focus is answered truthfully.
fn inject(os: *sim.Simulator, event: engine_module.Event) void {
    var next: ?engine_module.Event = event;
    var rounds: u32 = 0;
    while (next) |current| : (rounds += 1) {
        std.debug.assert(rounds < 4);
        next = null;
        // The effects are only valid until the next step, and performing them steps.
        var performed: [64]Performed = undefined;
        var count: u32 = 0;
        var asked = false;
        for (engine.step(current, os.now_ms)) |effect| {
            switch (effect) {
                .set_frame => |set| {
                    performed[count] = .{ .frame = .{ .id = set.id, .frame = set.frame } };
                    count += 1;
                },
                .focus_window => |focus| {
                    performed[count] = .{ .focus = focus.id };
                    count += 1;
                },
                .query_focus => asked = true,
                else => {},
            }
        }
        engine.verify();
        for (performed[0..count]) |action| {
            switch (action) {
                .frame => |set| os.window_drag(set.id, set.frame),
                .focus => |id| os.window_click(id),
            }
        }
        os.advance(0);
        if (asked) next = .{ .focus_reported = os.focused };
    }
}

/// The display list changes to one of our own making.
fn displays_set(os: *sim.Simulator, list: []const MonitorInfo) void {
    os.monitors = list;
    inject(os, .{ .monitors_changed = list });
}

/// The application moves or resizes its own window, as when it restores a saved frame.
fn self_move(os: *sim.Simulator, id: WindowId, frame: Rect) void {
    os.window_find(id).?.frame = frame;
    inject(os, .{ .window_frame_changed = .{ .id = id, .frame = frame, .by_user = false } });
}

// Focus.

// https://github.com/asmvik/yabai/issues/692
// https://github.com/asmvik/yabai/issues/485
// https://github.com/asmvik/yabai/issues/1012
test "closing the focused window keeps focus on its workspace" {
    // macOS hands focus to another window of the same application, wherever it is.
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const elsewhere = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    const neighbour = open(os, slack, .{});
    const closing = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(closing, engine.focused_window);
    os.window_close(closing);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expectEqual(neighbour, engine.focused_window);
    try testing.expectEqual(neighbour, os.focused);
    try expect_frame(screen, neighbour);
    try testing.expect(parked(elsewhere));
}

// https://github.com/asmvik/yabai/issues/687
// https://github.com/asmvik/yabai/issues/2440
test "closing the last window of a workspace does not jump to another workspace" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const elsewhere = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    const last = open(os, zed, .{});
    os.settle();
    os.window_close(last);
    os.settle();
    // macOS focused the application's other window; that is not the user going there.
    try testing.expectEqual(elsewhere, os.focused);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expect(parked(elsewhere));
    for (0..3) |_| {
        os.advance(1000);
        os.focus_repeat();
        os.settle();
        try testing.expectEqual(@as(u8, 1), engine.workspace_current());
        try testing.expect(parked(elsewhere));
    }
    // The next window opens on the workspace in use, not next to the one macOS focused.
    const next = open(os, zed, .{});
    os.settle();
    try expect_frame(screen, next);
    try testing.expect(parked(elsewhere));
}

// https://github.com/asmvik/yabai/issues/70
// https://github.com/asmvik/yabai/issues/1212
test "a minimized window gives up its tile and its focus, and takes both back" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const far = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    const a = open(os, slack, .{});
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    os.window_minimize(b, true);
    os.settle();
    // The tile closes up, and focus stays on this workspace although macOS preferred the
    // other window of the same application.
    try expect_frame(screen, a);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expect(parked(far));
    // No frame is sent to a window that sits in the Dock.
    const sets = engine.window_find(b).?.sets_total;
    os.command_run("workspace 1");
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(sets, engine.window_find(b).?.sets_total);
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(b, engine.focused_window);
}

// https://github.com/asmvik/yabai/issues/1033
// https://github.com/asmvik/yabai/issues/1569
test "an empty monitor keeps focus when an application repeats its focus" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const brave = os.app_launch("Brave Browser", "com.brave.Browser");
    const browser = open(os, brave, .{});
    os.settle();
    try expect_frame(screen, browser);
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    for (0..5) |_| {
        os.advance(800);
        os.focus_repeat();
        os.settle();
        try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
        try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    }
    // So the next window opens on the monitor that was asked for.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    os.settle();
    try expect_frame(external_screen, editor);
    try expect_frame(screen, browser);
    // Really going to the other window still moves focus there.
    os.window_click(browser);
    os.settle();
    try testing.expectEqual(browser, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
}

// https://github.com/asmvik/yabai/issues/1463
// https://github.com/asmvik/yabai/issues/225
test "focus crosses to a monitor whose edges are not aligned, and back" {
    const os = boot("");
    os.monitors_set(2); // External display on the left, the laptop lower on its right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const on_laptop = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(2560, 361, 1728, 1079), on_laptop);
    os.command_run("focus west");
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    const on_external = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(0, 38, 2560, 1402), on_external);
    os.command_run("focus east");
    try testing.expectEqual(on_laptop, engine.focused_window);
    os.command_run("focus west");
    try testing.expectEqual(on_external, engine.focused_window);
    // Nothing is above, below or further left: focus stays where it is.
    os.command_run("focus north");
    os.command_run("focus south");
    os.command_run("focus west");
    try testing.expectEqual(on_external, engine.focused_window);
    os.settle();
    try testing.expectEqual(on_external, os.focused);
    // Stacked displays: the laptop below the external one.
    os.monitors_set(4);
    os.settle();
    os.command_run("focus south");
    try testing.expectEqual(on_laptop, engine.focused_window);
    os.command_run("focus north");
    try testing.expectEqual(on_external, engine.focused_window);
}

// https://github.com/asmvik/yabai/issues/113
test "floating windows are reached with focus next, and directions lead back to tiles" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(700, 400, 300, 200) });
    os.settle();
    try testing.expectEqual(engine_module.Mode.floating, mode_of(note));
    os.window_click(a);
    os.settle();
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
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus prev --wrap");
    os.command_run("focus east");
    try testing.expectEqual(b, engine.focused_window);
    os.settle();
    try testing.expectEqual(b, os.focused);
    // Focus moved five times and no window was moved for it.
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try expect_frame(Rect.init(700, 400, 300, 200), note);
}

// https://github.com/asmvik/yabai/issues/1509
// https://github.com/asmvik/yabai/issues/1579
test "a popup that takes keyboard focus changes nothing" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    const revision = engine.revision;
    const menu = open(os, zed, .{ .kind = .popup, .frame = Rect.init(900, 100, 200, 400) });
    os.settle();
    try testing.expectEqual(menu, os.focused);
    try testing.expect(engine.window_find(menu) == null);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(sets, os.frames_set);
    try testing.expectEqual(revision, engine.revision);
    try expect_frame(Rect.init(900, 100, 200, 400), menu);
    // The popup closes and macOS gives focus back; commands carry on from where they were.
    os.window_close(menu);
    os.settle();
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
}

// https://github.com/asmvik/yabai/issues/1601
// https://github.com/asmvik/yabai/issues/2241
test "an application that takes focus on a hidden workspace shows that workspace once" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const teams = os.app_launch("Microsoft Teams", "com.microsoft.teams2");
    const call = open(os, teams, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    const editor = open(os, zed, .{});
    os.settle();
    try testing.expect(parked(call));
    // The application activates itself: the user is taken to it, with one frame per window.
    const sets = os.frames_set;
    os.window_click(call);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(call, engine.focused_window);
    try testing.expectEqual(@as(u64, 2), os.frames_set - sets);
    try testing.expect(parked(editor));
    // Going back is not undone by the application saying again that it has focus.
    os.command_run("workspace 2");
    os.settle();
    os.advance(700);
    os.focus_repeat();
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expectEqual(editor, engine.focused_window);
    try testing.expectEqual(editor, os.focused);
}

// Layout.

// https://github.com/asmvik/yabai/issues/1317
// https://github.com/asmvik/yabai/issues/322
// https://github.com/asmvik/yabai/issues/800
test "a window that cannot be resized floats, and tiling the workspace leaves it alone" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const home = Rect.init(500, 300, 400, 300);
    const fixed = open(os, zed, .{ .resizable = false, .frame = home });
    os.settle();
    try testing.expectEqual(engine_module.Mode.floating, mode_of(fixed));
    try expect_frame(screen, a);
    try expect_frame(home, fixed);
    os.command_run("layout bsp");
    os.command_run("retile");
    os.command_run("balance");
    os.settle();
    try testing.expectEqual(engine_module.Mode.floating, mode_of(fixed));
    try expect_frame(screen, a);
    try expect_frame(home, fixed);
    try testing.expectEqual(@as(u32, 0), engine.window_find(fixed).?.sets_total);
}

// https://github.com/asmvik/yabai/issues/864
// https://github.com/asmvik/yabai/issues/1481
// https://github.com/asmvik/yabai/issues/228
test "a window that opens beside a zoomed one gets its tile, and the zoom stays" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(screen, a);
    const c = open(os, zed, .{});
    os.settle();
    // The new window splits the tile of the zoomed one, which keeps the whole workspace.
    try expect_frame(screen, a);
    try expect_frame(right_half, b);
    try expect_frame(Rect.init(0, 578, 864, 539), c);
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(engine_module.Zoom.fullscreen, engine.window_find(a).?.zoom);
    // Leaving the zoom puts the window in the tile that the split left it.
    _ = run(os, "zoom {d} --off", .{a});
    os.settle();
    try expect_frame(Rect.init(0, 38, 864, 540), a);
    try expect_frame(Rect.init(0, 578, 864, 539), c);
    try expect_frame(right_half, b);
}

// https://github.com/asmvik/yabai/issues/317
// https://github.com/asmvik/yabai/issues/845
test "a floating window can be zoomed and returns to where it floated" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const home = Rect.init(700, 400, 300, 200);
    const note = open(os, zed, .{ .kind = .dialog, .frame = home });
    os.settle();
    try testing.expectEqual(note, engine.focused_window);
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(screen, note);
    try expect_frame(screen, a);
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(home, note);
    // Tiling a zoomed floating window and floating it again does not lose the spot either.
    os.command_run("toggle zoom-fullscreen");
    os.command_run("toggle float");
    os.command_run("toggle float");
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try testing.expectEqual(engine_module.Mode.floating, mode_of(note));
    try expect_frame(home, note);
    try expect_frame(screen, a);
}

// https://github.com/asmvik/yabai/issues/185
// https://github.com/asmvik/yabai/issues/2631
test "a zoomed window sent to another workspace arrives as a tile and focus stays behind" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 1");
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(screen, b);
    os.command_run("send 2");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try expect_frame(screen, a);
    try testing.expect(parked(b) and parked(c));
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(engine_module.Zoom.none, engine.window_find(b).?.zoom);
    try expect_frame(left_half, c);
    try expect_frame(right_half, b);
}

// https://github.com/asmvik/yabai/issues/190
// https://github.com/asmvik/yabai/issues/1301
// https://github.com/asmvik/yabai/issues/2506
test "balance evens three columns, rotations and mirrors undo themselves" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("insert east");
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("insert east");
    const c = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 432, 1079), b);
    try expect_frame(Rect.init(1296, 38, 432, 1079), c);
    os.command_run("balance");
    os.settle();
    try expect_frame(Rect.init(0, 38, 576, 1079), a);
    try expect_frame(Rect.init(576, 38, 576, 1079), b);
    try expect_frame(Rect.init(1152, 38, 576, 1079), c);
    // A second balance has nothing to do and moves nothing.
    var sets = os.frames_set;
    os.command_run("balance");
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    _ = run(os, "focus {d}", .{a});
    os.command_run("resize right 101");
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    try expect_frame(Rect.init(0, 38, 677, 1079), a);
    for (0..4) |_| os.command_run("rotate 90");
    os.command_run("mirror x-axis");
    os.command_run("mirror x-axis");
    os.command_run("mirror y-axis");
    os.command_run("mirror y-axis");
    os.command_run("rotate 180");
    os.command_run("rotate 180");
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
    // After a quarter turn the columns are rows, and an edge still moves by what was asked.
    os.command_run("rotate 90");
    os.settle();
    const top = frame_of(a);
    try testing.expectEqual(screen.w, top.w);
    try testing.expectEqual(screen.y, top.y);
    try testing.expect(frame_of(b).y == top.bottom() and frame_of(c).y > frame_of(b).y);
    sets = os.frames_set;
    os.command_run("resize bottom 50");
    os.settle();
    try expect_frame(Rect.init(top.x, top.y, top.w, top.h + 50), a);
    try testing.expectEqual(top.bottom() + 50, frame_of(b).y);
    try testing.expectEqual(screen.bottom(), frame_of(c).bottom());
    try testing.expectEqual(@as(u64, 3), os.frames_set - sets);
}

// https://github.com/asmvik/yabai/issues/492
// https://github.com/asmvik/yabai/issues/146
// https://github.com/asmvik/yabai/issues/1746
test "the insertion point outlives a dialog and a click, and is spent on the next tile" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("insert west");
    const dialog = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(600, 300, 400, 300) });
    os.settle();
    // A window that never joins the layout does not move the tiles or use up the insert.
    try expect_frame(screen, a);
    os.window_close(dialog);
    os.window_click(a);
    os.settle();
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, b);
    try expect_frame(right_half, a);
    // Spent: the next window splits the focused tile the usual way.
    const c = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(0, 38, 864, 540), b);
    try expect_frame(Rect.init(0, 578, 864, 539), c);
    try expect_frame(right_half, a);
}

// https://github.com/asmvik/yabai/issues/643
// https://github.com/asmvik/yabai/issues/2185
// https://github.com/asmvik/yabai/issues/21
test "resize moves the edge that exists, stops at the limit and then sends nothing" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    // One window has no edge to move.
    var sets = os.frames_set;
    os.command_run("resize right 20");
    os.command_run("resize left -20");
    os.command_run("resize ratio 30");
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    try expect_frame(screen, a);
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("focus west");
    // The left window has no left edge to move, so growing it moves the shared edge.
    os.command_run("resize left -20");
    os.settle();
    try expect_frame(Rect.init(0, 38, 884, 1079), a);
    try expect_frame(Rect.init(884, 38, 844, 1079), b);
    // No window shrinks below a tenth of its split.
    os.command_run("resize right 5000");
    os.settle();
    try expect_frame(Rect.init(0, 38, 1555, 1079), a);
    try expect_frame(Rect.init(1555, 38, 173, 1079), b);
    sets = os.frames_set;
    os.command_run("resize right 5000");
    os.command_run("resize right 1");
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
}

// https://github.com/asmvik/yabai/issues/685
// https://github.com/asmvik/yabai/issues/2475
// https://github.com/asmvik/yabai/issues/837
test "gaps are the same between windows and at every edge of the screen" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.command_run("toggle gaps");
    os.settle();
    try expect_frame(Rect.init(10, 48, 849, 1059), a);
    try expect_frame(Rect.init(869, 48, 849, 525), b);
    try expect_frame(Rect.init(869, 583, 849, 524), c);
    try testing.expectEqual(laptop.bottom() - 10, frame_of(c).bottom());
    try testing.expectEqual(laptop.right() - 10, frame_of(c).right());
    // Only this workspace: another one keeps the configured gaps.
    os.command_run("workspace 2");
    const d = open(os, zed, .{});
    os.settle();
    try expect_frame(screen, d);
    os.command_run("workspace 1");
    os.command_run("toggle gaps");
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
}

// https://github.com/asmvik/yabai/issues/2088
// https://github.com/asmvik/yabai/issues/1577
// https://github.com/asmvik/yabai/issues/526
test "warp and swap carry a window over the edge to the next monitor, and focus with it" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(external_screen, b);
    os.command_run("focus-monitor 1");
    os.command_run("warp east");
    os.settle();
    try expect_frame(Rect.init(1728, 38, 1280, 1402), b);
    try expect_frame(Rect.init(3008, 38, 1280, 1402), a);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    os.command_run("swap west");
    os.settle();
    try expect_frame(Rect.init(1728, 38, 1280, 1402), a);
    try expect_frame(Rect.init(3008, 38, 1280, 1402), b);
    // At the left edge of this monitor the same key goes on to the laptop.
    os.command_run("swap west");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external_screen, b);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    // And at the far edge of the last monitor nothing happens at all.
    const sets = os.frames_set;
    os.command_run("swap west");
    os.command_run("warp north");
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
}

// https://github.com/asmvik/yabai/issues/402
// https://github.com/asmvik/yabai/issues/376
// https://github.com/asmvik/yabai/issues/340
test "a tile dropped on its own place snaps back, dropped on another it trades places" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("toggle split");
    os.settle();
    const upper = Rect.init(0, 38, 1728, 540);
    const lower = Rect.init(0, 578, 1728, 539);
    try expect_frame(upper, a);
    try expect_frame(lower, b);
    // Nudged by accident: the middle of the window is still over its own tile.
    os.window_drag(a, Rect.init(40, 90, 1728, 540));
    os.settle();
    try expect_frame(upper, a);
    try expect_frame(lower, b);
    // Dropped on the window below: they trade places and the split stays a stack.
    os.window_drag(a, Rect.init(40, 600, 1728, 540));
    os.settle();
    try expect_frame(upper, b);
    try expect_frame(lower, a);
    // An outer edge pulled with the mouse has no split to move, and snaps back.
    os.window_drag(a, Rect.init(0, 578, 1500, 539));
    os.settle();
    try expect_frame(lower, a);
    try expect_frame(upper, b);
}

// https://github.com/asmvik/yabai/issues/103
// https://github.com/asmvik/yabai/issues/506
// https://github.com/asmvik/yabai/issues/2817
test "a tile dragged to a monitor with no windows moves there" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    os.window_drag(a, Rect.init(2400, 200, 864, 1079));
    os.settle();
    try expect_frame(external_screen, a);
    try expect_frame(screen, b);
    try testing.expectEqual(engine.monitors[1].workspace, workspace_of(a));
    // The other one follows the same way and lands beside it.
    os.window_drag(b, Rect.init(1800, 100, 1728, 1079));
    os.settle();
    try expect_frame(Rect.init(1728, 38, 1280, 1402), a);
    try expect_frame(Rect.init(3008, 38, 1280, 1402), b);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
}

// https://github.com/asmvik/yabai/issues/2341
// https://github.com/asmvik/yabai/issues/2292
// https://github.com/asmvik/yabai/issues/188
test "a floating window sent to a smaller monitor lands on it" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    os.command_run("focus-monitor 2");
    const far = Rect.init(3800, 900, 400, 300);
    const note = open(os, zed, .{ .kind = .dialog, .frame = far });
    os.settle();
    try expect_frame(far, note);
    // The same spot on the laptop would be past its right edge: it stops at the corner.
    os.command_run("send-monitor 1 --follow");
    os.settle();
    try expect_frame(Rect.init(1328, 817, 400, 300), note);
    try testing.expectEqual(note, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    // A spot that exists on both monitors is kept.
    _ = run(os, "float {d} --bounds 0.1,0.1,0.2,0.2", .{note});
    os.settle();
    try expect_frame(Rect.init(172, 145, 345, 215), note);
    os.command_run("send-monitor 2 --follow");
    os.settle();
    try expect_frame(Rect.init(1900, 145, 345, 215), note);
}

// https://github.com/asmvik/yabai/issues/820
// https://github.com/asmvik/yabai/issues/2300
test "a floating window dragged to another monitor belongs to that monitor from then on" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const note = open(os, zed, .{ .kind = .dialog, .frame = Rect.init(700, 400, 300, 200) });
    os.settle();
    const there = Rect.init(2500, 300, 300, 200);
    os.window_drag(note, there);
    os.settle();
    try expect_frame(there, note);
    try testing.expectEqual(engine.monitors[1].workspace, workspace_of(note));
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    // Switching the laptop's workspace no longer takes it away, and leaves no hole behind.
    os.window_click(a);
    os.settle();
    os.command_run("workspace 5");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(there, note);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(there, note);
}

// Displays.

/// Laptop and external display, three workspaces in use: one window on the laptop's, and
/// on the external display one hidden workspace with a window and the one showing with
/// another. Focus is on the laptop. Returns the windows in that order.
fn two_displays(os: *sim.Simulator) [3]WindowId {
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const on_laptop = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const hidden = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 5");
    const showing = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    std.debug.assert(engine.focused_window == on_laptop);
    std.debug.assert(engine.monitors[1].workspace == 4);
    std.debug.assert(frame_of(showing).eql(external_screen));
    std.debug.assert(parked_on(hidden, external));
    return .{ on_laptop, hidden, showing };
}

// https://github.com/asmvik/yabai/issues/259
// https://github.com/asmvik/yabai/issues/159
test "displays that sleep and wake show what they showed, and no window moves" {
    const os = boot("");
    const windows = two_displays(os);
    const frames = [3]Rect{ frame_of(windows[0]), frame_of(windows[1]), frame_of(windows[2]) };
    const sets = os.frames_set;
    displays_set(os, &.{});
    try testing.expectEqual(@as(u32, 0), engine.monitors_count);
    os.advance(60_000);
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    try testing.expectEqual(windows[0], engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    for (windows, frames) |id, frame| try expect_frame(frame, id);
    try testing.expectEqual(sets, os.frames_set);
    // The monitor in use is remembered too when it has no window to tell by.
    os.command_run("focus-monitor 2");
    os.command_run("workspace 7");
    os.settle();
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    displays_set(os, &.{});
    os.advance(60_000);
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(@as(u8, 6), engine.monitors[1].workspace);
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    try expect_frame(frames[0], windows[0]);
}

// https://github.com/asmvik/yabai/issues/259
// https://github.com/asmvik/yabai/issues/884
// https://github.com/asmvik/yabai/issues/2746
test "windows that macOS shuffles while the displays sleep are put back" {
    const os = boot("");
    const windows = two_displays(os);
    const frames = [3]Rect{ frame_of(windows[0]), frame_of(windows[1]), frame_of(windows[2]) };
    displays_set(os, &.{});
    // With nowhere to show them, macOS piles the windows up wherever it likes.
    os.window_drag(windows[0], Rect.init(0, 25, 1024, 743));
    os.window_drag(windows[1], Rect.init(0, 25, 1024, 743));
    os.window_drag(windows[2], Rect.init(100, 125, 1024, 600));
    os.advance(1);
    os.advance(60_000);
    os.monitors_set(1);
    os.settle();
    for (windows, frames) |id, frame| try expect_frame(frame, id);
    try testing.expectEqual(windows[0], engine.focused_window);
    // The same when the news of the shuffle only arrives together with the displays.
    os.window_drag(windows[0], Rect.init(0, 25, 1024, 743));
    os.window_drag(windows[1], Rect.init(0, 25, 1024, 743));
    os.window_drag(windows[2], Rect.init(100, 125, 1024, 600));
    os.monitors_set(1);
    os.settle();
    try expect_frame(frames[0], windows[0]);
    try expect_frame(frames[2], windows[2]);
    try testing.expect(parked_on(windows[1], external) and parked(windows[1]));
    for (windows) |id| {
        try testing.expectEqual(engine_module.Mode.tiled, mode_of(id));
        try testing.expect(!engine.window_find(id).?.auto_floated);
    }
}

// https://github.com/asmvik/yabai/issues/259
// https://github.com/asmvik/yabai/issues/1237
// https://github.com/asmvik/yabai/issues/1785
test "a display that is unplugged and comes back shows the workspace it showed" {
    const os = boot("");
    const windows = two_displays(os);
    const frames = [3]Rect{ frame_of(windows[0]), frame_of(windows[1]), frame_of(windows[2]) };
    os.monitors_set(0);
    os.settle();
    // Nothing is lost meanwhile: the external display's windows wait off screen.
    try expect_frame(screen, windows[0]);
    try testing.expect(parked(windows[1]) and parked(windows[2]));
    try testing.expectEqual(@as(u8, 4), workspace_of(windows[2]));
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    for (windows, frames) |id, frame| try expect_frame(frame, id);
    try testing.expectEqual(windows[0], engine.focused_window);
    // Also when the user looked at one of its workspaces on the laptop in between: that
    // is the one in use, and it goes back to its own display.
    os.monitors_set(0);
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, windows[1]);
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    try testing.expectEqual(@as(u8, 1), engine.monitors[1].workspace);
    try expect_frame(screen, windows[0]);
    try expect_frame(external_screen, windows[1]);
    try testing.expect(parked_on(windows[2], external));
    try testing.expectEqual(windows[1], engine.focused_window);
}

const lid_closed = [_]MonitorInfo{display(2, 0, 0, 2560, 1440, true)};

// https://github.com/asmvik/yabai/issues/1608
// https://github.com/asmvik/yabai/issues/323
// https://github.com/asmvik/yabai/issues/880
test "closing the lid keeps the window in use in view, opening it puts everything back" {
    const os = boot("");
    const windows = two_displays(os);
    const frames = [3]Rect{ frame_of(windows[0]), frame_of(windows[1]), frame_of(windows[2]) };
    // Only the external display is left, and it is the main one now.
    displays_set(os, &lid_closed);
    os.settle();
    const whole = Rect.init(0, 0, 2560, 1440);
    try expect_frame(Rect.init(0, 38, 2560, 1402), windows[0]);
    try testing.expectEqual(windows[0], engine.focused_window);
    try testing.expect(parked_on(windows[1], whole) and parked_on(windows[2], whole));
    // Every workspace can still be reached by its number.
    os.command_run("workspace 5");
    os.settle();
    try expect_frame(Rect.init(0, 38, 2560, 1402), windows[2]);
    try testing.expect(parked_on(windows[0], whole));
    os.command_run("workspace 1");
    os.settle();
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    for (windows, frames) |id, frame| try expect_frame(frame, id);
    try testing.expectEqual(windows[0], engine.focused_window);
}

// https://github.com/asmvik/yabai/issues/118
// https://github.com/asmvik/yabai/issues/811
test "rearranging the displays carries every workspace along with its display" {
    const os = boot("");
    const windows = two_displays(os);
    os.monitors_set(2); // External display on the left, the laptop lower on its right.
    os.settle();
    try expect_frame(Rect.init(2560, 361, 1728, 1079), windows[0]);
    try expect_frame(Rect.init(0, 38, 2560, 1402), windows[2]);
    try testing.expect(parked_on(windows[1], Rect.init(0, 0, 2560, 1440)));
    try testing.expectEqual(windows[0], engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    // The same list again changes nothing and moves nothing.
    const sets = os.frames_set;
    const revision = engine.revision;
    os.monitors_set(2);
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    try testing.expectEqual(revision, engine.revision);
}

const dock_on_the_left = [_]MonitorInfo{.{
    .display = 1,
    .frame = laptop,
    .visible = Rect.init(80, 38, 1648, 1079),
    .main = true,
}};

// https://github.com/asmvik/yabai/issues/793
// https://github.com/asmvik/yabai/issues/1951
// https://github.com/asmvik/yabai/issues/1593
test "a change of the usable area of a display moves the tiles and nothing else" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const hidden = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const home = Rect.init(700, 400, 300, 200);
    const note = open(os, zed, .{ .kind = .dialog, .frame = home });
    os.settle();
    const sets = engine.stats.frames_set;
    // The Dock appears on the left.
    displays_set(os, &dock_on_the_left);
    os.settle();
    try expect_frame(Rect.init(80, 38, 824, 1079), a);
    try expect_frame(Rect.init(904, 38, 824, 1079), b);
    try expect_frame(home, note);
    try testing.expect(parked(hidden));
    try testing.expectEqual(@as(u64, 2), engine.stats.frames_set - sets);
    try testing.expectEqual(note, engine.focused_window);
}

// https://github.com/asmvik/yabai/issues/2663
// https://github.com/asmvik/yabai/issues/1569
// https://github.com/asmvik/yabai/issues/2789
test "sending the last window to another monitor leaves the user on this one" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const brave = os.app_launch("Brave Browser", "com.brave.Browser");
    const browser = open(os, brave, .{});
    os.settle();
    os.command_run("send-monitor 2");
    os.settle();
    try expect_frame(external_screen, browser);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    // An empty workspace can be shown here, and the browser saying again that it has
    // focus does not pull the user after it.
    os.command_run("workspace 3");
    os.advance(800);
    os.focus_repeat();
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    os.settle();
    try expect_frame(screen, editor);
    try expect_frame(external_screen, browser);
}

// https://github.com/asmvik/yabai/issues/721
// https://github.com/asmvik/yabai/issues/1291
// https://github.com/asmvik/yabai/issues/303
test "workspace next and prev stay on the monitor in use and undo each other" {
    const os = boot("");
    const windows = two_displays(os);
    os.command_run("workspace 3");
    const third = open(os, os.app_launch("Slack", "com.tinyspeck.slackmacgap"), .{});
    os.settle();
    try expect_frame(screen, third);
    // The laptop has workspaces 1 and 3, the external display 2 and 5.
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try testing.expectEqual(windows[0], engine.focused_window);
    os.command_run("workspace prev");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(third, engine.focused_window);
    os.command_run("workspace prev");
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    // The external display kept showing what it showed all along.
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    try expect_frame(external_screen, windows[2]);
}

// https://github.com/asmvik/yabai/issues/2673
// https://github.com/asmvik/yabai/issues/1053
test "workspace recent goes back and forth, and a workspace shown elsewhere is focused there" {
    const os = boot("");
    const windows = two_displays(os);
    os.command_run("workspace 3");
    os.command_run("workspace 6");
    os.command_run("workspace recent");
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    os.command_run("workspace recent");
    try testing.expectEqual(@as(u8, 5), engine.workspace_current());
    os.command_run("workspace recent");
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    // Workspace 5 shows on the external display: asking for it goes there and leaves the
    // laptop as it is.
    os.command_run("workspace 5");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(windows[2], engine.focused_window);
    try testing.expectEqual(windows[2], os.focused);
    try testing.expectEqual(@as(u8, 2), engine.monitors[0].workspace);
    try expect_frame(external_screen, windows[2]);
    // A hidden workspace of the other display shows on that display, not on this one.
    os.command_run("focus-monitor 1");
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try expect_frame(external_screen, windows[1]);
    try testing.expectEqual(@as(u8, 2), engine.monitors[0].workspace);
}

// https://github.com/asmvik/yabai/issues/1107
// https://github.com/asmvik/yabai/issues/1676
// https://github.com/asmvik/yabai/issues/2241
test "a focus request overtaken by the next command does not pull the user back" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(b, os.focused);
    // Two keys pressed faster than the OS confirms the focus that the first one asked for:
    // the confirmation arrives when its window is hidden again.
    os.command_run("workspace 1");
    os.command_run("workspace 3");
    os.settle();
    try testing.expectEqual(a, os.focused);
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expect(parked(a) and parked(b));
    // The same with a window that is sent away right after it was given focus.
    os.command_run("workspace 2");
    os.command_run("send 4");
    os.settle();
    try testing.expectEqual(b, os.focused);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expectEqual(@as(u8, 3), workspace_of(b));
    try testing.expect(parked(a) and parked(b));
    // A burst that ends on a window ends with that window in focus.
    os.command_run("workspace 1");
    os.command_run("workspace 3");
    os.command_run("workspace 4");
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try expect_frame(screen, a);
}

// Native tabs.

// https://github.com/asmvik/yabai/issues/68
// https://github.com/asmvik/yabai/issues/199
// https://github.com/asmvik/yabai/issues/1999
test "switching between the tabs of a window moves nothing" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const editor = open(os, zed, .{});
    os.window_click(terminal);
    os.settle();
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    const sets = os.frames_set;
    for (0..3) |_| {
        os.window_click(terminal);
        os.settle();
        try testing.expectEqual(terminal, engine.focused_window);
        try testing.expectEqual(terminal, engine.window_find(tab).?.tab_of);
        os.window_click(tab);
        os.settle();
        try testing.expectEqual(tab, engine.focused_window);
        try testing.expectEqual(tab, engine.window_find(terminal).?.tab_of);
    }
    try testing.expectEqual(sets, os.frames_set);
    try expect_frame(left_half, terminal);
    try expect_frame(left_half, tab);
    try expect_frame(right_half, editor);
    // Focus by direction sees one window there, whichever tab shows.
    os.command_run("focus east");
    os.command_run("focus west");
    try testing.expectEqual(tab, engine.focused_window);
}

// https://github.com/asmvik/yabai/issues/951
// https://github.com/asmvik/yabai/issues/2599
// https://github.com/asmvik/yabai/issues/2717
test "a tab dragged out of its window becomes a tile beside it" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const editor = open(os, zed, .{});
    os.window_click(terminal);
    os.settle();
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    os.window_click(terminal);
    os.settle();
    os.tab_detach(tab);
    os.settle();
    try testing.expectEqual(@as(WindowId, 0), engine.window_find(tab).?.tab_of);
    try testing.expectEqual(@as(WindowId, 0), engine.window_find(terminal).?.tab_of);
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(tab));
    try expect_frame(Rect.init(0, 38, 864, 540), terminal);
    try expect_frame(Rect.init(0, 578, 864, 539), tab);
    try expect_frame(right_half, editor);
    try testing.expectEqual(workspace_of(terminal), workspace_of(tab));
}

// https://github.com/asmvik/yabai/issues/1594
// https://github.com/asmvik/yabai/issues/389
test "the tabs of a window go to another workspace together and come back together" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    const terminal = open(os, ghostty, .{});
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    try testing.expectEqual(tab, engine.focused_window);
    os.command_run("send 4");
    os.settle();
    try testing.expectEqual(@as(u8, 3), workspace_of(tab));
    try testing.expectEqual(@as(u8, 3), workspace_of(terminal));
    try testing.expect(parked(tab) and parked(terminal));
    try expect_frame(screen, editor);
    try testing.expectEqual(editor, engine.focused_window);
    // The background tab is asked for by id: its window comes, showing that tab's group.
    _ = run(os, "focus {d}", .{tab});
    os.settle();
    try testing.expectEqual(@as(u8, 3), engine.workspace_current());
    try expect_frame(screen, tab);
    try expect_frame(screen, terminal);
    try testing.expect(parked(editor));
}

// Rules.

// https://github.com/asmvik/yabai/issues/1383
// https://github.com/asmvik/yabai/issues/1627
// https://github.com/asmvik/yabai/issues/27
test "every rule that matches a window applies to it, each once" {
    const os = boot(
        "rule app=\"Simulator\" : float\n" ++
            "rule app=\"Simulator\" title=\"Debug\" : workspace 3\n",
    );
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, ghostty, .{});
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const phone_home = Rect.init(400, 100, 400, 800);
    const phone = open(os, ios, .{ .title = "iPhone", .frame = phone_home });
    os.settle();
    try testing.expectEqual(engine_module.Mode.floating, mode_of(phone));
    try expect_frame(phone_home, phone);
    try expect_frame(screen, terminal);
    try testing.expectEqual(phone, engine.focused_window);
    const debug_home = Rect.init(500, 200, 600, 400);
    const debug = open(os, ios, .{ .title = "Debug console", .frame = debug_home });
    os.settle();
    // Floated by the first rule and sent away by the second, without focus or a flash.
    try testing.expectEqual(engine_module.Mode.floating, mode_of(debug));
    try testing.expectEqual(@as(u8, 2), workspace_of(debug));
    try testing.expect(parked(debug));
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(phone, engine.focused_window);
    try testing.expectEqual(phone, os.focused);
    try expect_frame(phone_home, phone);
    try expect_frame(screen, terminal);
    os.command_run("workspace 3");
    os.settle();
    try expect_frame(debug_home, debug);
    // A later title change is not a reason to move a window that the user already has.
    os.command_run("workspace 1");
    os.advance(5000);
    os.window_title(phone, "Debug iPhone");
    os.settle();
    try testing.expectEqual(@as(u8, 0), workspace_of(phone));
    try expect_frame(phone_home, phone);
}

// https://github.com/asmvik/yabai/issues/707
// https://github.com/asmvik/yabai/issues/366
// https://github.com/asmvik/yabai/issues/1268
test "a rule with an application and a title needs both, and leaves the user's choice alone" {
    const os = boot("rule app=\"Zed\" title=\"Settings\" : float\n");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const code = open(os, zed, .{ .title = "main.zig" });
    const settings_home = Rect.init(300, 200, 700, 500);
    const settings = open(os, zed, .{ .title = "Zed Settings", .frame = settings_home });
    const terminal = open(os, ghostty, .{ .title = "Settings" });
    os.settle();
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(code));
    try testing.expectEqual(engine_module.Mode.floating, mode_of(settings));
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(terminal));
    try expect_frame(left_half, code);
    try expect_frame(right_half, terminal);
    try expect_frame(settings_home, settings);
    // A window whose title arrives late, and which the user tiled by hand meanwhile.
    const late = open(os, zed, .{ .title = "Untitled", .late_title = true });
    os.advance(100);
    _ = run(os, "tile {d}", .{late});
    os.advance(1000);
    os.settle();
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(late));
}

// https://github.com/asmvik/yabai/issues/568
// https://github.com/asmvik/yabai/issues/1604
// https://github.com/asmvik/yabai/issues/2553
test "an ignored window is never moved, tiled, parked or closed with the others" {
    const os = boot("rule app=\"Simulator\" : ignore\n");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, ghostty, .{});
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const home = Rect.init(400, 100, 400, 800);
    const phone = open(os, ios, .{ .frame = home });
    os.settle();
    try expect_frame(screen, terminal);
    try expect_frame(home, phone);
    try testing.expectEqual(phone, os.focused);
    try testing.expectEqual(terminal, engine.focused_window);
    os.command_run("layout bsp");
    os.command_run("retile");
    os.command_run("close-others");
    os.command_run("focus next --wrap");
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(terminal));
    try expect_frame(home, phone);
    try testing.expect(os.window_find(phone) != null);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, terminal);
    try expect_frame(home, phone);
    try testing.expectEqual(@as(u32, 0), engine.window_find(phone).?.sets_total);
    try expect_reply("error: conflict", run(os, "focus {d}", .{phone}));
}

fn expect_reply(prefix: []const u8, reply: []const u8) !void {
    if (std.mem.startsWith(u8, reply, prefix)) return;
    std.debug.print("expected a reply starting with {s}, found {s}\n", .{ prefix, reply });
    return error.TestUnexpectedResult;
}

// https://github.com/asmvik/yabai/issues/662
// https://github.com/asmvik/yabai/issues/489
test "focus can be taken back from a window that is ignored" {
    const os = boot("rule app=\"Simulator\" : ignore\n");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, ghostty, .{});
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const phone = open(os, ios, .{ .frame = Rect.init(400, 100, 400, 800) });
    os.settle();
    try testing.expectEqual(phone, os.focused);
    try testing.expectEqual(terminal, engine.focused_window);
    // The only window we manage is the one we believe has focus; asking for it by name
    // must still reach the OS, which has the keyboard somewhere else.
    _ = run(os, "focus {d}", .{terminal});
    os.settle();
    try testing.expectEqual(terminal, os.focused);
    try testing.expectEqual(terminal, engine.focused_window);
    // In agreement again, the same command asks the OS for nothing.
    os.command_run("focus next --wrap");
    try testing.expectEqual(@as(u32, 0), engine.effects_count);
}

// https://github.com/asmvik/yabai/issues/1066
// https://github.com/asmvik/yabai/issues/1783
// https://github.com/asmvik/yabai/issues/859
test "a rule sends a window to a workspace that shows on another monitor, without focus" {
    const os = boot("rule app=\"Simulator\" : workspace 2\n");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, ghostty, .{});
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.monitors[1].workspace);
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const phone = open(os, ios, .{ .frame = Rect.init(400, 100, 400, 800) });
    os.settle();
    try expect_frame(external_screen, phone);
    try expect_frame(screen, terminal);
    try testing.expectEqual(terminal, engine.focused_window);
    try testing.expectEqual(terminal, os.focused);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    // Once the rule has had its say the window is the user's to focus.
    os.advance(2000);
    os.window_click(phone);
    os.settle();
    try testing.expectEqual(phone, engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
}

// Windows that come and go.

// https://github.com/asmvik/yabai/issues/1418
// https://github.com/asmvik/yabai/issues/569
// https://github.com/asmvik/yabai/issues/2534
test "no command gives a minimized window a tile" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    const docked = frame_of(b);
    os.command_run("layout float");
    os.command_run("layout bsp");
    os.command_run("retile");
    os.command_run("balance");
    try expect_reply("", run(os, "tile {d}", .{b}));
    try expect_reply("error: conflict", run(os, "zoom {d}", .{b}));
    try expect_reply("error: conflict", run(os, "focus {d}", .{b}));
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ b, a }));
    os.command_run("focus east");
    os.command_run("focus next --wrap");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(docked, b);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expect(std.mem.indexOf(u8, run(os, "query tree", .{}), "window 101") == null);
    // It is still a tile when it comes back.
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/asmvik/yabai/issues/348
// https://github.com/asmvik/yabai/issues/1126
// https://github.com/asmvik/yabai/issues/2828
test "an application that quits leaves no tile behind, whether or not its windows say so" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    var slack: i32 = 0;
    for (0..4) |_| {
        slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
        _ = open(os, slack, .{});
        _ = open(os, slack, .{});
        const hidden = open(os, slack, .{});
        os.command_run("send 2");
        os.settle();
        try testing.expect(parked(hidden));
        try testing.expectEqual(@as(u32, 4), windows_known());
        // Some of the windows of a dying application never report that they are gone.
        os.app_quit(slack);
        os.settle();
        try testing.expectEqual(@as(u32, 1), windows_known());
        try expect_frame(screen, a);
        try testing.expectEqual(a, engine.focused_window);
        try testing.expectEqual(a, os.focused);
    }
    try testing.expect(std.mem.indexOf(u8, run(os, "query workspaces", .{}), "\n 2\t") == null);
}

fn windows_known() u32 {
    var count: u32 = 0;
    for (&engine.windows) |*window| count += @intFromBool(window.id != 0);
    return count;
}

// https://github.com/asmvik/yabai/issues/36
// https://github.com/asmvik/yabai/issues/590
// https://github.com/asmvik/yabai/issues/2477
test "a window in native fullscreen leaves the layout and returns to it as a tile" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    const sets = engine.window_find(b).?.sets_total;
    inject(os, .{ .window_fullscreen = .{ .id = b, .fullscreen = true } });
    os.settle();
    try expect_frame(screen, a);
    // It lives on a Space of its own now: workspaces come and go without touching it.
    os.command_run("workspace 2");
    os.command_run("workspace 1");
    os.command_run("retile");
    os.settle();
    try testing.expectEqual(sets, engine.window_find(b).?.sets_total);
    try expect_frame(screen, a);
    inject(os, .{ .window_fullscreen = .{ .id = b, .fullscreen = false } });
    os.settle();
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(b));
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/asmvik/yabai/issues/109
// https://github.com/asmvik/yabai/issues/289
// https://github.com/asmvik/yabai/issues/403
test "a tile that its application resizes once is put back once, and stays a tile" {
    const os = boot("");
    const firefox = os.app_launch("Firefox", "org.mozilla.firefox");
    const a = open(os, firefox, .{});
    const b = open(os, firefox, .{});
    os.settle();
    const sets = os.frames_set;
    // The application restores the size it had when it was last used.
    self_move(os, b, Rect.init(900, 100, 700, 500));
    os.advance(100);
    try expect_frame(Rect.init(900, 100, 700, 500), b);
    os.settle();
    try expect_frame(right_half, b);
    try expect_frame(left_half, a);
    try testing.expectEqual(@as(u64, 1), os.frames_set - sets);
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(b));
    try testing.expectEqual(@as(u64, 0), engine.stats.windows_auto_floated);
}

// Commands.

// https://github.com/asmvik/yabai/issues/1114
// https://github.com/asmvik/yabai/issues/531
// https://github.com/asmvik/yabai/issues/301
test "focus there and back returns to the window it left" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    // The left window has two neighbours on its right; the one last used is the one.
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus east");
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus north");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus west");
    os.command_run("focus east");
    try testing.expectEqual(b, engine.focused_window);
    // Up and down never leave the column, left of the left window is nothing.
    os.command_run("focus north");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus south");
    os.command_run("focus south");
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus west");
    os.command_run("focus west");
    os.command_run("focus north");
    os.command_run("focus south");
    try testing.expectEqual(a, engine.focused_window);
    os.settle();
    try testing.expectEqual(a, os.focused);
}

const burst = [_][]const u8{
    "swap west",     "focus east",         "warp south",        "toggle zoom-parent",
    "focus north",   "toggle zoom-parent", "resize right 40",   "insert north",
    "rotate 90",     "swap north",         "toggle float",      "toggle float",
    "mirror y-axis", "balance",            "focus prev --wrap", "warp west",
};

/// Opens four windows, runs the burst with or without waiting for the OS in between,
/// and returns where the windows ended up.
fn burst_run(patient: bool) [4]Rect {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    var windows: [4]WindowId = undefined;
    for (&windows) |*id| id.* = open(os, zed, .{});
    os.settle();
    for (burst) |text| {
        os.command_run(text);
        if (patient) os.settle();
    }
    os.settle();
    var frames: [4]Rect = undefined;
    for (windows, &frames) |id, *frame| frame.* = frame_of(id);
    return frames;
}

// https://github.com/asmvik/yabai/issues/1107
// https://github.com/asmvik/yabai/issues/1072
test "commands sent faster than the OS answers end where they end one at a time" {
    const patient = burst_run(true);
    const hasty = burst_run(false);
    for (patient, hasty) |expected, actual| try testing.expect(expected.eql(actual));
    // And the burst did rearrange things: this is not a comparison of two untouched layouts.
    try testing.expect(!patient[0].eql(left_half));
}

// https://github.com/asmvik/yabai/issues/760
// https://github.com/asmvik/yabai/issues/255
test "a sticky window follows the workspaces of its own monitor only, until it is tiled" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const home = Rect.init(1200, 100, 400, 300);
    const note = open(os, zed, .{ .kind = .dialog, .frame = home });
    os.settle();
    os.command_run("toggle sticky");
    os.command_run("focus-monitor 2");
    os.command_run("workspace 6");
    os.settle();
    try expect_frame(home, note);
    try testing.expectEqual(@as(u8, 0), workspace_of(note));
    os.command_run("focus-monitor 1");
    os.command_run("workspace 3");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(home, note);
    try testing.expectEqual(@as(u8, 2), workspace_of(note));
    try testing.expectEqual(note, engine.focused_window);
    _ = run(os, "tile {d}", .{note});
    os.settle();
    try expect_frame(screen, note);
    os.command_run("workspace 1");
    os.settle();
    try testing.expect(parked(note));
    try expect_frame(screen, a);
}

// https://github.com/asmvik/yabai/issues/2569
test "floating the whole workspace moves nothing, and tiling it again restores the tiles" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    os.command_run("layout float");
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    try testing.expectEqual(engine_module.Mode.floating, mode_of(a));
    try testing.expectEqual(engine_module.Mode.floating, mode_of(b));
    os.window_drag(b, Rect.init(300, 300, 500, 400));
    os.settle();
    try expect_frame(Rect.init(300, 300, 500, 400), b);
    try expect_frame(left_half, a);
    os.command_run("layout bsp");
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/asmvik/yabai/issues/2533
test "a title with line breaks and tabs still makes one line per window" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{ .title = "build\nlog\tview\r\n" });
    const b = open(os, zed, .{ .title = "plain" });
    os.settle();
    const lines = run(os, "query windows", .{});
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, lines, "\n"));
    try testing.expect(std.mem.indexOf(u8, lines, "build log view") != null);
    os.window_title(b, "now\nwith\x01breaks");
    os.settle();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, run(os, "query windows", .{}), "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, run(os, "query focus", .{}), "\n"));
    const described = run(os, "query window {d}", .{a});
    try testing.expectEqual(@as(usize, 14), std.mem.count(u8, described, "\n"));
    // What is kept has no line break left in it, so the JSON has none to escape either.
    try testing.expect(std.mem.indexOf(u8, run(os, "query windows --json", .{}), "\\n") == null);
}

// The engine alone: what the simulated OS cannot be made to do.

const laptop_only = [_]MonitorInfo{display(1, 0, 0, 1728, 1117, true)};

/// Starts the engine with the built-in configuration, the laptop screen and one
/// application, without the simulator.
fn boot_engine() void {
    var config: config_module.Config = undefined;
    config.load_default();
    engine.init(&config);
    _ = engine.step(.{ .monitors_changed = &laptop_only }, 1000);
    const emacs: engine_module.AppInfo = .{ .pid = 7, .name = "Emacs", .bundle = "org.gnu.Emacs" };
    _ = engine.step(.{ .app_launched = emacs }, 1000);
}

fn appeared(id: WindowId, kind: engine_module.WindowKind, fullscreen: bool) engine_module.Event {
    return .{ .window_appeared = .{
        .id = id,
        .pid = 7,
        .title = "scratch",
        .frame = Rect.init(100, 100, 800, 600),
        .kind = kind,
        .resizable = true,
        .fullscreen = fullscreen,
    } };
}

fn frames_asked(effects: []const engine_module.Effect) u32 {
    var count: u32 = 0;
    for (effects) |effect| count += @intFromBool(effect == .set_frame);
    return count;
}

// https://github.com/asmvik/yabai/issues/86
// https://github.com/asmvik/yabai/issues/235
test "a window that rounds its size down to whole characters is asked twice more, then left" {
    boot_engine();
    var effects = engine.step(appeared(50, .standard, false), 1000);
    try testing.expectEqual(@as(usize, 1), effects.len);
    try testing.expect(effects[0].set_frame.frame.eql(screen));
    // The simulator only knows windows that stay too large; this one stays too small.
    const snapped = Rect.init(0, 38, 1721, 1068);
    var asked: u32 = 0;
    for (0..6) |_| {
        const applied: engine_module.Event =
            .{ .window_frame_applied = .{ .id = 50, .frame = snapped } };
        asked += frames_asked(engine.step(applied, 1001));
    }
    try testing.expectEqual(@as(u32, engine_module.attempts_max), asked);
    try testing.expect(engine.next_deadline_ms() == null);
    // The notifications that trail the resize are echoes, not a fight to pick.
    const echo: engine_module.Event =
        .{ .window_frame_changed = .{ .id = 50, .frame = snapped, .by_user = false } };
    effects = engine.step(echo, 1050);
    try testing.expectEqual(@as(usize, 0), effects.len);
    try testing.expect(engine.next_deadline_ms() == null);
    try testing.expectEqual(engine_module.Mode.tiled, engine.window_find(50).?.mode);
    try testing.expectEqual(@as(u64, 0), engine.stats.windows_auto_floated);
}

// https://github.com/asmvik/yabai/issues/154
// https://github.com/asmvik/yabai/issues/174
// https://github.com/asmvik/yabai/issues/1269
test "a window is announced once when it is taken on and once when it is gone" {
    boot_engine();
    _ = engine.step(appeared(50, .standard, false), 1000);
    try testing.expectEqual(engine_module.Note{ .window_created = 50 }, engine.notes_slice()[0]);
    // Reported again, as when a window is found both by its notification and by a scan.
    _ = engine.step(appeared(50, .standard, false), 1000);
    try testing.expectEqual(@as(usize, 0), engine.notes_slice().len);
    _ = engine.step(appeared(51, .popup, false), 1000);
    try testing.expectEqual(@as(usize, 0), engine.notes_slice().len);
    _ = engine.step(.{ .window_focused = 50 }, 1000);
    try testing.expectEqual(engine_module.Note{ .focus_changed = 50 }, engine.notes_slice()[0]);
    _ = engine.step(.{ .window_destroyed = 50 }, 1001);
    const notes = engine.notes_slice();
    try testing.expectEqual(@as(usize, 3), notes.len);
    try testing.expectEqual(engine_module.Note{ .window_closed = 50 }, notes[0]);
    try testing.expectEqual(engine_module.Note{ .focus_changed = 0 }, notes[1]);
    try testing.expect(notes[2] == .view_changed);
    // Whoever hears that it closed and asks finds it gone already.
    try testing.expect(engine.window_find(50) == null);
    _ = engine.step(.{ .window_destroyed = 50 }, 1001);
    try testing.expectEqual(@as(usize, 0), engine.notes_slice().len);
    _ = engine.step(.{ .window_focused = 50 }, 1002);
    try testing.expectEqual(@as(usize, 0), engine.notes_slice().len);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
}

// https://github.com/asmvik/yabai/issues/354
// https://github.com/asmvik/yabai/issues/2576
test "a window found in native fullscreen is left alone until it comes out of it" {
    boot_engine();
    _ = engine.step(appeared(50, .standard, false), 1000);
    var effects = engine.step(appeared(51, .standard, true), 1000);
    try testing.expectEqual(@as(usize, 0), effects.len);
    try testing.expect(!engine.window_find(51).?.in_layout());
    const leaving: engine_module.Event =
        .{ .window_fullscreen = .{ .id = 51, .fullscreen = false } };
    effects = engine.step(leaving, 2000);
    try testing.expectEqual(@as(u32, 2), frames_asked(effects));
    try testing.expect(engine.window_find(51).?.in_layout());
    try testing.expect(engine.window_find(50).?.desired.eql(left_half));
    try testing.expect(engine.window_find(51).?.desired.eql(right_half));
}

// https://github.com/asmvik/skhd/issues/393
// https://github.com/asmvik/skhd/issues/135
// https://github.com/asmvik/skhd/issues/8
test "a chord is one key however its modifiers are written, and an unknown key is an error" {
    var config: config_module.Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const source =
        \\bind alt-shift-h : focus west
        \\bind shift-option-h : focus east
        \\bind cmd-pagup : workspace prev
        \\bind alt-0x99 : balance
        \\bind fn-h : balance
        \\bind mode:resize alt-shift-h : balance
        \\bind mode:resize esc : mode main
        \\bind alt-r : mode resize
    ;
    try testing.expect(!config.load(source, &diagnostics));
    const report = diagnostics.slice();
    // A key that cannot be bound is said so with its line; it never just does nothing.
    try testing.expect(std.mem.indexOf(u8, report, "line 2: DuplicateBinding") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 3: BadKey") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 4: BadKey") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 5: BadModifier") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 1:") == null);
    try testing.expect(std.mem.indexOf(u8, report, "line 6") == null);
}

// https://github.com/asmvik/skhd/issues/37
// https://github.com/asmvik/skhd/issues/82
// https://github.com/asmvik/skhd/issues/340
test "a binding may run commands and change the mode, and a mode may bind bare keys" {
    var config: config_module.Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const source =
        \\bind alt-w : mode window
        \\bind mode:window h : focus west ; mode main
        \\bind mode:window shift-h : swap west
        \\bind mode:window alt-w : mode main ; balance
        \\bind h : balance
    ;
    try testing.expect(config.load(source, &diagnostics));
    const window = config.mode_find("window").?;
    const bare = config.binding_find_in(window, .{}, 4).?;
    try testing.expectEqual(@as(u8, 2), bare.commands_count);
    try testing.expect(bare.commands[0] == .focus and bare.commands[1] == .mode);
    const leave = config.binding_find_in(window, .{ .alt = true }, 13).?;
    try testing.expect(leave.commands[0] == .mode and leave.commands[1] == .balance);
    // The same bare key means something else, or nothing, outside the mode.
    try testing.expect(config.binding_find(.{}, 4).?.commands[0] == .balance);
    try testing.expect(config.binding_find(.{ .shift = true }, 4) == null);
}
