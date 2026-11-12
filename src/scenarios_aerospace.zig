//! Scenario tests for the failures reported against AeroSpace, the window manager closest
//! in design to this one: Accessibility, workspaces parked off screen, a tree layout.
//! Each test names the behaviour and cites the reports it answers. They run the real
//! engine against the simulated OS with random faults switched off, so every expectation
//! is exact.
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
// The external display of monitor preset 1, to the right of the laptop.
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

fn known(id: WindowId) *engine_module.Window {
    return engine.window_find(id).?;
}

/// How many frames the engine has ever sent to the window.
fn sets_of(id: WindowId) u32 {
    return known(id).sets_total;
}

/// True when the window shows at most a one pixel sliver on every display.
fn sliver_only(id: WindowId) bool {
    const frame = frame_of(id);
    for (engine.monitors[0..engine.monitors_count]) |*monitor| {
        const w = frame.overlap(monitor.frame, .x);
        const h = frame.overlap(monitor.frame, .y);
        if (w > 1 and h > 1) return false;
    }
    return true;
}

/// The windows cover the area exactly: no two overlap and nothing is left over.
fn expect_partition(area: Rect, ids: []const WindowId) !void {
    var covered: i64 = 0;
    for (ids, 0..) |id, index| {
        const frame = frame_of(id);
        try testing.expect(frame.w > 0 and frame.h > 0);
        try testing.expect(frame.x >= area.x and frame.right() <= area.right());
        try testing.expect(frame.y >= area.y and frame.bottom() <= area.bottom());
        covered += frame.area();
        for (ids[0..index]) |other| try testing.expect(!frame.intersects(frame_of(other)));
    }
    try testing.expectEqual(area.area(), covered);
}

/// Every display goes to sleep. The simulator has no arrangement without displays, so
/// the event goes to the engine directly; it must answer with no effects at all.
fn displays_sleep(os: *sim.Simulator) !void {
    const none: []const engine_module.MonitorInfo = &.{};
    const effects = engine.step(.{ .monitors_changed = none }, os.now_ms);
    try testing.expectEqual(@as(usize, 0), effects.len);
}

/// The simulator has no native fullscreen either. The event goes to the engine directly
/// and the frames it answers with are dropped; reporting the same displays again makes
/// the engine send every frame that is still owed through the simulator.
fn fullscreen_set(os: *sim.Simulator, id: WindowId, fullscreen: bool) void {
    _ = engine.step(.{ .window_fullscreen = .{ .id = id, .fullscreen = fullscreen } }, os.now_ms);
    os.monitors_set(0);
}

// Focus and the workspace when windows go away.

// https://github.com/nikitabobko/AeroSpace/issues/854
// https://github.com/nikitabobko/AeroSpace/issues/571
// https://github.com/nikitabobko/AeroSpace/discussions/1048
test "closing a window does not follow its application to a hidden workspace" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const far = open(os, zed, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    const terminal = open(os, ghostty, .{});
    const near = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(near, engine.focused_window);
    // macOS hands focus to the other window of the application, on workspace 2.
    os.window_close(near);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expect(parked(far));
    try expect_frame(screen, terminal);
    try testing.expectEqual(terminal, engine.focused_window);
    try testing.expectEqual(terminal, os.focused);
}

// https://github.com/nikitabobko/AeroSpace/discussions/2350
// https://github.com/nikitabobko/AeroSpace/discussions/964
test "closing the last window of a workspace stays on the empty workspace" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const far = open(os, zed, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    const near = open(os, zed, .{});
    os.settle();
    const sets = os.frames_set;
    os.window_close(near);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expect(parked(far));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expectEqual(sets, os.frames_set);
    // The application saying again where its focus is changes nothing either.
    os.advance(1000);
    os.focus_repeat();
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expect(parked(far));
}

// https://github.com/nikitabobko/AeroSpace/discussions/2350
// https://github.com/nikitabobko/AeroSpace/discussions/2351
test "quitting the last application of a workspace stays there and moves nothing" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const far = open(os, zed, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    const chat = open(os, slack, .{});
    os.settle();
    try expect_frame(screen, chat);
    const sets = os.frames_set;
    os.app_quit(slack);
    os.settle();
    try testing.expect(engine.window_find(chat) == null);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expect(parked(far));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expectEqual(sets, os.frames_set);
}

