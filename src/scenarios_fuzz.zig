//! Scenario tests for what the simulator's random workload found once it played native
//! fullscreen, hidden applications, displays that sleep, change and come back, and
//! notifications that arrive late, twice or about windows that are gone. As in
//! scenarios.zig the real engine runs against the simulated OS with random faults switched
//! off, so every expectation is exact.
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
const Mode = engine_module.Mode;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const laptop = Rect.init(0, 0, 1728, 1117);
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
    return frame_of(id).overlap(laptop, .x) <= 1;
}

fn sets_of(id: WindowId) u32 {
    return engine.window_find(id).?.sets_total;
}

// Displays that sleep.

test "a window minimized while every display sleeps is left alone" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.displays_sleep();
    // The window moves, and before the manager gets to put it back it is minimized.
    os.window_drag(b, Rect.init(300, 300, 500, 400));
    os.advance(1);
    os.window_minimize(b, true);
    const sets = sets_of(b);
    os.settle();
    try testing.expectEqual(sets, sets_of(b));
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, a);
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

test "windows reported in one go while every display sleeps leave no timer spinning" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.displays_sleep();
    // A frame falls due while the windows are being reported, and is held back.
    os.window_drag(a, Rect.init(300, 300, 500, 400));
    os.advance(1);
    os.adoption(.begin);
    os.advance(engine_module.settle_ms);
    os.adoption(.end);
    // Whatever is due is due at a time, not for ever.
    if (engine.next_deadline_ms()) |deadline| try testing.expect(deadline > os.now_ms);
    os.settle();
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, a);
}

// Native fullscreen.

test "a floating window that leaves native fullscreen is back where it floated" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("toggle float");
    const place = Rect.init(200, 100, 600, 400);
    os.window_drag(b, place);
    os.settle();
    try expect_frame(place, b);
    // The window fills the display before the manager is told that it is fullscreen.
    os.window_fullscreen(b, true, .{ .notice_ms = 30 });
    os.settle();
    try expect_frame(laptop, b);
    try expect_frame(screen, a);
    // And it is back at its frame before the manager is told that it no longer is.
    os.window_fullscreen(b, false, .{ .notice_ms = 30 });
    os.settle();
    try expect_frame(place, b);
    try expect_frame(screen, a);
    try testing.expectEqual(Mode.floating, engine.window_find(b).?.mode);
}

test "a floating window that leaves native fullscreen while hidden comes back at its size" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("toggle float");
    const place = Rect.init(200, 100, 600, 400);
    os.window_drag(b, place);
    os.settle();
    os.window_fullscreen(b, true, .{ .notice_ms = 30 });
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a));
    // The video ends by itself. This time the manager is told first, and the frame
    // follows when the animation is over.
    os.window_fullscreen(b, false, .{ .frame_ms = 300 });
    os.settle();
    try testing.expect(parked(b));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(place, b);
    try expect_frame(screen, a);
}

// Displays that change.

test "a display that comes back under another id keeps its workspaces" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    os.monitors_set(1);
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("send-monitor 2 --follow");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    // The external display reconnects, and macOS knows it by another number.
    os.display_renumber(1, 5);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try testing.expectEqual(b, engine.focused_window);
    // The same over a night's sleep.
    os.displays_sleep();
    os.display_renumber(1, 6);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    // A display that is unplugged is another matter: its windows wait on the laptop.
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, b);
    try testing.expect(parked(a));
}

// Windows that leave the layout for a while.

test "hiding an application and showing it again puts every tile back where it was" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, ghostty, .{});
    const d = open(os, zed, .{});
    os.settle();
    const frames = [4]Rect{ frame_of(a), frame_of(b), frame_of(c), frame_of(d) };
    try expect_frame(left_half, a);
    // cmd-h: the shell reports every window of the application as minimized.
    os.app_hide(zed);
    os.settle();
    try expect_frame(screen, c);
    os.app_show(zed);
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
    try expect_frame(frames[3], d);
}

test "windows minimized one after the other return to their places in any order" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    os.window_minimize(a, true);
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    try expect_frame(screen, c);
    // The first to leave is the first to return.
    os.window_minimize(a, false);
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(right_half, c);
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
}
