//! Scenario tests: one for each AeroSpace failure this window manager exists to not have.
//! They run the real engine against the simulated OS with random faults switched off, so
//! every expectation is exact.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);

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
fn open(os: *sim.Simulator, app: i32, options: sim.Simulator.WindowOptions) engine_module.WindowId {
    const id = os.window_open(app, options);
    os.advance(1);
    return id;
}

fn frame_of(id: engine_module.WindowId) Rect {
    return simulator.window_find(id).?.frame;
}

fn expect_frame(expected: Rect, id: engine_module.WindowId) !void {
    const actual = frame_of(id);
    if (!actual.eql(expected)) {
        std.debug.print("window {d}: expected {any}, found {any}\n", .{ id, expected, actual });
        return error.TestUnexpectedResult;
    }
}

fn parked(id: engine_module.WindowId) bool {
    const frame = frame_of(id);
    return frame.overlap(Rect.init(0, 0, 1728, 1117), .x) <= 1;
}

test "new windows tile like yabai bsp and focus moves with cmd-hjkl" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app, .{});
    os.settle();
    try expect_frame(screen, a);
    const b = open(os, app, .{});
    os.settle();
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus north");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    // Focus is optimistic: two presses in a row do not wait for the OS in between.
    os.command_run("focus east");
    os.command_run("focus south");
    try testing.expectEqual(c, engine.focused_window);
    os.settle();
    try testing.expectEqual(c, os.focused);
}

test "a window that fights the layout is floated after a bounded number of tries" {
    // AeroSpace: 'my granola is flashing all the time'.
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const calm = open(os, app, .{});
    const home = Rect.init(300, 200, 500, 400);
    const stubborn = open(os, app, .{ .stubborn = true, .frame = home });
    os.settle(); // Would never return if the fight went on forever.
    const known = engine.window_find(stubborn).?;
    try testing.expect(known.auto_floated);
    try testing.expectEqual(engine_module.Mode.floating, known.mode);
    try testing.expect(known.sets_total <= engine_module.drift_max + 1);
    try expect_frame(home, stubborn);
    try expect_frame(screen, calm);
    try testing.expectEqual(@as(u64, 1), engine.stats.windows_auto_floated);
}

test "a window with a minimum size is asked a bounded number of times" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const wide = open(os, app, .{ .min_w = 1200 });
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 1200, 1079), wide);
    const known = engine.window_find(wide).?;
    try testing.expect(known.sets_total <= 1 + engine_module.attempts_max);
}

test "a title that arrives late still matches its rule, a later title change does not" {
    // AeroSpace needed a polling shell script to float the Tempo Wallet popup in Brave.
    const os = boot("");
    const brave = os.app_launch("Brave Browser", "com.brave.Browser");
    const browser = open(os, brave, .{ .title = "Inbox" });
    const wallet = open(os, brave, .{ .title = "Untitled", .late_title = true });
    os.advance(100);
    try testing.expectEqual(engine_module.Mode.tiled, engine.window_find(wallet).?.mode);
    os.advance(1000);
    try testing.expectEqual(engine_module.Mode.floating, engine.window_find(wallet).?.mode);
    os.settle();
    try expect_frame(screen, browser);
    // Navigating a tiled browser window to the wallet later must not float the browser.
    os.advance(10_000);
    os.window_title(browser, "Tempo Wallet");
    os.settle();
    try testing.expectEqual(engine_module.Mode.tiled, engine.window_find(browser).?.mode);
}

test "a native tab shares the tile of its window" {
    // AeroSpace: 'a second ghostty tab will be treated as a new window'.
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const editor = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, terminal);
    try expect_frame(right_half, editor);
    os.window_click(terminal);
    os.settle();
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    try expect_frame(left_half, tab);
    try expect_frame(right_half, editor);
    try testing.expectEqual(tab, engine.focused_window);
    try testing.expectEqual(tab, engine.window_find(terminal).?.tab_of);
    os.window_close(tab);
    os.settle();
    try expect_frame(left_half, terminal);
    try expect_frame(right_half, editor);
    try testing.expectEqual(terminal, engine.focused_window);
}