// https://github.com/nikitabobko/AeroSpace/issues/1614
test "minimizing the focused window does not follow its application to a hidden workspace" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const far = open(os, zed, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    const near = open(os, zed, .{});
    os.settle();
    os.window_minimize(near, true);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expect(parked(far));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    os.advance(1000);
    os.window_minimize(near, false);
    os.settle();
    try expect_frame(screen, near);
    try testing.expectEqual(near, engine.focused_window);
    try testing.expect(parked(far));
}

// https://github.com/nikitabobko/AeroSpace/discussions/2263
test "a window restored from the Dock goes back to its own workspace" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    os.advance(1000);
    // Restoring it is the user going to it: its workspace shows, it does not change.
    os.window_minimize(b, false);
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(b).workspace);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_frame(screen, b);
    try testing.expect(parked(a));
    try testing.expectEqual(b, engine.focused_window);
}

// https://github.com/nikitabobko/AeroSpace/issues/1086
// https://github.com/nikitabobko/AeroSpace/issues/1097
// https://github.com/nikitabobko/AeroSpace/discussions/2243
test "focus returns to the window used before, not to the one macOS picks" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.window_click(b);
    os.settle();
    os.window_click(c);
    os.settle();
    // The simulated macOS would pick the first window of the application.
    os.window_close(c);
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(b, os.focused);
    try expect_partition(screen, &.{ a, b });
}

// https://github.com/nikitabobko/AeroSpace/discussions/2376
// https://github.com/nikitabobko/AeroSpace/discussions/2377
test "focus never lands on a minimized window" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.window_minimize(a, true);
    os.settle();
    try expect_partition(screen, &.{ b, c });
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus west");
    os.command_run("focus prev --wrap");
    os.command_run("focus next --wrap");
    os.settle();
    try testing.expect(engine.focused_window != a);
    try testing.expectEqual(engine.focused_window, os.focused);
    os.window_close(os.focused);
    os.settle();
    try testing.expect(engine.focused_window == b or engine.focused_window == c);
    try testing.expectEqual(engine.focused_window, os.focused);
    try testing.expect(os.window_find(a).?.minimized);
    try testing.expect(run(os, "focus {d}", .{a}).len > 0);
    try testing.expect(os.window_find(a).?.minimized);
}

// https://github.com/nikitabobko/AeroSpace/issues/1089
test "a window closed on a hidden workspace leaves focus and every frame alone" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    const sets = os.frames_set;
    os.window_close(b);
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, c);
}

// https://github.com/nikitabobko/AeroSpace/issues/1369
// https://github.com/nikitabobko/AeroSpace/issues/1306
test "a window closed while its workspace is switched leaves nothing behind" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    // The frame that hides the window races with the window going away.
    os.window_close(a);
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(engine.window_find(a) == null);
    try testing.expect(parked(b));
    os.command_run("workspace 1");
    os.window_close(b);
    os.settle();
    try testing.expect(engine.window_find(b) == null);
    try testing.expectEqual(tree.node_none, engine.workspaces[0].root);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
}

// https://github.com/nikitabobko/AeroSpace/issues/445
// https://github.com/nikitabobko/AeroSpace/issues/570
// https://github.com/nikitabobko/AeroSpace/issues/1257
// https://github.com/nikitabobko/AeroSpace/discussions/1979
test "an application that quits leaves no ghost tile, whatever it reported on the way" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    // The simulated macOS drops the destroyed notice of a dying application at random.
    for (0..4) |_| {
        const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
        const b = open(os, slack, .{});
        const c = open(os, slack, .{});
        const d = open(os, slack, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
        os.settle();
        try expect_partition(screen, &.{ a, b, c });
        os.app_quit(slack);
        os.settle();
        for ([_]WindowId{ b, c, d }) |id| try testing.expect(engine.window_find(id) == null);
        try expect_frame(screen, a);
        try testing.expectEqual(a, engine.focused_window);
        try testing.expectEqual(a, os.focused);
    }
}

// Popups, dialogs and floating windows.

// https://github.com/nikitabobko/AeroSpace/issues/53
// https://github.com/nikitabobko/AeroSpace/issues/1324
// https://github.com/nikitabobko/AeroSpace/issues/2170
test "a popup that takes focus and goes away moves no window and no focus" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, app, .{});
    os.settle();
    const sets = os.frames_set;
    const place = Rect.init(600, 400, 300, 200);
    const popup = open(os, app, .{ .kind = .popup, .frame = place });
    os.settle();
    try testing.expect(engine.window_find(popup) == null);
    try testing.expectEqual(terminal, engine.focused_window);
    try expect_frame(place, popup);
    os.window_close(popup);
    os.settle();
    try testing.expectEqual(terminal, engine.focused_window);
    try testing.expectEqual(terminal, os.focused);
    try testing.expectEqual(sets, os.frames_set);
}

