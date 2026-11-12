//! Scenario tests from the bug trackers of other window managers that drive macOS through
//! the Accessibility API: Amethyst, Rectangle, Hammerspoon, and komorebi for layout and
//! focus logic. Each test is something an application or a display did to one of them,
//! and what tatami does instead. They run the real engine against the simulated OS with
//! random faults switched off, so every expectation is exact.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const command_module = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const Event = engine_module.Event;
const WindowId = engine_module.WindowId;
const MonitorInfo = engine_module.MonitorInfo;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);
const right_top = Rect.init(864, 38, 864, 540);
const right_bottom = Rect.init(864, 578, 864, 539);
// The external display of the simulator's second arrangement, right of the laptop.
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
    frames_delivered = 0;
    cells = .{};
    // The engine asks where focus is as soon as it has displays. Answer before anything
    // opens: otherwise the simulator reports the first window ahead of its application,
    // and rules that go by the application's name would not see it.
    simulator.settle();
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

/// True when at most a one pixel sliver of the window shows on any monitor.
fn parked(id: WindowId) bool {
    const frame = frame_of(id);
    for (simulator.monitors) |*info| {
        if (frame.overlap(info.frame, .x) > 1 and frame.overlap(info.frame, .y) > 1) return false;
    }
    return true;
}

fn mode_of(id: WindowId) engine_module.Mode {
    return engine.window_find(id).?.mode;
}

fn workspace_of(id: WindowId) u8 {
    return engine.window_find(id).?.workspace;
}

/// Runs a command built from a format string and returns what the engine answered.
fn run(os: *sim.Simulator, comptime format: []const u8, args: anytype) []const u8 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    os.command_run(text);
    return engine.reply();
}

// What the simulator has no call for: native fullscreen, a display that changes its
// resolution or goes to sleep, an application that moves its own window once. The helpers
// below hand such an event to the engine the way the shell does, and perform the frames
// and the focus it asks for, for windows that do as they are told above their minimum.

const followups_max: u32 = 2048;
var followups: [followups_max]Event = undefined;
/// Frames performed by deliver, which the simulator does not get to count.
var frames_delivered: u64 = 0;
/// A window that rounds every size it is given down to whole cells, as terminals do.
var cells: struct { id: WindowId = 0, w: i32 = 1, h: i32 = 1 } = .{};

/// Every frame the engine has asked for since boot.
fn frames_sent(os: *const sim.Simulator) u64 {
    return os.frames_set + frames_delivered;
}

fn deliver(os: *sim.Simulator, event: Event) void {
    var head: u32 = 0;
    var count: u32 = 1;
    followups[0] = event;
    while (head < count) : (head += 1) {
        const effects = engine.step(followups[head], os.now_ms);
        for (effects) |effect| {
            switch (effect) {
                .set_frame => |set| {
                    const window = os.window_find(set.id) orelse continue;
                    var frame = Rect.init(
                        set.frame.x,
                        set.frame.y,
                        @max(set.frame.w, window.min_w),
                        @max(set.frame.h, window.min_h),
                    );
                    if (set.id == cells.id) {
                        frame.w -= @mod(frame.w, cells.w);
                        frame.h -= @mod(frame.h, cells.h);
                    }
                    window.frame = frame;
                    frames_delivered += 1;
                    std.debug.assert(window.tab_group == 0 and window.title_bar == 0);
                    std.debug.assert(count < followups_max);
                    followups[count] = .{
                        .window_frame_applied = .{ .id = set.id, .frame = frame },
                    };
                    count += 1;
                },
                .focus_window => |focus| os.window_click(focus.id),
                .close_window => |close| os.window_close(close.id),
                .query_focus => {
                    std.debug.assert(count < followups_max);
                    followups[count] = .{ .focus_reported = os.focused };
                    count += 1;
                },
                .warp_mouse, .exec, .reload, .quit => {},
            }
        }
        engine.verify();
    }
}

/// The displays change to a list the simulator has no preset for. An empty list is every
/// display asleep.
fn monitors_deliver(os: *sim.Simulator, list: []const MonitorInfo) void {
    if (list.len > 0) os.monitors = list;
    deliver(os, .{ .monitors_changed = list });
}

/// A command whose frames are performed by deliver rather than by the simulator.
fn command_deliver(os: *sim.Simulator, text: []const u8) void {
    var pool: command_module.StringPool = .{};
    deliver(os, .{ .command = command_module.parse(text, &pool) catch unreachable });
}

/// The application, or macOS, moves a window without anyone holding a mouse button.
fn app_moves(os: *sim.Simulator, id: WindowId, frame: Rect) void {
    os.window_find(id).?.frame = frame;
    deliver(os, .{ .window_frame_changed = .{ .id = id, .frame = frame, .by_user = false } });
}

fn display(id: u32, frame: Rect, visible: Rect, main: bool) MonitorInfo {
    return .{ .display = id, .frame = frame, .visible = visible, .main = main };
}

const laptop_frame = Rect.init(0, 0, 1728, 1117);
const laptop = [_]MonitorInfo{display(1, laptop_frame, screen, true)};
const asleep = [_]MonitorInfo{};

// Windows that will not take the size of their tile.

// https://github.com/ianyh/Amethyst/issues/377
// https://github.com/ianyh/Amethyst/issues/1022
test "a window that cannot be resized floats where it is and takes no tile" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const settings = os.app_launch("Spotify", "com.spotify.client");
    const a = open(os, zed, .{});
    const place = Rect.init(500, 200, 715, 600);
    const fixed = open(os, settings, .{ .resizable = false, .frame = place });
    const b = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(engine_module.Mode.floating, mode_of(fixed));
    try expect_frame(place, fixed);
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(@as(u32, 0), engine.window_find(fixed).?.sets_total);
}