test "popups and helper windows are never tiled" {
    // AeroSpace: 'a chrome window that is fucking up my tiling'.
    const os = boot("");
    const chrome = os.app_launch("Google Chrome", "com.google.Chrome");
    const browser = open(os, chrome, .{});
    const popup = open(os, chrome, .{ .kind = .popup, .frame = Rect.init(50, 50, 300, 20) });
    const dialog = open(os, chrome, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
    os.settle();
    try expect_frame(screen, browser);
    try expect_frame(Rect.init(50, 50, 300, 20), popup);
    try expect_frame(Rect.init(500, 300, 400, 300), dialog);
    try testing.expect(engine.window_find(popup) == null);
    try testing.expectEqual(engine_module.Mode.floating, engine.window_find(dialog).?.mode);
}

test "a zoomed window stays zoomed when another window takes focus" {
    // Asked for: 'my window stayed in full screen and the window I alt tabbed towards just
    // came as a temporary overlay'.
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(screen, a);
    os.window_click(b);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("toggle zoom-fullscreen");
    os.command_run("focus west");
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(left_half, a);
}

test "a hung application delays only its own windows" {
    // AeroSpace: 'restart aerospace it is very slow', and a CLI that hangs with it.
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const b = open(os, slack, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    os.app_hang(slack, 2000);
    os.command_run("focus west");
    os.command_run("swap east");
    os.advance(1);
    try expect_frame(right_half, a); // Moved at once.
    try expect_frame(right_half, b); // Still where it was; nobody waited for it.
    try testing.expect(engine.stats.apps_suspended >= 1);
    os.advance(3000);
    try expect_frame(left_half, b); // Caught up once it answered again.
}

test "workspaces switch with one frame per window and come back exactly" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    var sets = os.frames_set;
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(@as(u64, 3), os.frames_set - sets);
    try testing.expect(parked(a) and parked(b) and parked(c));
    try testing.expectEqual(@as(engine_module.WindowId, 0), engine.focused_window);
    const d = open(os, app, .{});
    os.settle();
    try expect_frame(screen, d);
    sets = os.frames_set;
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(@as(u64, 4), os.frames_set - sets);
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
    try testing.expect(parked(d));
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(c, os.focused);
    // Send the focused window away and follow it.
    os.command_run("send 2 --follow");
    os.settle();
    try testing.expectEqual(c, engine.focused_window);
    try testing.expect(parked(a) and parked(b));
    try testing.expect(!parked(c) and !parked(d));
}

test "a sticky window stays on screen across workspaces" {
    // AeroSpace has no sticky windows (its pull request 2083 was tried and reverted).
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const note = open(os, app, .{ .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    os.command_run("toggle sticky");
    os.settle();
    try expect_frame(screen, a);
    const place = frame_of(note);
    os.command_run("workspace 3");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(place, note);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(place, note);
}

test "a window sent away by a rule does not pull focus or the workspace with it" {
    // Asked for: 'in all your tests the window kept popping up in front of my face'.
    const os = boot("rule app=\"Simulator\" : workspace 9\n");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, ghostty, .{});
    os.settle();
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const phone = open(os, ios, .{ .frame = Rect.init(400, 100, 400, 800) });
    os.settle();
    try testing.expect(parked(phone));
    try expect_frame(screen, terminal);
    try testing.expectEqual(terminal, engine.focused_window);
    try testing.expectEqual(terminal, os.focused);
    try testing.expectEqual(@as(u8, 8), engine.window_find(phone).?.workspace);
    // Going there on purpose still works.
    os.command_run("workspace 9");
    os.settle();
    try testing.expect(!parked(phone));
    try testing.expectEqual(phone, engine.focused_window);
}

test "windows that were already open stay on the monitor they are on" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const external = Rect.init(1728, 38, 2560, 1402);
    const there = open(os, app, .{ .frame = Rect.init(2000, 200, 900, 700), .adopted = true });
    os.settle();
    try expect_frame(external, there);
    // A window opened from now on joins the workspace in use, wherever the app drew it.
    os.command_run("focus-monitor 1");
    os.settle();
    const here = open(os, app, .{ .frame = Rect.init(2100, 300, 900, 700) });
    os.settle();
    try expect_frame(screen, here);
    try expect_frame(external, there);
}

test "workspaces return to a monitor that is unplugged and plugged back in" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    const external = Rect.init(1728, 38, 2560, 1402);
    try expect_frame(screen, a);
    try expect_frame(external, b);
    os.monitors_set(0);
    os.settle();
    // The window in use stays in view on the remaining screen; the other waits.
    try expect_frame(screen, b);
    try testing.expect(parked(a));
    os.monitors_set(1);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
}

test "the mouse can swap and resize tiles" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    // Drop the left window onto the right one.
    os.window_drag(a, Rect.init(900, 100, 864, 1079));
    os.settle();
    try expect_frame(right_half, a);
    try expect_frame(left_half, b);
    // Drag the shared edge 100 pixels to the right.
    os.window_drag(b, Rect.init(0, 38, 964, 1079));
    os.settle();
    try expect_frame(Rect.init(0, 38, 964, 1079), b);
    try expect_frame(Rect.init(964, 38, 764, 1079), a);
}

test "quitting brings every parked window back on screen" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a));
    os.command_run("quit");
    os.advance(1000);
    try testing.expect(!parked(a));
    // A stopped engine does nothing more, whatever still arrives.
    os.command_run("workspace 1");
    try testing.expectEqual(@as(u32, 0), engine.effects_count);
}