// https://github.com/nikitabobko/AeroSpace/issues/89
// https://github.com/nikitabobko/AeroSpace/issues/323
// https://github.com/nikitabobko/AeroSpace/discussions/2040
test "a dialog floats where it opened, takes focus and gives it back" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const editor = open(os, zed, .{});
    os.settle();
    const place = Rect.init(500, 300, 400, 300);
    const dialog = open(os, zed, .{ .kind = .dialog, .frame = place });
    os.settle();
    try testing.expectEqual(Mode.floating, known(dialog).mode);
    try testing.expectEqual(@as(u32, 0), sets_of(dialog));
    try expect_frame(place, dialog);
    try expect_frame(left_half, terminal);
    try expect_frame(right_half, editor);
    try testing.expectEqual(dialog, engine.focused_window);
    os.window_close(dialog);
    os.settle();
    try testing.expectEqual(editor, engine.focused_window);
    try testing.expectEqual(editor, os.focused);
}

// https://github.com/nikitabobko/AeroSpace/discussions/2016
test "a window that floats by rule is never tiled first" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const calculator = os.app_launch("Calculator", "com.apple.calculator");
    const terminal = open(os, ghostty, .{});
    os.settle();
    const sets = sets_of(terminal);
    const place = Rect.init(700, 300, 300, 400);
    const keys = open(os, calculator, .{ .frame = place });
    os.settle();
    try testing.expectEqual(Mode.floating, known(keys).mode);
    try testing.expectEqual(@as(u32, 0), sets_of(keys));
    try testing.expectEqual(sets, sets_of(terminal));
    try expect_frame(place, keys);
    try expect_frame(screen, terminal);
    try testing.expectEqual(keys, engine.focused_window);
}

// https://github.com/nikitabobko/AeroSpace/issues/642
// https://github.com/nikitabobko/AeroSpace/issues/1519
// https://github.com/nikitabobko/AeroSpace/discussions/1875
// https://github.com/nikitabobko/AeroSpace/discussions/2028
// https://github.com/nikitabobko/AeroSpace/discussions/2320
test "a floating window comes back from a hidden workspace where the user left it" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const note = open(os, app, .{ .kind = .dialog, .frame = Rect.init(100, 100, 400, 300) });
    os.settle();
    const place = Rect.init(900, 500, 500, 350);
    os.window_drag(note, place);
    os.settle();
    try expect_frame(place, note);
    try testing.expectEqual(@as(u32, 0), sets_of(note));
    for (0..3) |_| {
        os.command_run("workspace 2");
        os.settle();
        try testing.expect(parked(note) and parked(a));
        os.command_run("workspace 1");
        os.settle();
        try expect_frame(place, note);
        try expect_frame(screen, a);
    }
    // One frame to hide it and one to bring it back, each time.
    try testing.expectEqual(@as(u32, 6), sets_of(note));
}

// https://github.com/nikitabobko/AeroSpace/issues/1987
test "a window floated while its frame is still on the way does not float in the corner" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a));
    // Two key presses in a row: the answer to the first frame has not arrived yet.
    os.command_run("workspace 1");
    os.command_run("toggle float");
    os.settle();
    try testing.expectEqual(Mode.floating, known(a).mode);
    try expect_frame(screen, a);
}

// https://github.com/nikitabobko/AeroSpace/issues/1987
test "a window floated while its application hangs does not float in the corner" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    os.app_hang(zed, 2000);
    os.command_run("workspace 1");
    os.advance(100);
    try testing.expect(parked(a)); // It has not answered yet.
    os.command_run("layout float");
    os.advance(5000);
    os.settle();
    try testing.expectEqual(Mode.floating, known(a).mode);
    try expect_frame(screen, a);
}

