//! Deterministic simulation: a model of macOS as a window manager sees it, driven by one
//! seeded PRNG. The same Engine that runs under the real shell runs here against apps that
//! hang, windows that refuse sizes, animate, fight back, change titles late, form tab
//! groups, and monitors that come and go.
//!
//! After every step the engine's invariants are verified. Whenever the workload pauses the
//! system must go quiet in bounded work (no endless flashing) and must then agree with the
//! simulated OS about frames and focus.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const WindowId = engine_module.WindowId;
const MonitorInfo = engine_module.MonitorInfo;

pub const windows_max: u32 = 40;
pub const apps_max: u32 = 10;
pub const queue_max: u32 = 8192;
/// Upper bound on events needed to go quiet. Exceeding it means something loops.
pub const settle_events_max: u32 = 50_000;

/// Set by the runner: print every event and effect.
pub var trace: bool = false;
/// The seed in flight, for whoever inspects a crash.
pub var seed_running: u64 = 0;

pub const Options = struct {
    seed: u64,
    /// Hung apps, stubborn windows, animations, minimum sizes, spurious notifications.
    faults: bool = true,
};

const SimWindow = struct {
    id: WindowId = 0,
    pid: i32 = 0,
    frame: Rect = Rect.zero,
    min_w: i32 = 1,
    min_h: i32 = 1,
    kind: engine_module.WindowKind = .standard,
    resizable: bool = true,
    minimized: bool = false,
    /// Moves itself back to home whenever it is moved.
    stubborn: bool = false,
    home: Rect = Rect.zero,
    /// Takes a while to reach a new frame and reports frames on the way.
    animates: bool = false,
    animation: u32 = 0,
    /// Windows with the same non-zero group are native tabs of each other.
    tab_group: u32 = 0,
    title: []const u8 = "",
    adopted: bool = false,
};

const SimApp = struct {
    pid: i32 = 0,
    name: []const u8 = "",
    bundle: []const u8 = "",
    unresponsive_until_ms: u64 = 0,
};

const QueuedKind = enum {
    appeared,
    destroyed,
    frame_applied,
    frame_changed,
    title_changed,
    minimized,
    tab_changed,
    focused,
    focus_report,
    app_launched,
    app_terminated,
    app_unresponsive,
    // Things the simulated OS does to itself later.
    self_move,
    animation_end,
    late_title,
};

const Queued = struct {
    at_ms: u64,
    seq: u64,
    kind: QueuedKind,
    id: WindowId = 0,
    pid: i32 = 0,
    frame: Rect = Rect.zero,
    flag: bool = false,
    token: u32 = 0,
};

const AppTemplate = struct { name: []const u8, bundle: []const u8 };

const app_templates = [_]AppTemplate{
    .{ .name = "Ghostty", .bundle = "com.mitchellh.ghostty" },
    .{ .name = "Brave Browser", .bundle = "com.brave.Browser" },
    .{ .name = "Google Chrome", .bundle = "com.google.Chrome" },
    .{ .name = "Slack", .bundle = "com.tinyspeck.slackmacgap" },
    .{ .name = "Granola", .bundle = "com.granola.app" },
    .{ .name = "Finder", .bundle = "com.apple.finder" },
    .{ .name = "Zed", .bundle = "dev.zed.Zed" },
    .{ .name = "Simulator", .bundle = "com.apple.iphonesimulator" },
};

const titles = [_][]const u8{ "Untitled", "main.zig", "Inbox", "Tempo Wallet", "Huddle", "~" };

const monitor_presets = [_][]const MonitorInfo{
    &.{monitor(1, 0, 0, 1728, 1117, true)},
    &.{ monitor(1, 0, 0, 1728, 1117, true), monitor(2, 1728, 0, 2560, 1440, false) },
    &.{ monitor(2, 0, 0, 2560, 1440, false), monitor(1, 2560, 323, 1728, 1117, true) },
    &.{
        monitor(3, 0, 0, 1920, 1080, false),
        monitor(1, 1920, 0, 1728, 1117, true),
        monitor(2, 3648, 0, 2560, 1440, false),
    },
    &.{ monitor(2, 0, 0, 2560, 1440, false), monitor(1, 416, 1440, 1728, 1117, true) },
};

fn monitor(display: u32, x: i32, y: i32, w: i32, h: i32, main: bool) MonitorInfo {
    const menu_bar = 38;
    return .{
        .display = display,
        .frame = .{ .x = x, .y = y, .w = w, .h = h },
        .visible = .{ .x = x, .y = y + menu_bar, .w = w, .h = h - menu_bar },
        .main = main,
    };
}