// https://github.com/ianyh/Amethyst/issues/641
// https://github.com/ianyh/Amethyst/issues/380
// https://github.com/ianyh/Amethyst/issues/203
// https://github.com/rxhanson/Rectangle/issues/185
test "a window wider than its tile hides whole and is asked a bounded number of times" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const wide = open(os, app, .{ .min_w = 1200, .min_h = 900 });
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 1200, 1079), wide);
    for (0..3) |_| {
        var sets = frames_sent(os);
        os.command_run("workspace 2");
        os.settle();
        try testing.expectEqual(@as(u64, 2), frames_sent(os) - sets);
        try testing.expect(parked(a) and parked(wide));
        // Coming back, the tile is asked for again: once, and the two retries.
        sets = frames_sent(os);
        os.command_run("workspace 1");
        os.settle();
        try testing.expectEqual(@as(u64, 2 + engine_module.attempts_max), frames_sent(os) - sets);
        try expect_frame(left_half, a);
        try expect_frame(Rect.init(864, 38, 1200, 1079), wide);
    }
}

// The simulator's windows take any size above their minimum. A terminal takes only
// whole character cells, so the frame it ends up with is never the one asked for.
// https://github.com/ianyh/Amethyst/issues/158
// https://github.com/ianyh/Amethyst/issues/216
// https://github.com/ianyh/Amethyst/issues/1036
// https://github.com/rxhanson/Rectangle/issues/2
// https://github.com/rxhanson/Rectangle/issues/1079
// https://github.com/Hammerspoon/hammerspoon/issues/2444
test "a terminal that resizes in whole character cells is asked a bounded number of times" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = os.app_launch("Terminal", "com.apple.Terminal");
    const a = open(os, zed, .{});
    const shell = open(os, terminal, .{});
    os.settle();
    cells = .{ .id = shell, .w = 7, .h = 17 };
    const known = engine.window_find(shell).?;
    var sets = known.sets_total;
    command_deliver(os, "resize left -100");
    // Its tile is 964 by 1079; 137 columns and 63 rows fit.
    try expect_frame(Rect.init(764, 38, 959, 1071), shell);
    try expect_frame(Rect.init(0, 38, 764, 1079), a);
    try testing.expectEqual(1 + engine_module.attempts_max, known.sets_total - sets);
    try testing.expectEqual(engine_module.Mode.tiled, known.mode);
    try testing.expect(engine.next_deadline_ms() == null);
    // Commands that leave its tile alone ask nothing more of it.
    sets = known.sets_total;
    command_deliver(os, "insert south");
    command_deliver(os, "label shell");
    command_deliver(os, "query windows");
    try testing.expectEqual(sets, known.sets_total);
    command_deliver(os, "resize left 100");
    try expect_frame(Rect.init(864, 38, 861, 1071), shell);
    try expect_frame(left_half, a);
    try testing.expectEqual(1 + engine_module.attempts_max, known.sets_total - sets);
    try testing.expect(!known.auto_floated);
}

// Dialogs, sheets, popovers and palettes.

// https://github.com/ianyh/Amethyst/issues/1031
// https://github.com/ianyh/Amethyst/issues/993
// https://github.com/ianyh/Amethyst/issues/1002
test "a dialog opens and closes without moving a tile, and focus returns to its window" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    const sets = frames_sent(os);
    const place = Rect.init(300, 300, 500, 300);
    const dialog = open(os, app, .{ .kind = .dialog, .frame = place });
    os.settle();
    try testing.expectEqual(dialog, engine.focused_window);
    try expect_frame(place, dialog);
    os.window_close(dialog);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expect(engine.focused_window == a or engine.focused_window == b);
    try testing.expectEqual(os.focused, engine.focused_window);
}

// https://github.com/ianyh/Amethyst/issues/1018
// https://github.com/ianyh/Amethyst/issues/1196
test "a dialog goes away with its workspace and comes back where it was" {
    const os = boot("");
    const finder = os.app_launch("Finder", "com.apple.finder");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const place = Rect.init(600, 400, 420, 120);
    const copying = open(os, finder, .{ .kind = .dialog, .frame = place });
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a) and parked(copying));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(place, copying);
}

// https://github.com/ianyh/Amethyst/issues/308
// https://github.com/ianyh/Amethyst/issues/883
// https://github.com/rxhanson/Rectangle/issues/1125
// https://github.com/rxhanson/Rectangle/issues/1303
test "a popup that takes the keyboard changes neither the layout nor the window in use" {
    const os = boot("");
    const app = os.app_launch("Google Chrome", "com.google.Chrome");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    const sets = frames_sent(os);
    const popup = open(os, app, .{ .kind = .popup, .frame = Rect.init(900, 80, 300, 400) });
    os.settle();
    try testing.expectEqual(popup, os.focused);
    try testing.expectEqual(b, engine.focused_window);
    // Commands still act on the window that was in use.
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    os.window_close(popup);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// Minimize and hide.

// https://github.com/ianyh/Amethyst/issues/1191
// https://github.com/ianyh/Amethyst/issues/1857
test "a minimized window gives up its tile and takes one again when it is restored" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(right_bottom, c);
    os.window_minimize(c, true);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expect(engine.focused_window == a or engine.focused_window == b);
    try testing.expectEqual(os.focused, engine.focused_window);
    os.window_minimize(c, false);
    os.settle();
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(screen.w * screen.h, tiles_area(&.{ a, b, c }));
}

fn tiles_area(ids: []const WindowId) i32 {
    var total: i32 = 0;
    for (ids) |id| total += frame_of(id).w * frame_of(id).h;
    return total;
}

// The shell does not report cmd-h yet; this is what the engine does once it reports a
// hidden application as its windows minimizing, and shown as them coming back.
// https://github.com/ianyh/Amethyst/issues/546
// https://github.com/ianyh/Amethyst/issues/741
// https://github.com/ianyh/Amethyst/issues/971
// https://github.com/ianyh/Amethyst/issues/1255
test "windows that leave together, as when their application hides, come back to tiles" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const b = open(os, slack, .{});
    const c = open(os, slack, .{});
    os.settle();
    os.window_minimize(b, true);
    os.window_minimize(c, true);
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    os.window_minimize(b, false);
    os.window_minimize(c, false);
    os.settle();
    try testing.expectEqual(screen.w * screen.h, tiles_area(&.{ a, b, c }));
    try testing.expectEqual(c, engine.focused_window);
}