// https://github.com/nikitabobko/AeroSpace/issues/521
// https://github.com/nikitabobko/AeroSpace/issues/1311
test "focus moves between floating windows by direction" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const west = open(os, app, .{ .kind = .dialog, .frame = Rect.init(100, 200, 400, 300) });
    const east = open(os, app, .{ .kind = .dialog, .frame = Rect.init(1000, 200, 400, 300) });
    os.settle();
    try testing.expectEqual(east, engine.focused_window);
    os.command_run("focus west");
    try testing.expectEqual(west, engine.focused_window);
    os.command_run("focus west");
    try testing.expectEqual(west, engine.focused_window);
    os.command_run("focus east");
    try testing.expectEqual(east, engine.focused_window);
    os.settle();
    try testing.expectEqual(east, os.focused);
    try testing.expectEqual(@as(u32, 0), sets_of(west) + sets_of(east));
}

// https://github.com/nikitabobko/AeroSpace/issues/30
test "a floating window can be zoomed and returns to its place" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const place = Rect.init(300, 200, 500, 400);
    const note = open(os, app, .{ .kind = .dialog, .frame = place });
    os.settle();
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(screen, note);
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(place, note);
    try testing.expectEqual(Mode.floating, known(note).mode);
}

// https://github.com/nikitabobko/AeroSpace/issues/1547
// https://github.com/nikitabobko/AeroSpace/issues/121
test "a window that cannot be resized floats and keeps its size across workspaces" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const terminal = open(os, ghostty, .{});
    const place = Rect.init(400, 100, 400, 800);
    const phone = open(os, ios, .{ .resizable = false, .frame = place });
    os.settle();
    try testing.expectEqual(Mode.floating, known(phone).mode);
    try expect_frame(place, phone);
    try expect_frame(screen, terminal);
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(phone));
    try testing.expectEqual(place.w, frame_of(phone).w);
    try testing.expectEqual(place.h, frame_of(phone).h);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(place, phone);
}

// Zoom and native fullscreen.

// https://github.com/nikitabobko/AeroSpace/issues/35
// https://github.com/nikitabobko/AeroSpace/issues/211
test "a zoomed window is still zoomed after a workspace switch and back" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a) and parked(b));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(left_half, a);
}

// https://github.com/nikitabobko/AeroSpace/issues/233
// https://github.com/nikitabobko/AeroSpace/issues/857
// https://github.com/nikitabobko/AeroSpace/issues/1480
// https://github.com/nikitabobko/AeroSpace/issues/188
// https://github.com/nikitabobko/AeroSpace/issues/845
// https://github.com/nikitabobko/AeroSpace/issues/562
// https://github.com/nikitabobko/AeroSpace/discussions/984
test "a window in native fullscreen is left alone and returns to the place it left" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    const sets = sets_of(a);
    fullscreen_set(os, a, true);
    os.settle();
    try expect_partition(screen, &.{ b, c });
    try testing.expectEqual(sets, sets_of(a));
    os.command_run("focus west");
    os.command_run("focus next --wrap");
    os.command_run("workspace 2");
    os.command_run("workspace 1");
    os.settle();
    try testing.expect(engine.focused_window == b or engine.focused_window == c);
    try testing.expectEqual(sets, sets_of(a));
    try expect_frame(left_half, a); // Nobody touched it.
    // Leaving fullscreen, as after a video, puts every window back where it was.
    fullscreen_set(os, a, false);
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
}

// Native tabs.

// https://github.com/nikitabobko/AeroSpace/issues/340
// https://github.com/nikitabobko/AeroSpace/issues/1771
test "a tab dragged out of a tiled window becomes a tile of its own" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const editor = open(os, zed, .{});
    os.settle();
    os.window_click(terminal);
    os.settle();
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    try expect_partition(screen, &.{ tab, editor });
    os.tab_detach(tab);
    os.settle();
    try testing.expectEqual(Mode.tiled, known(tab).mode);
    try testing.expectEqual(Mode.tiled, known(terminal).mode);
    try testing.expectEqual(@as(WindowId, 0), known(tab).tab_of);
    try testing.expectEqual(@as(WindowId, 0), known(terminal).tab_of);
    try expect_partition(screen, &.{ terminal, tab, editor });
}

// https://github.com/nikitabobko/AeroSpace/issues/340
// https://github.com/nikitabobko/AeroSpace/issues/345
test "a tab dragged out of a floating window floats where it is dropped" {
    // The default configuration floats Finder.
    const os = boot("");
    const finder = os.app_launch("Finder", "com.apple.finder");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    const place = Rect.init(200, 200, 800, 600);
    const folder = open(os, finder, .{ .frame = place });
    os.settle();
    try testing.expectEqual(Mode.floating, known(folder).mode);
    const tab = open(os, finder, .{ .tab_of = folder });
    os.settle();
    try expect_frame(place, tab);
    os.tab_detach(tab);
    const dropped = frame_of(tab);
    os.settle();
    try testing.expectEqual(Mode.floating, known(tab).mode);
    try testing.expectEqual(Mode.floating, known(folder).mode);
    try expect_frame(dropped, tab);
    try expect_frame(place, folder);
    try expect_frame(screen, editor);
}