const commands = [_][]const u8{
    "focus west",         "focus south",                "focus north",
    "focus east",         "swap west",                  "swap south",
    "swap north",         "swap east",                  "warp west",
    "warp south",         "warp north",                 "warp east",
    "insert west",        "insert south",               "resize left -20",
    "resize right 20",    "resize top 20",              "resize bottom -20",
    "resize width 50",    "resize height -50",          "balance",
    "retile",             "rotate 90",                  "rotate 270",
    "mirror x-axis",      "mirror y-axis",              "toggle split",
    "toggle float",       "toggle zoom-parent",         "toggle zoom-fullscreen",
    "toggle sticky",      "toggle gaps",                "workspace 1",
    "workspace 2",        "workspace 3",                "workspace 4",
    "workspace next",     "workspace prev",             "workspace recent",
    "workspace new",      "send 1",                     "send 2",
    "send 3 --follow",    "send next --follow",         "send recent",
    "focus-monitor next", "focus-monitor prev",         "focus-monitor recent",
    "focus-monitor 1",    "send-monitor next --follow", "send-monitor 2",
    "grid 1:2:0:0:1:1",   "grid 4:4:1:1:2:2",           "move-floating 20 0",
    "layout bsp",         "layout float",               "close",
    "close-others",       "query windows",              "query workspaces",
    "query monitors",     "query stats",                "query focus",
    "workspace 2",
};