// https://github.com/ianyh/Amethyst/issues/438
test "a window that is minimized when it is found takes no tile until it is restored" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const docked = os.window_open(app, .{ .adopted = true, .focus = false });
    os.window_minimize(docked, true);
    os.settle();
    try expect_frame(screen, a);
    try testing.expect(!engine.window_find(docked).?.in_layout());
    os.window_minimize(docked, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, docked);
}

// https://github.com/ianyh/Amethyst/issues/1855
// https://github.com/LGUG2Z/komorebi/issues/1673
test "a window restored from the Dock on a hidden workspace brings its workspace back" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a));
    os.advance(1000); // The user finds the Dock.
    os.window_minimize(b, false);
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(b, engine.focused_window);
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// Native fullscreen.

// The shell reads native fullscreen when it finds a window; this is the engine's side of
// a window entering and leaving it later.
// https://github.com/ianyh/Amethyst/issues/674
// https://github.com/ianyh/Amethyst/issues/1392
// https://github.com/ianyh/Amethyst/issues/1179
// https://github.com/ianyh/Amethyst/issues/101
test "a window in native fullscreen leaves the layout and is left alone until it returns" {
    const os = boot("");
    const app = os.app_launch("Safari", "com.apple.Safari");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    deliver(os, .{ .window_fullscreen = .{ .id = b, .fullscreen = true } });
    app_moves(os, b, laptop_frame);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(laptop_frame, b);
    const sets = engine.window_find(b).?.sets_total;
    // Nothing is asked of it while it is fullscreen, whatever else happens.
    os.command_run("workspace 2");
    os.settle();
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(laptop_frame, b);
    try testing.expectEqual(sets, engine.window_find(b).?.sets_total);
    deliver(os, .{ .window_fullscreen = .{ .id = b, .fullscreen = false } });
    os.settle();
    try testing.expectEqual(screen.w * screen.h, tiles_area(&.{ a, b }));
    try testing.expect(engine.window_find(b).?.in_layout());
}

// Native tabs.

// https://github.com/ianyh/Amethyst/issues/1613
// https://github.com/ianyh/Amethyst/issues/1614
// https://github.com/ianyh/Amethyst/issues/1821
// https://github.com/ianyh/Amethyst/issues/1832
// https://github.com/ianyh/Amethyst/issues/633
// https://github.com/rxhanson/Rectangle/issues/1685
test "opening, switching and closing native tabs sends no frame to any window" {
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    const terminal = open(os, ghostty, .{});
    os.settle();
    const sets = frames_sent(os);
    const second = open(os, ghostty, .{ .tab_of = terminal });
    const third = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    try testing.expectEqual(third, engine.focused_window);
    os.window_click(terminal);
    os.settle();
    try testing.expectEqual(terminal, engine.focused_window);
    os.window_click(second);
    os.settle();
    try testing.expectEqual(second, engine.focused_window);
    os.window_close(second);
    os.settle();
    os.window_close(third);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try testing.expectEqual(terminal, engine.focused_window);
    try expect_frame(left_half, editor);
    try expect_frame(right_half, terminal);
}

// https://github.com/ianyh/Amethyst/issues/1094
// https://github.com/ianyh/Amethyst/issues/895
test "a tab group moves between workspaces as one window" {
    const os = boot("");
    const terminal = os.app_launch("Terminal", "com.apple.Terminal");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    const files = open(os, terminal, .{});
    const tab = open(os, terminal, .{ .tab_of = files });
    os.settle();
    try expect_frame(right_half, tab);
    os.command_run("send 2");
    os.settle();
    try expect_frame(screen, editor);
    try testing.expect(parked(files) and parked(tab));
    try testing.expectEqual(@as(u8, 1), workspace_of(files));
    try testing.expectEqual(@as(u8, 1), workspace_of(tab));
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, tab);
    try expect_frame(screen, files);
    try testing.expectEqual(tab, engine.focused_window);
}

// An application that closes a window and opens its replacement in the same place is
// reported by the shell as a tab of the old one, which then closes.
// https://github.com/ianyh/Amethyst/issues/1612
test "an application that replaces a window in place keeps its tile" {
    const os = boot("");
    const preview = os.app_launch("Preview", "com.apple.Preview");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const files = open(os, preview, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.window_click(files);
    os.settle();
    const sets = frames_sent(os);
    const replacement = open(os, preview, .{ .tab_of = files });
    os.window_close(files);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try expect_frame(left_half, replacement);
    try expect_frame(right_top, b);
    try expect_frame(right_bottom, c);
    try testing.expectEqual(replacement, engine.focused_window);
}

// Windows that close, and where focus goes.

// https://github.com/ianyh/Amethyst/issues/1790
// https://github.com/ianyh/Amethyst/issues/1837
// https://github.com/ianyh/Amethyst/issues/1849
test "closing a window resizes only the window that shared its split" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const sets = frames_sent(os);
    os.window_close(c);
    os.settle();
    try testing.expectEqual(@as(u64, 1), frames_sent(os) - sets);
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(b, os.focused);
}

// https://github.com/ianyh/Amethyst/issues/483
// https://github.com/ianyh/Amethyst/issues/1169
// https://github.com/ianyh/Amethyst/issues/1431
// https://github.com/ianyh/Amethyst/issues/85
test "a window that closes on a hidden workspace leaves no hole there" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    os.window_close(b);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    os.advance(1000);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
}

// https://github.com/ianyh/Amethyst/issues/71
// https://github.com/ianyh/Amethyst/issues/467
test "an application that quits takes its windows on every workspace with it" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    _ = open(os, slack, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, zed, .{});
    _ = open(os, slack, .{});
    os.settle();
    os.app_quit(slack);
    os.settle();
    try expect_frame(screen, c);
    try testing.expectEqual(c, engine.focused_window);
    os.advance(1000);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(@as(u32, 2), engine.forest.leaf_count(engine.workspaces[0].root) +
        engine.forest.leaf_count(engine.workspaces[1].root));
}