// https://github.com/nikitabobko/AeroSpace/issues/68
// https://github.com/nikitabobko/AeroSpace/issues/277
test "a window with tabs moves between workspaces as one window" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    const terminal = open(os, ghostty, .{});
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    try testing.expectEqual(tab, engine.focused_window);
    os.command_run("send 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(tab).workspace);
    try testing.expectEqual(@as(u8, 1), known(terminal).workspace);
    try testing.expect(parked(tab) and parked(terminal));
    try expect_frame(screen, editor);
    try testing.expectEqual(editor, engine.focused_window);
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, tab);
    try expect_frame(screen, terminal);
    try testing.expectEqual(tab, engine.focused_window);
}

// Frames: nothing moves that does not have to.

// https://github.com/nikitabobko/AeroSpace/issues/545
// https://github.com/nikitabobko/AeroSpace/issues/1287
// https://github.com/nikitabobko/AeroSpace/issues/751
test "windows on hidden workspaces are sent nothing while the visible one changes" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, app, .{});
    const d = open(os, app, .{});
    const e = open(os, app, .{});
    os.settle();
    const sets = [2]u32{ sets_of(a), sets_of(b) };
    const churn = [_][]const u8{
        "swap west",     "warp south",             "resize right 40", "rotate 90",
        "balance",       "toggle zoom-fullscreen", "focus prev",      "toggle float",
        "mirror x-axis", "retile",                 "toggle gaps",     "toggle gaps",
    };
    for (churn) |text| {
        os.command_run(text);
        os.settle();
    }
    os.window_close(e);
    os.settle();
    try testing.expectEqual(sets[0], sets_of(a));
    try testing.expectEqual(sets[1], sets_of(b));
    try testing.expect(parked(a) and parked(b));
    try testing.expect(!parked(c) and !parked(d));
}

// https://github.com/nikitabobko/AeroSpace/discussions/2155
// https://github.com/nikitabobko/AeroSpace/discussions/2063
// https://github.com/nikitabobko/AeroSpace/issues/527
// https://github.com/nikitabobko/AeroSpace/discussions/1234
test "a hidden window that will not stay parked is left alone after a few tries" {
    const os = boot("rule app=\"Simulator\" : workspace 5\n");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const terminal = open(os, ghostty, .{});
    os.settle();
    const home = Rect.init(300, 200, 500, 400);
    const pet = open(os, ios, .{ .stubborn = true, .frame = home, .focus = false });
    os.settle(); // Would never return if the engine kept parking it.
    try testing.expect(known(pet).frozen);
    try testing.expect(sets_of(pet) <= engine_module.drift_max + 1);
    try testing.expectEqual(Mode.tiled, known(pet).mode);
    try expect_frame(home, pet);
    try expect_frame(screen, terminal);
    try testing.expectEqual(terminal, engine.focused_window);
    // Nothing more is sent however long it sits there.
    const sets = os.frames_set;
    os.advance(60_000);
    os.settle();
    try testing.expectEqual(sets, os.frames_set);
}

// https://github.com/nikitabobko/AeroSpace/discussions/2297
// https://github.com/nikitabobko/AeroSpace/discussions/2373
test "workspace switches in quick succession end on the last one asked for" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 3");
    const c = open(os, app, .{});
    os.settle();
    // No time passes between the key presses: no echo of any focus request arrives.
    os.command_run("workspace 1");
    os.command_run("workspace 2");
    os.command_run("workspace 3");
    os.command_run("workspace 1");
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_frame(screen, b);
    try testing.expect(parked(a) and parked(c));
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(b, os.focused);
}

// https://github.com/nikitabobko/AeroSpace/discussions/2297
// https://github.com/nikitabobko/AeroSpace/issues/289
// https://github.com/nikitabobko/AeroSpace/discussions/1375
test "leaving for an empty workspace before the focus echo arrives does not bounce back" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    // Workspace 1 asks macOS to focus its window; the answer arrives after the user has
    // already moved on to an empty workspace.
    os.command_run("workspace 1");
    os.command_run("workspace 3");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expect(parked(a) and parked(b));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    // Really going to the window still shows its workspace.
    os.advance(1000);
    os.window_click(b);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_frame(screen, b);
}