pub const Simulator = struct {
    options: Options,
    prng: stdx.Prng,
    engine: *Engine,
    now_ms: u64,
    windows: [windows_max]SimWindow,
    apps: [apps_max]SimApp,
    monitors: []const MonitorInfo,
    focused: WindowId,
    queue: [queue_max]Queued,
    queue_count: u32,
    seq: u64,
    window_id_next: WindowId,
    pid_next: i32,
    tab_group_next: u32,
    delivered: u64,
    frames_set: u64,
    settles: u64,

    pub fn init(simulator: *Simulator, engine: *Engine, options: Options) void {
        simulator.options = options;
        simulator.prng = stdx.Prng.init(options.seed);
        simulator.engine = engine;
        simulator.now_ms = 1000;
        for (&simulator.windows) |*window| window.* = .{};
        for (&simulator.apps) |*app| app.* = .{};
        simulator.monitors = monitor_presets[0];
        simulator.focused = 0;
        simulator.queue_count = 0;
        simulator.seq = 0;
        simulator.window_id_next = 100;
        simulator.pid_next = 500;
        simulator.tab_group_next = 1;
        simulator.delivered = 0;
        simulator.frames_set = 0;
        simulator.settles = 0;
        simulator.step(.{ .monitors_changed = simulator.monitors });
    }

    // Queue.

    fn push(simulator: *Simulator, delay_ms: u64, entry: Queued) void {
        assert(simulator.queue_count < queue_max);
        var queued = entry;
        queued.at_ms = simulator.now_ms + delay_ms;
        queued.seq = simulator.seq;
        simulator.seq += 1;
        simulator.queue[simulator.queue_count] = queued;
        simulator.queue_count += 1;
    }

    fn jitter(simulator: *Simulator, max_ms: u32) u64 {
        if (!simulator.options.faults) return 0;
        return simulator.prng.below(max_ms + 1);
    }

    fn queue_next_at(simulator: *const Simulator) ?u64 {
        var earliest: ?u64 = null;
        for (simulator.queue[0..simulator.queue_count]) |*entry| {
            if (earliest == null or entry.at_ms < earliest.?) earliest = entry.at_ms;
        }
        return earliest;
    }

    fn pop_due(simulator: *Simulator) ?Queued {
        var best: ?u32 = null;
        for (simulator.queue[0..simulator.queue_count], 0..) |*entry, index| {
            if (entry.at_ms > simulator.now_ms) continue;
            if (best) |current| {
                const other = &simulator.queue[current];
                const earlier = entry.at_ms < other.at_ms or
                    (entry.at_ms == other.at_ms and entry.seq < other.seq);
                if (!earlier) continue;
            }
            best = @intCast(index);
        }
        const index = best orelse return null;
        const entry = simulator.queue[index];
        simulator.queue_count -= 1;
        simulator.queue[index] = simulator.queue[simulator.queue_count];
        return entry;
    }

    // Lookups.

    pub fn window_find(simulator: *Simulator, id: WindowId) ?*SimWindow {
        if (id == 0) return null;
        for (&simulator.windows) |*window| {
            if (window.id == id) return window;
        }
        return null;
    }

    fn app_find(simulator: *Simulator, pid: i32) ?*SimApp {
        for (&simulator.apps) |*app| {
            if (app.pid == pid and pid != 0) return app;
        }
        return null;
    }

    fn app_responsive(simulator: *Simulator, pid: i32) bool {
        const app = simulator.app_find(pid) orelse return false;
        return simulator.now_ms >= app.unresponsive_until_ms;
    }

    fn window_random(simulator: *Simulator) ?*SimWindow {
        var count: u32 = 0;
        for (&simulator.windows) |*window| count += @intFromBool(window.id != 0);
        if (count == 0) return null;
        var pick = simulator.prng.below(count);
        for (&simulator.windows) |*window| {
            if (window.id == 0) continue;
            if (pick == 0) return window;
            pick -= 1;
        }
        unreachable;
    }

    /// Another window of the same tab group, preferably the one the engine shows.
    fn tab_peer(simulator: *Simulator, window: *const SimWindow) WindowId {
        if (window.tab_group == 0) return 0;
        for (&simulator.windows) |*other| {
            if (other.id != 0 and other.id != window.id and other.tab_group == window.tab_group) {
                return other.id;
            }
        }
        return 0;
    }

    // The engine side: deliver an event, perform its effects, check invariants.

    fn step(simulator: *Simulator, event: engine_module.Event) void {
        const effects = simulator.engine.step(event, simulator.now_ms);
        if (trace) trace_step(simulator, event, effects);
        var sets_per_window: [windows_max]u8 = @splat(0);
        for (effects) |effect| {
            switch (effect) {
                .set_frame => |set| {
                    // No window is ever sent more than two frames for one event.
                    for (&simulator.windows, 0..) |*window, index| {
                        if (window.id != set.id) continue;
                        sets_per_window[index] += 1;
                        assert(sets_per_window[index] <= 2);
                    }
                    simulator.perform_set_frame(set.id, set.frame);
                },
                .focus_window => |focus| simulator.perform_focus(focus.id),
                .close_window => |close| simulator.window_close(close.id),
                .query_focus => simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .focus_report }),
                .warp_mouse, .exec, .reload, .quit => {},
            }
        }
        simulator.delivered += 1;
        simulator.engine.verify();
    }

    fn perform_set_frame(simulator: *Simulator, id: WindowId, frame: Rect) void {
        simulator.frames_set += 1;
        const window = simulator.window_find(id) orelse return; // Already gone.
        if (!simulator.app_responsive(window.pid)) {
            simulator.push(
                0,
                .{ .at_ms = 0, .seq = 0, .kind = .app_unresponsive, .pid = window.pid },
            );
            return;
        }
        const target: Rect = .{
            .x = frame.x,
            .y = frame.y,
            .w = @max(frame.w, window.min_w),
            .h = @max(frame.h, window.min_h),
        };
        // The shell reads the frame back right after setting it, before any notification
        // about the change can arrive; an animating window is only part of the way there.
        var result = target;
        if (window.animates and !target.eql(window.frame)) {
            window.animation += 1;
            const from = window.frame;
            result = .{
                .x = @divTrunc(from.x + target.x, 2),
                .y = @divTrunc(from.y + target.y, 2),
                .w = @divTrunc(from.w + target.w, 2),
                .h = @divTrunc(from.h + target.h, 2),
            };
            simulator.push(20 + simulator.jitter(80), .{
                .at_ms = 0,
                .seq = 0,
                .kind = .animation_end,
                .id = id,
                .frame = target,
                .token = window.animation,
            });
        }
        simulator.push(
            0,
            .{ .at_ms = 0, .seq = 0, .kind = .frame_applied, .id = id, .frame = result },
        );
        simulator.frame_assign(window, result);
        if (window.stubborn) {
            simulator.push(
                10 + simulator.jitter(70),
                .{ .at_ms = 0, .seq = 0, .kind = .self_move, .id = id },
            );
        }
    }

    /// Sets the frame of a window and of its tab group, and queues the notifications.
    fn frame_assign(simulator: *Simulator, window: *SimWindow, frame: Rect) void {
        assert(frame.w > 0 and frame.h > 0);
        for (&simulator.windows) |*other| {
            const grouped = window.tab_group != 0 and other.tab_group == window.tab_group;
            if (other.id == 0 or (other != window and !grouped)) continue;
            if (other.frame.eql(frame)) continue;
            other.frame = frame;
            simulator.push(
                simulator.jitter(40),
                .{ .at_ms = 0, .seq = 0, .kind = .frame_changed, .id = other.id },
            );
        }
    }

    fn perform_focus(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        if (window.minimized or !simulator.app_responsive(window.pid)) return;
        simulator.focus_set(id);
    }

    fn focus_set(simulator: *Simulator, id: WindowId) void {
        if (simulator.focused == id) return;
        simulator.focused = id;
        simulator.push(simulator.jitter(30), .{ .at_ms = 0, .seq = 0, .kind = .focused });
    }

    fn window_info(simulator: *Simulator, window: *const SimWindow) engine_module.WindowInfo {
        return .{
            .id = window.id,
            .pid = window.pid,
            .title = window.title,
            .frame = window.frame,
            .kind = window.kind,
            .resizable = window.resizable,
            .minimized = window.minimized,
            .tab_of = simulator.tab_peer(window),
            .adopted = window.adopted,
        };
    }

    fn deliver(simulator: *Simulator, entry: Queued) void {
        switch (entry.kind) {
            .appeared => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(.{ .window_appeared = simulator.window_info(window) });
            },
            .destroyed => simulator.step(.{ .window_destroyed = entry.id }),
            .frame_applied => simulator.step(.{
                .window_frame_applied = .{ .id = entry.id, .frame = entry.frame },
            }),
            .frame_changed => {
                // Like the real shell, report the frame as it is now, not as it was.
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(.{ .window_frame_changed = .{
                    .id = entry.id,
                    .frame = window.frame,
                    .by_user = entry.flag,
                } });
            },
            .title_changed => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(
                    .{ .window_title_changed = .{ .id = entry.id, .title = window.title } },
                );
            },
            .minimized => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(
                    .{ .window_minimized = .{ .id = entry.id, .minimized = window.minimized } },
                );
            },
            .tab_changed => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(.{ .window_tab_changed = .{
                    .id = entry.id,
                    .tab_of = simulator.tab_peer(window),
                } });
            },
            .focused => {
                simulator.flush_appeared(simulator.focused);
                simulator.step(.{ .window_focused = simulator.focused });
            },
            .focus_report => {
                simulator.flush_appeared(simulator.focused);
                simulator.step(.{ .focus_reported = simulator.focused });
            },
            .app_launched => {
                const app = simulator.app_find(entry.pid) orelse return;
                simulator.step(.{
                    .app_launched = .{ .pid = app.pid, .name = app.name, .bundle = app.bundle },
                });
            },
            .app_terminated => simulator.step(.{ .app_terminated = entry.pid }),
            .app_unresponsive => simulator.step(.{ .app_unresponsive = entry.pid }),
            .self_move => {
                const window = simulator.window_find(entry.id) orelse return;
                if (!window.stubborn or window.minimized) return;
                simulator.frame_assign(window, window.home);
            },
            .animation_end => {
                const window = simulator.window_find(entry.id) orelse return;
                if (window.animation == entry.token) simulator.frame_assign(window, entry.frame);
            },
            .late_title => {
                const window = simulator.window_find(entry.id) orelse return;
                window.title = "Tempo Wallet";
                const kind: QueuedKind = .title_changed;
                simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = kind, .id = entry.id });
            },
        }
    }

    /// Delivers everything that is due, including engine ticks.
    fn drain(simulator: *Simulator) u32 {
        var events: u32 = 0;
        while (true) : (events += 1) {
            assert(events < settle_events_max);
            if (simulator.pop_due()) |entry| {
                simulator.deliver(entry);
                continue;
            }
            const deadline = simulator.engine.next_deadline_ms() orelse break;
            if (deadline > simulator.now_ms) break;
            simulator.step(.tick);
            // A tick must make progress, or the real timer would spin.
            const after = simulator.engine.next_deadline_ms();
            assert(after == null or after.? > simulator.now_ms);
        }
        return events;
    }

    /// The shell reports a window before it reports focus on it; so does the simulator.
    fn flush_appeared(simulator: *Simulator, id: WindowId) void {
        for (simulator.queue[0..simulator.queue_count], 0..) |entry, index| {
            if (entry.kind != .appeared or entry.id != id) continue;
            simulator.queue_count -= 1;
            simulator.queue[index] = simulator.queue[simulator.queue_count];
            simulator.deliver(entry);
            return;
        }
    }

    // The world side: what users and applications do.

    pub const WindowOptions = struct {
        title: []const u8 = "Untitled",
        frame: ?Rect = null,
        kind: engine_module.WindowKind = .standard,
        resizable: bool = true,
        min_w: i32 = 1,
        min_h: i32 = 1,
        stubborn: bool = false,
        animates: bool = false,
        tab_of: WindowId = 0,
        late_title: bool = false,
        focus: bool = true,
        /// Reported as a window that was open before the window manager started.
        adopted: bool = false,
    };

    pub fn app_launch(simulator: *Simulator, name: []const u8, bundle: []const u8) i32 {
        for (&simulator.apps) |*app| {
            if (app.pid != 0) continue;
            app.* = .{ .pid = simulator.pid_next, .name = name, .bundle = bundle };
            simulator.pid_next += 1;
            simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .app_launched, .pid = app.pid });
            return app.pid;
        }
        return 0;
    }

    pub fn window_open(simulator: *Simulator, pid: i32, options: WindowOptions) WindowId {
        assert(simulator.app_find(pid) != null);
        var slot: ?*SimWindow = null;
        for (&simulator.windows) |*window| {
            if (window.id == 0 and slot == null) slot = window;
        }
        const window = slot orelse return 0;
        var frame = options.frame orelse simulator.frame_random(options.min_w, options.min_h);
        var group: u32 = 0;
        var min_w = options.min_w;
        var min_h = options.min_h;
        var animates = options.animates;
        if (simulator.window_find(options.tab_of)) |peer| {
            assert(peer.pid == pid);
            if (peer.tab_group == 0) {
                peer.tab_group = simulator.tab_group_next;
                simulator.tab_group_next += 1;
            }
            // Tabs are one native window frame: they share its geometry and its limits.
            group = peer.tab_group;
            frame = peer.frame;
            min_w = peer.min_w;
            min_h = peer.min_h;
            animates = peer.animates;
            peer.stubborn = false;
        }
        window.* = .{
            .id = simulator.window_id_next,
            .pid = pid,
            .frame = frame,
            .home = frame,
            .min_w = min_w,
            .min_h = min_h,
            .kind = options.kind,
            .resizable = options.resizable,
            .stubborn = options.stubborn and group == 0,
            .animates = animates,
            .tab_group = group,
            .title = options.title,
            .adopted = options.adopted,
        };
        simulator.window_id_next += 1;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .appeared, .id = window.id },
        );
        if (options.late_title) {
            simulator.push(900, .{ .at_ms = 0, .seq = 0, .kind = .late_title, .id = window.id });
        }
        if (options.focus) simulator.focus_set(window.id);
        return window.id;
    }

    fn frame_random(simulator: *Simulator, min_w: i32, min_h: i32) Rect {
        const prng = &simulator.prng;
        return .{
            .x = prng.range(0, 1200),
            .y = prng.range(40, 600),
            .w = @max(min_w, prng.range(200, 1400)),
            .h = @max(min_h, prng.range(150, 900)),
        };
    }

    /// After the focused window went away macOS focuses a tab peer, then a window of the
    /// same application, then anything.
    fn focus_fallback(simulator: *Simulator, pid: i32, group: u32) void {
        var next: WindowId = 0;
        var rank_best: u32 = 0;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.minimized) continue;
            const rank: u32 = if (group != 0 and window.tab_group == group)
                3
            else if (window.pid == pid)
                2
            else
                1;
            if (rank > rank_best) {
                rank_best = rank;
                next = window.id;
            }
        }
        simulator.focused = 0;
        if (next != 0) {
            simulator.focus_set(next);
        } else {
            simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .focused });
        }
    }

    pub fn window_close(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        const pid = window.pid;
        const group = window.tab_group;
        window.* = .{};
        simulator.tab_group_shrink(group);
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .destroyed, .id = id },
        );
        if (simulator.focused == id) simulator.focus_fallback(pid, group);
    }

    /// A tab group with a single window left is just a window.
    fn tab_group_shrink(simulator: *Simulator, group: u32) void {
        if (group == 0) return;
        var count: u32 = 0;
        var last: ?*SimWindow = null;
        for (&simulator.windows) |*window| {
            if (window.id != 0 and window.tab_group == group) {
                count += 1;
                last = window;
            }
        }
        if (count != 1) return;
        last.?.tab_group = 0;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .tab_changed, .id = last.?.id },
        );
    }

    pub fn app_quit(simulator: *Simulator, pid: i32) void {
        const app = simulator.app_find(pid) orelse return;
        var focus_lost = false;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.pid != pid) continue;
            if (simulator.focused == window.id) focus_lost = true;
            // The destroyed notification of a dying application may or may not arrive.
            if (simulator.prng.chance(1, 2)) {
                simulator.push(
                    simulator.jitter(20),
                    .{ .at_ms = 0, .seq = 0, .kind = .destroyed, .id = window.id },
                );
            }
            window.* = .{};
        }
        app.* = .{};
        simulator.push(
            simulator.jitter(30),
            .{ .at_ms = 0, .seq = 0, .kind = .app_terminated, .pid = pid },
        );
        if (focus_lost) simulator.focus_fallback(0, 0);
    }

    /// The application stops answering Accessibility calls for a while.
    pub fn app_hang(simulator: *Simulator, pid: i32, ms: u64) void {
        simulator.app_find(pid).?.unresponsive_until_ms = simulator.now_ms + ms;
    }

    pub fn window_click(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        if (!window.minimized) simulator.focus_set(id);
    }

    /// The user drags or resizes a window with the mouse.
    pub fn window_drag(simulator: *Simulator, id: WindowId, frame: Rect) void {
        const window = simulator.window_find(id) orelse return;
        if (window.minimized) return;
        simulator.frame_assign_by(window, frame, true);
    }

    fn frame_assign_by(simulator: *Simulator, window: *SimWindow, frame: Rect, by_user: bool) void {
        const before = simulator.queue_count;
        simulator.frame_assign(window, frame);
        for (simulator.queue[before..simulator.queue_count]) |*entry| entry.flag = by_user;
    }

    pub fn window_minimize(simulator: *Simulator, id: WindowId, minimized: bool) void {
        const window = simulator.window_find(id) orelse return;
        if (window.minimized == minimized) return;
        window.minimized = minimized;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .minimized, .id = id },
        );
        if (!minimized) {
            simulator.focus_set(id);
        } else if (simulator.focused == id) {
            simulator.focus_fallback(window.pid, window.tab_group);
        }
    }

    pub fn window_title(simulator: *Simulator, id: WindowId, title: []const u8) void {
        const window = simulator.window_find(id) orelse return;
        window.title = title;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .title_changed, .id = id },
        );
    }

    pub fn tab_detach(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        if (window.tab_group == 0) return;
        const group = window.tab_group;
        window.tab_group = 0;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .tab_changed, .id = id },
        );
        simulator.tab_group_shrink(group);
        simulator.frame_assign(window, simulator.frame_random(window.min_w, window.min_h));
    }

    pub fn monitors_set(simulator: *Simulator, preset: u32) void {
        simulator.monitors = monitor_presets[preset];
        simulator.step(.{ .monitors_changed = simulator.monitors });
    }

    pub fn command_run(simulator: *Simulator, text: []const u8) void {
        var pool: command.StringPool = .{};
        const parsed = command.parse(text, &pool) catch unreachable;
        simulator.step(.{ .command = parsed });
    }

    pub fn advance(simulator: *Simulator, ms: u64) void {
        simulator.now_ms += ms;
        _ = simulator.drain();
    }

    // The random workload.

    fn action(simulator: *Simulator) void {
        const prng = &simulator.prng;
        const faults = simulator.options.faults;
        const roll = prng.below(100);
        const window = simulator.window_random();
        const id: WindowId = if (window) |w| w.id else 0;
        switch (roll) {
            0...39 => simulator.command_run(commands[prng.below(commands.len)]),
            40...51 => simulator.action_open(),
            52...57 => simulator.window_close(id),
            58...60 => {
                const template = app_templates[prng.below(app_templates.len)];
                _ = simulator.app_launch(template.name, template.bundle);
            },
            61 => if (window) |w| simulator.app_quit(w.pid),
            62...69 => simulator.window_click(id),
            70...75 => if (window) |w| {
                var frame = simulator.frame_random(w.min_w, w.min_h);
                if (prng.chance(1, 2)) {
                    frame.w = w.frame.w;
                    frame.h = w.frame.h;
                }
                simulator.window_drag(id, frame);
            },
            76...78 => if (window) |w| {
                if (!w.minimized) {
                    simulator.frame_assign(w, simulator.frame_random(w.min_w, w.min_h));
                }
            },
            79...81 => if (window) |w| simulator.window_minimize(id, !w.minimized),
            82...84 => simulator.window_title(id, titles[prng.below(titles.len)]),
            85...86 => simulator.tab_detach(id),
            87...89 => if (window) |w| {
                if (faults) {
                    const app = simulator.app_find(w.pid).?;
                    app.unresponsive_until_ms = simulator.now_ms + 100 + prng.below(3000);
                }
            },
            90...91 => simulator.monitors_set(prng.below(monitor_presets.len)),
            92...94 => if (faults) simulator.action_spurious(id),
            else => simulator.now_ms += 200,
        }
    }

    fn action_open(simulator: *Simulator) void {
        const prng = &simulator.prng;
        const faults = simulator.options.faults;
        var apps_count: u32 = 0;
        for (&simulator.apps) |*app| apps_count += @intFromBool(app.pid != 0);
        if (apps_count == 0) {
            _ = simulator.app_launch(app_templates[0].name, app_templates[0].bundle);
            return;
        }
        var pick = prng.below(apps_count);
        var pid: i32 = 0;
        for (&simulator.apps) |*app| {
            if (app.pid == 0) continue;
            if (pick == 0) pid = app.pid;
            pick -%= 1;
        }
        assert(pid != 0);
        var peer: WindowId = 0;
        for (&simulator.windows) |*window| {
            if (window.id != 0 and window.pid == pid and window.kind == .standard) peer = window.id;
        }
        const kind_roll = prng.below(100);
        const constrained = faults and prng.chance(1, 4);
        _ = simulator.window_open(pid, .{
            .title = titles[prng.below(titles.len)],
            .kind = if (kind_roll < 85) .standard else if (kind_roll < 95) .dialog else .popup,
            .resizable = prng.chance(92, 100),
            .min_w = if (constrained) prng.range(300, 900) else 1,
            .min_h = if (constrained) prng.range(300, 700) else 1,
            .stubborn = faults and prng.chance(6, 100),
            .animates = faults and prng.chance(12, 100),
            .tab_of = if (kind_roll < 85 and prng.chance(15, 100)) peer else 0,
            .late_title = prng.chance(1, 5),
            .focus = prng.chance(9, 10),
            .adopted = prng.chance(1, 10),
        });
    }

    /// Notifications that are late, duplicated or about things that no longer exist.
    fn action_spurious(simulator: *Simulator, id: WindowId) void {
        switch (simulator.prng.below(6)) {
            0 => simulator.push(
                simulator.jitter(50),
                .{ .at_ms = 0, .seq = 0, .kind = .frame_changed, .id = id },
            ),
            1 => simulator.push(simulator.jitter(50), .{ .at_ms = 0, .seq = 0, .kind = .focused }),
            2 => simulator.step(.{ .window_destroyed = 999_999 }),
            3 => simulator.step(.{
                .window_frame_applied = .{ .id = 999_999, .frame = Rect.zero },
            }),
            4 => simulator.step(.{ .app_unresponsive = 77 }),
            else => simulator.step(.tick),
        }
    }

    pub fn run(simulator: *Simulator, steps: u32) void {
        var index: u32 = 0;
        while (index < steps) : (index += 1) {
            simulator.now_ms += simulator.prng.below(60);
            _ = simulator.drain();
            simulator.action();
            if (index % 97 == 96) simulator.settle();
        }
        simulator.settle();
        simulator.teardown();
    }

    /// Lets every pending event and timer play out, then checks that the engine and the
    /// simulated OS agree. Asserts that this takes a bounded number of events.
    pub fn settle(simulator: *Simulator) void {
        for (&simulator.apps) |*app| app.unresponsive_until_ms = 0;
        var events: u32 = 0;
        while (true) {
            events += simulator.drain();
            assert(events < settle_events_max);
            const queue_at = simulator.queue_next_at();
            const deadline = simulator.engine.next_deadline_ms();
            if (queue_at == null and deadline == null) break;
            const next =
                @min(queue_at orelse std.math.maxInt(u64), deadline orelse std.math.maxInt(u64));
            assert(next > simulator.now_ms);
            simulator.now_ms = next;
        }
        simulator.settles += 1;
        simulator.check_agreement();
    }

    fn check_agreement(simulator: *Simulator) void {
        const engine = simulator.engine;
        var tracked: u32 = 0;
        for (&simulator.windows) |*window| {
            if (window.id == 0) continue;
            if (window.kind == .popup) {
                assert(engine.window_find(window.id) == null);
                continue;
            }
            const known = engine.window_find(window.id).?;
            tracked += 1;
            // The engine's picture of the world is the world.
            assert(known.actual.eql(window.frame));
            assert(known.minimized == window.minimized);
            if (!known.managed() or engine.monitors_count == 0) continue;
            assert(known.desired_valid);
            assert(!known.set_pending);
            if (known.frozen or window.stubborn) continue;
            // Every window is where it should be, as far as its minimum size allows.
            const expected: Rect = .{
                .x = known.desired.x,
                .y = known.desired.y,
                .w = @max(known.desired.w, window.min_w),
                .h = @max(known.desired.h, window.min_h),
            };
            if (!window.frame.eql(expected)) simulator.report(window, known, expected);
            assert(window.frame.eql(expected));
            if (!engine.workspace_visible(known.workspace)) {
                // Hidden windows show at most a one pixel sliver on their monitor.
                const own = engine.monitors[engine.workspace_monitor(known.workspace)].frame;
                assert(window.frame.overlap(own, .x) <= 1 or window.frame.overlap(own, .y) <= 1);
            }
        }
        var engine_windows: u32 = 0;
        for (&engine.windows) |*known| engine_windows += @intFromBool(known.id != 0);
        assert(engine_windows == tracked);
        simulator.check_focus();
    }

    fn report(
        simulator: *Simulator,
        window: *const SimWindow,
        known: *const engine_module.Window,
        expected: Rect,
    ) void {
        std.debug.print(
            "seed {d}: window {d} is at {d},{d} {d}x{d}, expected {d},{d} {d}x{d}\n" ++
                "  workspace={d} visible={} mode={s} zoom={s} attempts={d} min={d}x{d} " ++
                "animates={} group={d}\n",
            .{
                simulator.options.seed, window.id,
                window.frame.x,         window.frame.y,
                window.frame.w,         window.frame.h,
                expected.x,             expected.y,
                expected.w,             expected.h,
                known.workspace + 1,    simulator.engine.workspace_visible(known.workspace),
                @tagName(known.mode),   @tagName(known.zoom),
                known.attempts,         window.min_w,
                window.min_h,           window.animates,
                window.tab_group,
            },
        );
    }

    fn check_focus(simulator: *Simulator) void {
        const engine = simulator.engine;
        const known = engine.window_find(simulator.focused) orelse return;
        if (!known.focusable()) return;
        if (engine.focused_window == known.id) return;
        // The only excuses for disagreeing with the OS: the engine deliberately holds no
        // focus, because the OS-focused window is on a hidden workspace or because the
        // user moved to a monitor that has no windows.
        assert(engine.focused_window == 0);
        if (engine.monitors_count == 0) return;
        const hidden = !engine.workspace_visible(known.workspace);
        const elsewhere = engine.workspace_monitor(known.workspace) != engine.focused_monitor;
        if (!hidden and !elsewhere) {
            std.debug.print("seed {d}: focus lost: os={d} workspace={d} monitor={d} stale={}\n", .{
                simulator.options.seed, known.id,           known.workspace + 1,
                engine.focused_monitor, engine.focus_stale,
            });
        }
        assert(hidden or elsewhere);
    }

    /// Closes everything and checks that nothing leaked.
    fn teardown(simulator: *Simulator) void {
        for (&simulator.windows) |*window| {
            if (window.id != 0) simulator.window_close(window.id);
        }
        simulator.settle();
        for (&simulator.engine.windows) |*known| assert(known.id == 0);
        assert(simulator.engine.forest.free_count == @import("tree.zig").nodes_max);
        assert(simulator.engine.focused_window == 0);
    }
};