// macOS gives focus to another window of the same application when one closes, wherever
// that window is.
// https://github.com/ianyh/Amethyst/issues/1175
// https://github.com/ianyh/Amethyst/issues/1506
// https://github.com/ianyh/Amethyst/issues/1466
test "closing a window keeps you on the workspace, whatever macOS focuses next" {
    const os = boot("");
    const chrome = os.app_launch("Google Chrome", "com.google.Chrome");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const elsewhere = open(os, chrome, .{});
    os.settle();
    os.command_run("workspace 2");
    const editor = open(os, zed, .{});
    const browser = open(os, chrome, .{});
    os.settle();
    os.advance(1000);
    os.window_close(browser);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expect(parked(elsewhere));
    try expect_frame(screen, editor);
    try testing.expectEqual(editor, engine.focused_window);
    try testing.expectEqual(editor, os.focused);
    // The last window of the workspace: it stays, empty.
    os.advance(1000);
    os.window_close(editor);
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expect(parked(elsewhere));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
}

// Asking a window for focus takes an application anything from 15 ms to the best part
// of a second. What the user does meanwhile must not be undone when the answer comes.
// https://github.com/LGUG2Z/komorebi/issues/1676
// https://github.com/LGUG2Z/komorebi/issues/879
// https://github.com/LGUG2Z/komorebi/issues/2
test "an empty workspace stays when a focus asked for just before is confirmed late" {
    const os = boot("");
    const app = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("focus west"); // Asks macOS to focus a ...
    os.command_run("workspace 5"); // ... and moves on before it has answered.
    os.settle();
    try testing.expectEqual(a, os.focused);
    try testing.expectEqual(@as(u8, 4), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expect(parked(a) and parked(b));
    // The window that opens next opens here.
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(screen, c);
    try testing.expect(parked(a) and parked(b));
}

// https://github.com/LGUG2Z/komorebi/issues/148
// https://github.com/LGUG2Z/komorebi/issues/1678
// https://github.com/ianyh/Amethyst/issues/838
test "an empty display keeps focus when a focus asked for just before is confirmed late" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("focus west");
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(a, os.focused);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(external, c);
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/ianyh/Amethyst/issues/1779
// https://github.com/ianyh/Amethyst/issues/1753
test "a new window joins the workspace in use, wherever its application lives" {
    const os = boot("");
    const chrome = os.app_launch("Google Chrome", "com.google.Chrome");
    const first = open(os, chrome, .{});
    os.settle();
    os.command_run("workspace 3");
    os.settle();
    os.advance(1000);
    const second = open(os, chrome, .{});
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(u8, 2), workspace_of(second));
    try expect_frame(screen, second);
    try testing.expect(parked(first));
    try testing.expectEqual(second, engine.focused_window);
}

// https://github.com/ianyh/Amethyst/issues/372
// https://github.com/ianyh/Amethyst/issues/289
// https://github.com/rxhanson/Rectangle/issues/933
// https://github.com/rxhanson/Rectangle/issues/231
test "focus asked of a hung application is given up, and the keys keep working" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const office = os.app_launch("LibreOffice", "org.libreoffice.script");
    const a = open(os, zed, .{});
    const b = open(os, office, .{});
    const c = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(c, os.focused);
    os.app_hang(office, 60_000);
    os.command_run("focus north");
    try testing.expectEqual(b, engine.focused_window);
    os.advance(engine_module.focus_pending_ms + 1);
    // It never took focus: the engine asked macOS and believes the answer.
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus west");
    os.advance(1);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try expect_frame(left_half, a);
}

// Displays that sleep, change and move.

// https://github.com/ianyh/Amethyst/issues/1167
// https://github.com/ianyh/Amethyst/issues/1282
// https://github.com/ianyh/Amethyst/issues/194
// https://github.com/rxhanson/Rectangle/issues/1234
// https://github.com/LGUG2Z/komorebi/issues/364
// https://github.com/LGUG2Z/komorebi/issues/1660
test "displays that all go to sleep come back to the same workspaces and move nothing" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.command_run("workspace 5");
    const c = open(os, app, .{});
    os.settle();
    // The external display shows workspace 5; its other workspace, with b, is hidden.
    try expect_frame(screen, a);
    try expect_frame(external, c);
    try testing.expect(parked(b));
    // And the user is on the laptop, on a workspace that has nothing on it.
    os.command_run("focus-monitor 1");
    os.settle();
    os.command_run("workspace 7");
    os.settle();
    try testing.expect(parked(a));
    try testing.expectEqual(@as(u8, 6), engine.workspace_current());
    const sets = frames_sent(os);
    monitors_deliver(os, &asleep);
    os.advance(60_000);
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try testing.expectEqual(@as(u8, 6), engine.workspace_current());
    try testing.expect(parked(a) and parked(b));
    try expect_frame(external, c);
}

// https://github.com/LGUG2Z/komorebi/issues/1087
// https://github.com/rxhanson/Rectangle/issues/1398
test "a window that opens while the displays are asleep joins the workspace in use" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.command_run("workspace 3");
    const b = open(os, app, .{});
    os.settle();
    monitors_deliver(os, &asleep);
    const c = open(os, app, .{});
    os.advance(60_000);
    monitors_deliver(os, &laptop);
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(@as(u8, 2), workspace_of(c));
    try testing.expect(parked(a));
    try testing.expect(!parked(b) and !parked(c));
    try testing.expectEqual(screen.w * screen.h, tiles_area(&.{ b, c }));
}

// https://github.com/ianyh/Amethyst/issues/232
// https://github.com/rxhanson/Rectangle/issues/1064
test "a display that changes its resolution re-tiles what it shows" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, app, .{});
    os.settle();
    const smaller = [_]MonitorInfo{
        display(1, Rect.init(0, 0, 1280, 800), Rect.init(0, 25, 1280, 775), true),
    };
    monitors_deliver(os, &smaller);
    os.settle();
    try expect_frame(Rect.init(0, 25, 1280, 775), c);
    try testing.expect(parked(a) and parked(b));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(Rect.init(0, 25, 640, 775), a);
    try expect_frame(Rect.init(640, 25, 640, 775), b);
    try testing.expect(parked(c));
}