// https://github.com/nikitabobko/AeroSpace/issues/613
// https://github.com/nikitabobko/AeroSpace/issues/576
test "leaving for an empty monitor before the focus echo arrives does not bounce back" {
    const os = boot("");
    os.monitors_set(3); // Three displays in a row, the laptop in the middle.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 3");
    const b = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus-monitor 3");
    os.command_run("focus-monitor 1");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    // A window opened now lands on the empty monitor that is in use.
    const c = open(os, app, .{});
    os.settle();
    try testing.expectEqual(engine.monitors[0].workspace, known(c).workspace);
    try testing.expectEqual(c, engine.focused_window);
    try testing.expect(known(b).workspace != known(c).workspace);
}

// https://github.com/nikitabobko/AeroSpace/issues/317
test "a query moves nothing and focuses nothing" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    const queries = [_][]const u8{
        "query windows",  "query windows --json", "query workspaces", "query monitors",
        "query focus",    "query tree --json",    "query window",     "query stats",
        "query bindings", "query modes",          "query commands",
    };
    for (queries) |text| {
        os.command_run(text);
        try testing.expect(engine.reply().len > 0);
        try testing.expectEqual(@as(u32, 0), engine.effects_count);
        try testing.expectEqual(@as(usize, 0), engine.notes_slice().len);
    }
    try testing.expectEqual(b, engine.focused_window);
    try expect_partition(screen, &.{ a, b });
}

// https://github.com/nikitabobko/AeroSpace/issues/440
// https://github.com/nikitabobko/AeroSpace/issues/1576
test "a window with no title or a very long one still answers queries" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const blank = open(os, app, .{ .title = "" });
    // Longer than the engine keeps, and cut in the middle of a character.
    const long = "x" ++ "日本日本日本日本日本日本日本日本日本日本日本日本日本日本日本日本";
    const wide = open(os, app, .{ .title = long });
    os.settle();
    try testing.expectEqual(@as(u8, 0), known(blank).title_len);
    const json = run(os, "query windows --json", .{});
    try testing.expect(std.unicode.utf8ValidateSlice(json));
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"\"") != null);
    try testing.expect(std.unicode.utf8ValidateSlice(run(os, "query window {d} --json", .{wide})));
    try testing.expect(std.unicode.utf8ValidateSlice(run(os, "query tree --json", .{})));
    try expect_partition(screen, &.{ blank, wide });
}

// The mouse.

// https://github.com/nikitabobko/AeroSpace/issues/1265
// https://github.com/nikitabobko/AeroSpace/issues/411
test "a tile dropped on its own place snaps back and an edge stops at its limit" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_drag(a, Rect.init(100, 200, 864, 1079));
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    // Drag the shared edge almost to the right end of the screen.
    os.window_drag(a, Rect.init(0, 38, 1700, 1079));
    os.settle();
    try expect_partition(screen, &.{ a, b });
    try testing.expect(frame_of(b).w * 10 >= screen.w - 10);
    try testing.expectEqual(screen.h, frame_of(b).h);
}

// Minimize.

// https://github.com/nikitabobko/AeroSpace/issues/18
// https://github.com/nikitabobko/AeroSpace/issues/36
// https://github.com/nikitabobko/AeroSpace/issues/1500
test "a minimized window gives up its tile and returns to the place it left" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    os.window_minimize(b, true);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
    const sets = sets_of(b);
    os.command_run("workspace 2");
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(sets, sets_of(b)); // A minimized window is never moved.
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
    try testing.expectEqual(b, engine.focused_window);
    // A window that sat beside a whole group returns beside it, with the share it had.
    os.window_click(a);
    os.settle();
    os.command_run("resize right 100");
    os.settle();
    const resized = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    try testing.expectEqual(left_half.w + 100, resized[0].w);
    os.window_minimize(a, true);
    os.settle();
    try expect_partition(screen, &.{ b, c });
    os.window_minimize(a, false);
    os.settle();
    try expect_frame(resized[0], a);
    try expect_frame(resized[1], b);
    try expect_frame(resized[2], c);
}

// https://github.com/nikitabobko/AeroSpace/issues/18
test "a minimized window whose neighbour is gone tiles like a new window" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    try expect_frame(screen, a);
    os.window_close(a);
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(screen, c);
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(left_half, c);
    try expect_frame(right_half, b);
}