fn trace_step(
    simulator: *Simulator,
    event: engine_module.Event,
    effects: []const engine_module.Effect,
) void {
    std.debug.print("{d:>8} ", .{simulator.now_ms});
    switch (event) {
        .window_appeared => |e| std.debug.print(
            "appeared {d} pid={d} tab_of={d} kind={s}",
            .{ e.id, e.pid, e.tab_of, @tagName(e.kind) },
        ),
        .window_destroyed => |id| std.debug.print("destroyed {d}", .{id}),
        .window_frame_applied => |e| std.debug.print(
            "applied {d} {d},{d} {d}x{d}",
            .{ e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h },
        ),
        .window_frame_changed => |e| std.debug.print(
            "changed {d} {d},{d} {d}x{d} user={}",
            .{ e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h, e.by_user },
        ),
        .window_focused => |id| std.debug.print("focused {d}", .{id}),
        .focus_reported => |id| std.debug.print("focus-report {d}", .{id}),
        .window_minimized => |e| std.debug.print("minimized {d} {}", .{ e.id, e.minimized }),
        .window_tab_changed => |e| std.debug.print("tab {d} of {d}", .{ e.id, e.tab_of }),
        .window_title_changed => |e| std.debug.print("title {d} {s}", .{ e.id, e.title }),
        .app_launched => |e| std.debug.print("launched {d} {s}", .{ e.pid, e.name }),
        .app_terminated => |pid| std.debug.print("terminated {d}", .{pid}),
        .app_unresponsive => |pid| std.debug.print("unresponsive {d}", .{pid}),
        .monitors_changed => |list| std.debug.print("monitors {d}", .{list.len}),
        .command => |cmd| std.debug.print("command {s}", .{@tagName(cmd)}),
        else => std.debug.print("{s}", .{@tagName(event)}),
    }
    const engine = simulator.engine;
    const shown: u32 = if (engine.monitors_count > 0) engine.workspace_current() + 1 else 0;
    std.debug.print("  [focus={d} os={d} monitor={d} workspace={d}]\n", .{
        engine.focused_window, simulator.focused, engine.focused_monitor, shown,
    });
    for (effects) |effect| {
        switch (effect) {
            .set_frame => |e| std.debug.print(
                "           -> set {d} {d},{d} {d}x{d}\n",
                .{ e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h },
            ),
            .focus_window => |e| std.debug.print("           -> focus {d}\n", .{e.id}),
            else => std.debug.print("           -> {s}\n", .{@tagName(effect)}),
        }
    }
}

/// One full simulation run. Returns the number of events delivered.
pub fn run_seed(engine: *Engine, simulator: *Simulator, seed: u64, steps: u32, faults: bool) u64 {
    var config: config_module.Config = undefined;
    config.load_default();
    engine.init(&config);
    simulator.init(engine, .{ .seed = seed, .faults = faults });
    simulator.run(steps);
    return simulator.delivered;
}

var test_engine: Engine = undefined;
var test_simulator: Simulator = undefined;

test "simulation: a hundred seeds with faults" {
    var seed: u64 = 1;
    while (seed <= 100) : (seed += 1) {
        _ = run_seed(&test_engine, &test_simulator, seed, 600, true);
    }
}

test "simulation: is deterministic" {
    const first = run_seed(&test_engine, &test_simulator, 7, 800, true);
    const first_sets = test_simulator.frames_set;
    const second = run_seed(&test_engine, &test_simulator, 7, 800, true);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first_sets, test_simulator.frames_set);
}