// https://github.com/ianyh/Amethyst/issues/141
// https://github.com/ianyh/Amethyst/issues/729
// https://github.com/ianyh/Amethyst/issues/349
// https://github.com/rxhanson/Rectangle/issues/106
// https://github.com/rxhanson/Rectangle/issues/467
// https://github.com/rxhanson/Rectangle/issues/695
test "the Dock, the menu bar or the notch taking room re-tiles into what is left" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    // The Dock appears on the left and the menu bar hides itself.
    const docked = [_]MonitorInfo{
        display(1, laptop_frame, Rect.init(80, 0, 1648, 1117), true),
    };
    monitors_deliver(os, &docked);
    os.settle();
    try expect_frame(Rect.init(80, 0, 824, 1117), a);
    try expect_frame(Rect.init(904, 0, 824, 1117), b);
    monitors_deliver(os, &laptop);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/ianyh/Amethyst/issues/1140
// https://github.com/LGUG2Z/komorebi/issues/267
test "a display notice that changes nothing sends no frame and keeps focus" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, app, .{});
    os.settle();
    const sets = frames_sent(os);
    for (0..3) |_| {
        os.monitors_set(0);
        os.settle();
    }
    try testing.expectEqual(sets, frames_sent(os));
    try testing.expectEqual(c, engine.focused_window);
    try testing.expect(parked(a) and parked(b));
}

// https://github.com/ianyh/Amethyst/issues/238
// https://github.com/rxhanson/Rectangle/issues/1272
// https://github.com/rxhanson/Rectangle/issues/1595
test "displays that swap sides keep their workspaces and their windows" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.monitors_set(2); // The external display on the left, the laptop right and lower.
    os.settle();
    try expect_frame(Rect.init(2560, 361, 1728, 1079), a);
    try expect_frame(Rect.init(0, 38, 1280, 1402), b);
    try expect_frame(Rect.init(1280, 38, 1280, 1402), c);
    try testing.expectEqual(c, engine.focused_window);
    // Monitors are numbered from the left, so the external display is now the first.
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
}

// https://github.com/rxhanson/Rectangle/issues/192
// https://github.com/ianyh/Amethyst/issues/1155
test "hidden windows of stacked displays do not show on the other display" {
    const os = boot("");
    os.monitors_set(4); // The external display above, the laptop below it.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.command_run("focus-monitor 1");
    const c = open(os, app, .{});
    os.settle();
    try testing.expect(!parked(a) and !parked(b) and !parked(c));
    os.command_run("workspace new");
    os.settle();
    try testing.expect(parked(c));
    try testing.expect(!parked(a) and !parked(b));
    os.command_run("focus-monitor 2");
    os.settle();
    os.command_run("workspace new");
    os.settle();
    try testing.expect(parked(a) and parked(b) and parked(c));
}

// A 1920 point display above a laptop set to show more: wider than the display over it.
// https://github.com/rxhanson/Rectangle/issues/192
// https://github.com/Hammerspoon/hammerspoon/issues/3263
// https://github.com/LGUG2Z/komorebi/issues/1056
test "hidden windows of a display above a wider one do not show on the wider one" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const upper = Rect.init(320, 25, 1920, 1055);
    const stacked = [_]MonitorInfo{
        display(2, Rect.init(320, 0, 1920, 1080), upper, false),
        display(1, Rect.init(0, 1080, 2560, 1440), Rect.init(0, 1105, 2560, 1415), true),
    };
    monitors_deliver(os, &stacked);
    os.settle();
    os.command_run("focus-monitor 2");
    const a = open(os, app, .{});
    const b = open(os, app, .{ .min_w = 1200 });
    os.settle();
    try expect_frame(Rect.init(320, 25, 960, 1055), a);
    try expect_frame(Rect.init(1280, 25, 1200, 1055), b);
    for (0..2) |_| {
        var sets = frames_sent(os);
        os.command_run("workspace new");
        os.settle();
        try testing.expect(parked(a) and parked(b));
        try testing.expectEqual(@as(u64, 2), frames_sent(os) - sets);
        sets = frames_sent(os);
        os.command_run("workspace recent");
        os.settle();
        try expect_frame(Rect.init(320, 25, 960, 1055), a);
        try expect_frame(Rect.init(1280, 25, 1200, 1055), b);
        try testing.expectEqual(@as(u64, 2 + engine_module.attempts_max), frames_sent(os) - sets);
    }
}

// Windows that move themselves.

// macOS pulls windows back on screen when displays change or wake, and some applications
// restore their own position when they are activated.
// https://github.com/ianyh/Amethyst/issues/1030
// https://github.com/rxhanson/Rectangle/issues/777
test "a hidden window that is moved back on screen is hidden again" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    try testing.expect(parked(a));
    app_moves(os, a, Rect.init(100, 100, 1728, 1079));
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(screen, b);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
}

// https://github.com/rxhanson/Rectangle/issues/1447
// https://github.com/ianyh/Amethyst/issues/929
// https://github.com/ianyh/Amethyst/issues/1119
test "a window that resizes itself after it was placed is put back once" {
    const os = boot("");
    const app = os.app_launch("Firefox", "org.mozilla.firefox");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    const sets = frames_sent(os);
    app_moves(os, b, Rect.init(900, 100, 700, 500));
    // Not at once: the application may be in the middle of an animation.
    try testing.expectEqual(sets, frames_sent(os));
    os.settle();
    try testing.expectEqual(@as(u64, 1), frames_sent(os) - sets);
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(b));
}

// https://github.com/ianyh/Amethyst/issues/1495
// https://github.com/ianyh/Amethyst/issues/1043
// https://github.com/ianyh/Amethyst/issues/989
test "a tile nudged with the mouse inside its own cell goes back and nothing swaps" {
    const os = boot("");
    const app = os.app_launch("Google Chrome", "com.google.Chrome");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_drag(a, Rect.init(40, 60, 864, 1079));
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// More than one display.

// https://github.com/ianyh/Amethyst/issues/242
// https://github.com/ianyh/Amethyst/issues/1853
// https://github.com/ianyh/Amethyst/issues/223
test "a tile dragged onto a display with no tiles moves there" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(right_half, b);
    os.window_drag(b, Rect.init(2400, 300, 864, 1079));
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
}