// Applications that do not answer.

// https://github.com/nikitabobko/AeroSpace/issues/391
// https://github.com/nikitabobko/AeroSpace/issues/131
test "focus asked of an application that hangs falls back to where focus really is" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const b = open(os, slack, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    os.app_hang(slack, 2000);
    os.command_run("focus east");
    try testing.expectEqual(b, engine.focused_window); // Optimistic.
    os.advance(engine_module.focus_pending_ms + 100);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    // The next key press works at once; nothing waited for the application.
    os.command_run("toggle zoom-fullscreen");
    os.advance(1);
    try expect_frame(screen, a);
    os.advance(5000);
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
}

// Displays.

// https://github.com/nikitabobko/AeroSpace/issues/1302
// https://github.com/nikitabobko/AeroSpace/issues/912
test "an empty workspace opens on the monitor in use and a shown one takes focus there" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    os.command_run("workspace 5");
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(external, b);
    try expect_frame(screen, a);
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    try expect_frame(external, b);
}

// https://github.com/nikitabobko/AeroSpace/issues/283
// https://github.com/nikitabobko/AeroSpace/issues/196
// https://github.com/nikitabobko/AeroSpace/issues/142
test "send-monitor moves the window and leaves focus behind unless told to follow" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("send-monitor 2");
    os.settle();
    try expect_frame(external, b);
    try expect_frame(screen, a);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    // The window that was thrown over can be reached and brought back.
    os.command_run("focus east");
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(b, os.focused);
    os.command_run("send-monitor 1 --follow");
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try expect_partition(screen, &.{ a, b });
}

// https://github.com/nikitabobko/AeroSpace/issues/691
// https://github.com/nikitabobko/AeroSpace/issues/94
test "workspace next and prev stay on the monitor in use" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 4");
    const c = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    // Workspace 2 has a window, but it belongs to the other display.
    os.command_run("workspace next");
    os.command_run("workspace prev");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try testing.expectEqual(@as(u8, 3), engine.monitors[1].workspace);
    try expect_frame(external, c);
    try testing.expect(sliver_only(b));
    // On the other display the two of its workspaces that have windows take turns.
    os.command_run("focus-monitor 2");
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    os.command_run("workspace next");
    os.settle();
    try testing.expectEqual(c, engine.focused_window);
    try expect_frame(screen, a);
}

// https://github.com/nikitabobko/AeroSpace/issues/116
// https://github.com/nikitabobko/AeroSpace/issues/347
test "a floating window dragged to another monitor stays there and takes focus along" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const note = open(os, app, .{ .kind = .dialog, .frame = Rect.init(100, 100, 400, 300) });
    os.settle();
    const place = Rect.init(2400, 500, 400, 300);
    os.window_drag(note, place);
    os.settle();
    try expect_frame(place, note);
    try testing.expectEqual(engine.monitors[1].workspace, known(note).workspace);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(note, engine.focused_window);
    try testing.expectEqual(@as(u32, 0), sets_of(note));
    try expect_frame(screen, a);
}

// https://github.com/nikitabobko/AeroSpace/issues/116
// https://github.com/nikitabobko/AeroSpace/issues/1357
test "a tile dragged onto a monitor with no tiles moves there" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(right_half, b);
    os.window_drag(b, Rect.init(2500, 300, 864, 1079));
    os.settle();
    try testing.expectEqual(engine.monitors[1].workspace, known(b).workspace);
    try testing.expectEqual(Mode.tiled, known(b).mode);
    try expect_frame(external, b);
    try expect_frame(screen, a);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
}

// https://github.com/nikitabobko/AeroSpace/discussions/2102
// https://github.com/nikitabobko/AeroSpace/discussions/2065
// https://github.com/nikitabobko/AeroSpace/issues/413
// https://github.com/nikitabobko/AeroSpace/issues/171
test "hidden windows show at most a sliver on every display, side by side or stacked" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    // Three displays in a row, the laptop in the middle; then one above the other.
    for ([_]u32{ 3, 4 }) |preset| {
        os.monitors_set(preset);
        os.settle();
        const a = open(os, app, .{});
        os.settle();
        os.command_run("focus-monitor 1");
        const b = open(os, app, .{});
        os.settle();
        try testing.expect(known(a).workspace != known(b).workspace);
        os.command_run("workspace new");
        os.command_run("focus-monitor 2");
        os.command_run("workspace new");
        os.settle();
        try testing.expect(!engine.workspace_visible(known(a).workspace));
        try testing.expect(!engine.workspace_visible(known(b).workspace));
        try testing.expect(sliver_only(a));
        try testing.expect(sliver_only(b));
        os.window_close(a);
        os.window_close(b);
        os.settle();
    }
}