// https://github.com/ianyh/Amethyst/issues/408
// https://github.com/ianyh/Amethyst/issues/533
// https://github.com/ianyh/Amethyst/issues/280
test "focus can go to a display with no windows, and the next window opens there" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
}

// https://github.com/ianyh/Amethyst/issues/703
// https://github.com/ianyh/Amethyst/issues/753
// https://github.com/ianyh/Amethyst/issues/466
test "going to another display focuses the window last used there" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.window_click(b);
    os.settle();
    os.command_run("focus-monitor 2");
    const d = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 1");
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(b, os.focused);
    os.command_run("focus-monitor 2");
    os.settle();
    try testing.expectEqual(d, engine.focused_window);
    _ = a;
    _ = c;
}

// https://github.com/rxhanson/Rectangle/issues/94
// https://github.com/rxhanson/Rectangle/issues/1080
// https://github.com/rxhanson/Rectangle/issues/54
// https://github.com/ianyh/Amethyst/issues/1229
test "a window sent to a display of another size fills its share of that display" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("send-monitor 2 --follow");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("send-monitor 1 --follow");
    os.settle();
    try testing.expectEqual(screen.w * screen.h, tiles_area(&.{ a, b }));
    try testing.expectEqual(b, os.focused);
}

// Meeting controls, call windows and alerts open on whichever display their application
// likes, not on the one in use.
// https://github.com/ianyh/Amethyst/issues/1776
// https://github.com/ianyh/Amethyst/issues/1210
// https://github.com/LGUG2Z/komorebi/issues/1679
test "a floating window that opens on another display belongs to that display" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const zoom = os.app_launch("zoom.us", "us.zoom.xos");
    const a = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    const place = Rect.init(2600, 900, 600, 80);
    const controls = open(os, zoom, .{ .kind = .dialog, .frame = place, .focus = false });
    os.settle();
    try expect_frame(place, controls);
    // Changing the workspace of the laptop leaves the other display as it is.
    os.command_run("workspace 4");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(place, controls);
    try testing.expectEqual(engine.monitors[1].workspace, workspace_of(controls));
}

// https://github.com/ianyh/Amethyst/issues/626
// https://github.com/ianyh/Amethyst/issues/1030
// https://github.com/LGUG2Z/komorebi/issues/841
test "a floating window that opens off every display is brought into view" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    // Where it was when a second display was still attached.
    const lost = open(os, app, .{ .kind = .dialog, .frame = Rect.init(3000, 400, 500, 300) });
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(Rect.init(614, 427, 500, 300), lost);
}

// https://github.com/rxhanson/Rectangle/issues/779
// https://github.com/rxhanson/Rectangle/issues/1552
test "a floating window whose display is unplugged comes into view on the one left" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    os.command_run("focus-monitor 2");
    const a = open(os, app, .{});
    os.command_run("toggle float");
    os.command_run("grid 4:4:2:1:2:2");
    os.settle();
    try expect_frame(Rect.init(3008, 388, 1280, 700), a);
    os.monitors_set(0);
    os.settle();
    try testing.expect(frame_of(a).x >= 0 and frame_of(a).right() <= 1728);
    try testing.expect(frame_of(a).y >= 38 and frame_of(a).bottom() <= 1117);
    try testing.expectEqual(a, engine.focused_window);
}

// Quick fingers and slow applications.

// https://github.com/LGUG2Z/komorebi/issues/151
// https://github.com/LGUG2Z/komorebi/issues/897
// https://github.com/LGUG2Z/komorebi/issues/879
// https://github.com/LGUG2Z/komorebi/issues/1676
test "workspaces switched faster than focus is confirmed end on the last one asked for" {
    const os = boot("");
    const app = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, app, .{});
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    // Nothing waits for macOS between these.
    os.command_run("workspace 1");
    os.command_run("workspace 2");
    os.command_run("workspace 1");
    os.command_run("workspace 3");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expect(parked(a) and parked(b));
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
    os.command_run("workspace 2");
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_frame(screen, a);
    try testing.expect(parked(b));
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
}

// https://github.com/LGUG2Z/komorebi/issues/22
// https://github.com/LGUG2Z/komorebi/issues/1543
// https://github.com/Hammerspoon/hammerspoon/issues/3574
// https://github.com/Hammerspoon/hammerspoon/issues/3421
test "a workspace switch does not wait for a hung application" {
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const teams = os.app_launch("Microsoft Teams", "com.microsoft.teams2");
    const a = open(os, zed, .{});
    const b = open(os, teams, .{});
    os.settle();
    os.command_run("workspace 2");
    const c = open(os, zed, .{});
    os.settle();
    os.app_hang(teams, 5000);
    os.command_run("workspace 1");
    os.advance(1);
    try expect_frame(left_half, a);
    try testing.expect(parked(c));
    try testing.expect(parked(b)); // It has not heard yet.
    try testing.expectEqual(b, engine.focused_window);
    os.settle();
    try expect_frame(right_half, b);
    try testing.expect(engine.window_find(b).?.sets_total <= 4);
}

// https://github.com/Hammerspoon/hammerspoon/issues/2043
// https://github.com/Hammerspoon/hammerspoon/issues/3731
// https://github.com/Hammerspoon/hammerspoon/issues/478
test "a window that animates to its frame is asked a bounded number of times" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const slow = open(os, app, .{ .animates = true });
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, slow);
    try testing.expect(engine.window_find(slow).?.sets_total <= 1 + engine_module.attempts_max);
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(slow));
}

// Applications bring a parked window back when they are activated, every time.
// https://github.com/ianyh/Amethyst/issues/1834
// https://github.com/ianyh/Amethyst/issues/216
// https://github.com/rxhanson/Rectangle/issues/889
test "a hidden window that will not stay hidden is left alone after a few tries" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const home = Rect.init(200, 200, 800, 600);
    const loud = open(os, app, .{ .stubborn = true, .frame = home });
    os.settle();
    try testing.expect(engine.window_find(loud).?.auto_floated);
    os.command_run("workspace 2");
    os.settle(); // Would never return if the two kept answering each other.
    const known = engine.window_find(loud).?;
    try testing.expect(known.frozen);
    try testing.expect(known.sets_total <= 2 * (engine_module.drift_max + 1) + 1);
    try expect_frame(home, loud);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
}

// Zoom, the tatami kind: one window fills the workspace and the layout stays as it is.

// https://github.com/LGUG2Z/komorebi/issues/19
// https://github.com/LGUG2Z/komorebi/issues/331
// https://github.com/LGUG2Z/komorebi/issues/819
// https://github.com/LGUG2Z/komorebi/issues/1257
test "a zoomed window can be left with the focus keys and closed, and sizes are kept" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("resize left -100");
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    try expect_frame(Rect.init(0, 38, 764, 1079), a);
    os.command_run("zoom --on");
    os.settle();
    try expect_frame(screen, c);
    os.command_run("focus north");
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    try expect_frame(screen, c);
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    _ = run(os, "zoom {d} --off", .{c});
    os.settle();
    try expect_frame(frames[2], c);
    _ = run(os, "zoom {d} --on", .{c});
    os.settle();
    os.window_close(c);
    os.settle();
    try expect_frame(frames[0], a);
    try expect_frame(Rect.init(764, 38, 964, 1079), b);
    // Focus goes to the window that was in use before the one that closed.
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
}

// https://github.com/LGUG2Z/komorebi/issues/1209
// https://github.com/LGUG2Z/komorebi/issues/1210
// https://github.com/LGUG2Z/komorebi/issues/1191
test "a window in native fullscreen can be sent away and commands act on the window in use" {
    const os = boot("");
    const app = os.app_launch("Safari", "com.apple.Safari");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const movie = open(os, app, .{});
    os.settle();
    deliver(os, .{ .window_fullscreen = .{ .id = movie, .fullscreen = true } });
    app_moves(os, movie, laptop_frame);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    os.window_click(a);
    os.settle();
    os.command_run("swap east");
    os.settle();
    try expect_frame(right_half, a);
    try expect_frame(left_half, b);
    try expect_frame(laptop_frame, movie);
    _ = run(os, "focus {d}", .{movie});
    os.command_run("send 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), workspace_of(movie));
    try expect_frame(laptop_frame, movie);
    deliver(os, .{ .window_fullscreen = .{ .id = movie, .fullscreen = false } });
    os.settle();
    try testing.expect(parked(movie));
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
}

// Windows that are not really windows.

// https://github.com/ianyh/Amethyst/issues/1220
// https://github.com/ianyh/Amethyst/issues/1509
test "a picture in picture window made sticky by a rule floats over every workspace" {
    const os = boot("rule title=\"Picture in Picture\" : sticky\n");
    const app = os.app_launch("Firefox", "org.mozilla.firefox");
    const a = open(os, app, .{});
    const place = Rect.init(1300, 800, 400, 225);
    const video = open(os, app, .{ .title = "Picture in Picture", .frame = place, .focus = false });
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(place, video);
    os.command_run("workspace 2");
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(screen, b);
    try expect_frame(place, video);
    try testing.expect(parked(a));
    try testing.expectEqual(@as(u32, 0), engine.window_find(video).?.sets_total);
}

// https://github.com/ianyh/Amethyst/issues/1143
// https://github.com/LGUG2Z/komorebi/issues/406
// https://github.com/LGUG2Z/komorebi/issues/94
test "a notification window matched by an ignore rule moves nothing and takes no focus" {
    const os = boot("rule app=\"Microsoft Teams\" title=\"Notification\" : ignore\n");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const teams = os.app_launch("Microsoft Teams", "com.microsoft.teams2");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    const sets = frames_sent(os);
    const place = Rect.init(1380, 50, 340, 100);
    const toast = open(os, teams, .{ .title = "Notification", .frame = place });
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    os.window_close(toast);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/LGUG2Z/komorebi/issues/990
// https://github.com/LGUG2Z/komorebi/issues/178
// https://github.com/ianyh/Amethyst/issues/1031
test "a dialog from an application on a hidden workspace shows here and takes nobody along" {
    const os = boot("");
    const outlook = os.app_launch("Microsoft Outlook", "com.microsoft.Outlook");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const mail = open(os, outlook, .{});
    os.settle();
    os.command_run("workspace 2");
    const editor = open(os, zed, .{});
    os.settle();
    os.advance(1000);
    const place = Rect.init(600, 300, 500, 400);
    const reminder = open(os, outlook, .{ .kind = .dialog, .frame = place });
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_frame(place, reminder);
    try expect_frame(screen, editor);
    try testing.expect(parked(mail));
    os.advance(1000);
    os.window_close(reminder);
    os.settle();
    // macOS hands focus to the mail window; the workspace in use stays.
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expect(parked(mail));
    try testing.expectEqual(editor, engine.focused_window);
    try testing.expectEqual(editor, os.focused);
}

// https://github.com/Hammerspoon/hammerspoon/issues/2487
// https://github.com/Hammerspoon/hammerspoon/issues/2671
test "a window that reports an empty frame when it opens is tiled all the same" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{ .frame = Rect.init(0, 0, 0, 0) });
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

// https://github.com/LGUG2Z/komorebi/issues/1231
// https://github.com/LGUG2Z/komorebi/issues/1730
// https://github.com/LGUG2Z/komorebi/issues/878
test "minimizing a window that is not in use closes its tile and leaves focus alone" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.window_minimize(a, true);
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 540), b);
    try expect_frame(Rect.init(0, 578, 1728, 539), c);
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(c, os.focused);
    // On a hidden workspace too: the tile is gone when the workspace comes back.
    os.command_run("workspace 2");
    os.settle();
    os.window_minimize(b, true);
    os.settle();
    os.advance(1000);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, c);
}

// https://github.com/LGUG2Z/komorebi/issues/1701
// https://github.com/LGUG2Z/komorebi/issues/1130
// https://github.com/ianyh/Amethyst/issues/950
test "the focus keys reach floating windows and come back from them" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const note = open(os, app, .{ .kind = .dialog, .frame = Rect.init(1500, 400, 200, 200) });
    os.settle();
    try testing.expectEqual(note, engine.focused_window);
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus west");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus next");
    os.command_run("focus next");
    os.settle();
    try testing.expectEqual(note, engine.focused_window);
    try testing.expectEqual(note, os.focused);
    // A workspace whose last window in use floats gives focus back to it.
    os.command_run("workspace 2");
    os.settle();
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(note, engine.focused_window);
    try testing.expectEqual(note, os.focused);
}