// https://github.com/nikitabobko/AeroSpace/issues/506
// https://github.com/nikitabobko/AeroSpace/discussions/2197
// https://github.com/nikitabobko/AeroSpace/discussions/2262
// https://github.com/nikitabobko/AeroSpace/issues/651
// https://github.com/nikitabobko/AeroSpace/issues/404
test "displays coming and going in any order lose no window and no workspace" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 4");
    const c = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    const homes = [3]u8{ known(a).workspace, known(b).workspace, known(c).workspace };
    for ([_]u32{ 0, 3, 2, 4, 0, 1, 2, 3, 0, 1 }) |preset| {
        os.monitors_set(preset);
        os.settle();
        try testing.expectEqual(homes[0], known(a).workspace);
        try testing.expectEqual(homes[1], known(b).workspace);
        try testing.expectEqual(homes[2], known(c).workspace);
        try testing.expectEqual(a, engine.focused_window);
        for ([_]WindowId{ a, b, c }) |id| {
            try testing.expect(engine.workspace_visible(known(id).workspace) != sliver_only(id));
        }
    }
    try expect_frame(screen, a);
    try testing.expectEqual(@as(u8, 3), engine.monitors[1].workspace);
    try expect_frame(external, c);
    try testing.expect(sliver_only(b));
    // Every workspace can still be reached.
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(external, b);
    try testing.expectEqual(b, engine.focused_window);
}

// https://github.com/nikitabobko/AeroSpace/issues/2173
test "a display that is plugged back in shows the workspace it showed before" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 4");
    const c = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, a);
    try testing.expect(parked(b) and parked(c));
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 3), engine.monitors[1].workspace);
    try expect_frame(external, c);
    try testing.expect(sliver_only(b));
    try expect_frame(screen, a);
}

// Sleep and wake.

// https://github.com/nikitabobko/AeroSpace/discussions/1469
// https://github.com/nikitabobko/AeroSpace/discussions/1182
// https://github.com/nikitabobko/AeroSpace/discussions/2264
// https://github.com/nikitabobko/AeroSpace/discussions/2318
test "every display shows the same workspace after sleep as before" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 4");
    const c = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    const sets = os.frames_set;
    try displays_sleep(os);
    os.advance(60_000);
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.monitors[0].workspace);
    try testing.expectEqual(@as(u8, 3), engine.monitors[1].workspace);
    try expect_frame(screen, a);
    try expect_frame(external, c);
    try testing.expect(sliver_only(b));
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(sets, os.frames_set); // Nothing had to move.
}

// https://github.com/nikitabobko/AeroSpace/discussions/2264
// https://github.com/nikitabobko/AeroSpace/discussions/1469
test "an empty workspace is still the one in use after sleep" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 3");
    os.settle();
    try displays_sleep(os);
    os.advance(60_000);
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expect(parked(a));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
}

// https://github.com/nikitabobko/AeroSpace/issues/1216
// https://github.com/nikitabobko/AeroSpace/discussions/2264
test "a window that opens while the displays sleep joins the workspace that was in use" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    try displays_sleep(os);
    const c = open(os, app, .{});
    os.advance(1000);
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(c).workspace);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_partition(screen, &.{ b, c });
    try testing.expect(parked(a));
}

// https://github.com/nikitabobko/AeroSpace/issues/164
// https://github.com/nikitabobko/AeroSpace/issues/890
test "commands while every display sleeps do nothing, and queries still answer" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try displays_sleep(os);
    const asleep = [_][]const u8{
        "focus west", "swap west",       "warp south",      "workspace 2",
        "send 3",     "toggle float",    "retile",          "balance",
        "close",      "focus-monitor 2", "send-monitor 2",  "workspace next",
        "zoom --on",  "close-others",    "resize right 20", "layout float",
    };
    for (asleep) |text| {
        os.command_run(text);
        try testing.expectEqual(@as(u32, 0), engine.effects_count);
    }
    try testing.expect(run(os, "query windows", .{}).len > 0);
    try testing.expect(run(os, "query workspaces --json", .{}).len > 0);
    os.monitors_set(0);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(b, engine.focused_window);
}