// More displays.

// https://github.com/Hammerspoon/hammerspoon/issues/955
// https://github.com/Hammerspoon/hammerspoon/issues/3263
// https://github.com/Hammerspoon/hammerspoon/issues/2324
test "a display left of and above the main one, at negative coordinates, works like any other" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    const far = Rect.init(-2560, -400, 2560, 1440);
    const two = [_]MonitorInfo{
        display(2, far, Rect.init(-2560, -375, 2560, 1415), false),
        display(1, laptop_frame, screen, true),
    };
    monitors_deliver(os, &two);
    os.settle();
    try expect_frame(screen, a);
    os.command_run("focus-monitor 1");
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(Rect.init(-2560, -375, 1280, 1415), b);
    try expect_frame(Rect.init(-1280, -375, 1280, 1415), c);
    os.command_run("focus east");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus-monitor 1");
    os.settle();
    os.command_run("workspace new");
    os.settle();
    try testing.expect(parked(b) and parked(c));
    try expect_frame(screen, a);
}

// https://github.com/ianyh/Amethyst/issues/230
// https://github.com/ianyh/Amethyst/issues/238
// https://github.com/LGUG2Z/komorebi/issues/1640
test "plugging in a display, or making it the main one, moves no window in view" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.command_run("workspace 2");
    const c = open(os, app, .{});
    os.settle();
    var sets = frames_sent(os);
    os.monitors_set(1);
    os.settle();
    // Only the two hidden windows move: to the corner that the new display cannot see.
    try testing.expectEqual(@as(u64, 2), frames_sent(os) - sets);
    sets = frames_sent(os);
    const other_main = [_]MonitorInfo{
        display(1, laptop_frame, screen, false),
        display(2, Rect.init(1728, 0, 2560, 1440), external, true),
    };
    monitors_deliver(os, &other_main);
    os.settle();
    try testing.expectEqual(sets, frames_sent(os));
    try expect_frame(screen, c);
    try testing.expect(parked(a) and parked(b));
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
}

// https://github.com/LGUG2Z/komorebi/issues/30
// https://github.com/LGUG2Z/komorebi/issues/831
// https://github.com/LGUG2Z/komorebi/issues/239
test "an empty workspace opens on the display in use, a used one on its own display" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    os.command_run("workspace 6");
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(external, b);
    try expect_frame(screen, a);
    os.command_run("focus-monitor 1");
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    // From the laptop: workspace 6 lives on the external display and is shown there.
    os.command_run("workspace 6");
    os.settle();
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    try testing.expectEqual(b, engine.focused_window);
    try testing.expectEqual(b, os.focused);
    try expect_frame(screen, a);
}

// https://github.com/LGUG2Z/komorebi/issues/1065
// https://github.com/LGUG2Z/komorebi/issues/1592
// https://github.com/Hammerspoon/hammerspoon/issues/3347
test "a floating window dragged to another display belongs there, and focus goes along" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const note = open(os, app, .{ .kind = .dialog, .frame = Rect.init(400, 300, 600, 400) });
    os.settle();
    const there = Rect.init(2500, 500, 600, 400);
    os.window_drag(note, there);
    os.settle();
    try expect_frame(there, note);
    try testing.expectEqual(engine.monitors[1].workspace, workspace_of(note));
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    // The laptop's workspaces no longer take it with them.
    os.command_run("focus-monitor 1");
    os.settle();
    os.command_run("workspace 3");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(there, note);
}

// https://github.com/rxhanson/Rectangle/issues/779
// https://github.com/rxhanson/Rectangle/issues/54
// https://github.com/Hammerspoon/hammerspoon/issues/3852
test "a floating window sent to a smaller display is wholly on it" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    os.command_run("focus-monitor 2");
    const a = open(os, app, .{});
    os.command_run("toggle float");
    os.command_run("grid 4:4:2:1:2:2");
    os.settle();
    try expect_frame(Rect.init(3008, 388, 1280, 700), a);
    os.command_run("send-monitor 1 --follow");
    os.settle();
    try expect_frame(Rect.init(448, 388, 1280, 700), a);
    try testing.expectEqual(a, engine.focused_window);
    // And back: it fits, so it keeps its spot relative to the display.
    os.command_run("send-monitor 2 --follow");
    os.settle();
    try expect_frame(Rect.init(2176, 388, 1280, 700), a);
}

// The shell names a display by the number macOS gives it, and macOS gives a display a
// new number now and then. Nothing is lost when it does; the windows wait on the main
// display until they are sent back.
// https://github.com/LGUG2Z/komorebi/issues/31
// https://github.com/LGUG2Z/komorebi/issues/275
// https://github.com/LGUG2Z/komorebi/issues/913
test "a display that comes back under another number starts empty and loses nothing" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(external, b);
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, b);
    try testing.expect(parked(a));
    const renumbered = [_]MonitorInfo{
        display(1, laptop_frame, screen, true),
        display(7, Rect.init(1728, 0, 2560, 1440), external, false),
    };
    monitors_deliver(os, &renumbered);
    os.settle();
    try expect_frame(screen, b);
    try testing.expect(parked(a));
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("send-monitor 2 --follow");
    os.settle();
    try expect_frame(external, b);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try testing.expectEqual(a, engine.focused_window);
}

// https://github.com/ianyh/Amethyst/issues/1342
// https://github.com/ianyh/Amethyst/issues/1281
// https://github.com/ianyh/Amethyst/issues/551
test "a tile dropped on a tile of another display joins the layout there" {
    const os = boot("");
    os.monitors_set(1);
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.command_run("focus-monitor 2");
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(external, c);
    os.window_drag(b, Rect.init(2400, 200, 864, 1079));
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(external.w * external.h, tiles_area(&.{ b, c }));
    try testing.expectEqual(workspace_of(c), workspace_of(b));
    try testing.expectEqual(engine_module.Mode.tiled, mode_of(b));
}
