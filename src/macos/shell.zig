//! The macOS shell around the engine: it turns Accessibility notifications, Carbon hot keys
//! and display changes into engine events, and performs the effects the engine returns.
//! Everything runs on the main thread. No call here can block for longer than the
//! Accessibility timeout, and an application that hits it is suspended by the engine.
const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const ax = @import("ax.zig");
const ipc = @import("ipc.zig");
const border = @import("border.zig");
const stdx = @import("../stdx.zig");
const geometry = @import("../geometry.zig");
const command = @import("../command.zig");
const config_module = @import("../config.zig");
const engine_module = @import("../engine.zig");
const state_module = @import("../state.zig");

const Ref = c.Ref;
const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const Event = engine_module.Event;
const Effect = engine_module.Effect;

const followups_max: u32 = 2048;
const app_retries_max: u8 = 6;
const drag_poll_ms: u64 = 30;
const monitors_debounce_ms: u64 = 250;
const repeat_delay_ms: u64 = 300;
const repeat_interval_ms: u64 = 50;
/// A key held for longer than this many repeats is taken for stuck.
const repeats_max: u32 = 400;
const far_future_seconds: f64 = 3.0e9;
/// AppKit learns the new usable area of a display a moment after the Dock says it moved.
const usable_recheck_ms: u64 = 1500;
/// How far outside a window the pointer may be and still hold it by an edge.
const pointer_reach: i32 = 24;
/// A window that is not a real window yet when it is announced is looked at again.
const probes_max: u32 = 16;
const probe_delays_ms = [_]u64{ 150, 500, 1500 };
const state_debounce_ms: u64 = 2000;
const config_bytes_max: usize = 64 * 1024;
/// An application raises a window a moment after it is asked to, which puts the window
/// above its border: the border is ordered above it again after this long.
const border_reorder_ms: u64 = 120;
/// A click raises the window under it, even the focused one, which puts that window
/// above its border with no Accessibility notification to tell: the border is ordered
/// above it again this long after each mouse button goes down or up.
const border_click_reorder_ms: u64 = 40;

/// True while the applications that were already running are being picked up.
var adopting: bool = false;

const ShellApp = struct {
    pid: i32 = 0,
    element: Ref = null,
    observer: Ref = null,
    /// Applications are not ready for Accessibility the moment they launch.
    retry_at_ms: u64 = 0,
    retries: u8 = 0,
    ready: bool = false,
    /// Was running before we started: its windows stay on the monitor they are on.
    adopted: bool = false,
    /// Hidden with cmd-h: its windows are out of the layout like minimized ones.
    hidden: bool = false,
    /// The batch of effects in which its animations were last looked at, and whether
    /// they were switched off for it.
    enhanced_batch: u64 = 0,
    enhanced_off: bool = false,
    /// The batch of effects in which it did not answer. Nothing more is asked of it in
    /// that batch: the engine suspends it when it hears, and sends the frames again.
    hung_batch: u64 = 0,
};

/// A window that was announced before its application had made it a real window.
const Probe = struct {
    pid: i32 = 0,
    element: Ref = null,
    at_ms: u64 = 0,
    tries: u8 = 0,
};

const ShellWindow = struct {
    id: u32 = 0,
    pid: i32 = 0,
    element: Ref = null,
    /// Moved while a mouse button was down; reported once the button is released.
    dragging: bool = false,
};

/// Events that an effect leads to. They carry no slices, so they can wait in a queue while
/// the current batch of effects is performed.
const Followup = union(enum) {
    frame_applied: struct { id: u32, frame: Rect },
    app_unresponsive: i32,
    window_destroyed: u32,
    focus_reported: u32,
};

var engine: Engine = undefined;
var apps: [engine_module.apps_max]ShellApp = undefined;
var windows: [engine_module.windows_max]ShellWindow = undefined;
var followups: [followups_max]Followup = undefined;
var followups_head: u32 = 0;
var followups_count: u32 = 0;
var performing: [engine_module.effects_max]Effect = undefined;
var dispatching: bool = false;
var quit_requested: bool = false;
var timer: Ref = null;
var drag_poll_at_ms: u64 = 0;
var monitors_dirty_at_ms: u64 = 0;
var monitors_recheck_at_ms: u64 = 0;
var monitors_recheck_again: bool = false;
/// The usable area of some display was a guess, because AppKit did not know it yet.
var monitors_guessed: bool = false;
/// The displays changed, or may have while we could not see: tell the engine even when
/// they read the same as before, so that it puts every window back where it belongs.
var monitors_force: bool = false;
var monitors_seen: [engine_module.monitors_max]engine_module.MonitorInfo = undefined;
var monitors_seen_count: u32 = 0;
var probes: [probes_max]Probe = undefined;
/// What the tatami that ran before this one left behind.
var left: state_module.State = .{};
var state_dirty_at_ms: u64 = 0;
var state_revision: u64 = 0;
var state_written: [state_module.bytes_max]u8 = undefined;
var state_written_len: usize = 0;
var secure_input_on: bool = false;
var secure_input_explained = [2]bool{ false, false };
/// Counts the batches of effects; see ShellApp.enhanced_batch.
var batch: u64 = 0;
var repeat_at_ms: u64 = 0;
var repeat_binding: u32 = 0;
var repeat_count: u32 = 0;
var hot_keys: [config_module.bindings_max]Ref = undefined;
var hot_keys_count: u32 = 0;
/// The binding mode whose hot keys are registered. 0 is main.
var mode_current: u8 = 0;
var config_scratch: Config = undefined;
var config_bytes: [config_bytes_max]u8 = undefined;
var own_pid: i32 = 0;
var border_reorder_at_ms: u64 = 0;
var mouse_tap: Ref = null;
pub var verbose: bool = false;

const Config = config_module.Config;

extern "c" fn getpid() i32;

fn log(comptime format: []const u8, args: anytype) void {
    if (verbose) std.debug.print("tatami: " ++ format ++ "\n", args);
}

// Tables.

fn app_find(pid: i32) ?*ShellApp {
    if (pid == 0) return null;
    for (&apps) |*app| {
        if (app.pid == pid) return app;
    }
    return null;
}

fn window_find(id: u32) ?*ShellWindow {
    if (id == 0) return null;
    for (&windows) |*window| {
        if (window.id == id) return window;
    }
    return null;
}

fn window_forget(id: u32) void {
    const window = window_find(id) orelse return;
    c.CFRelease(window.element);
    window.* = .{};
}

// Dispatch: one event in, effects out, follow-up events until quiet.

fn followup_push(followup: Followup) void {
    if (followups_count == followups_max) return; // The engine heals from a lost report.
    followups[(followups_head + followups_count) % followups_max] = followup;
    followups_count += 1;
}

fn followup_pop() ?Followup {
    if (followups_count == 0) return null;
    const followup = followups[followups_head];
    followups_head = (followups_head + 1) % followups_max;
    followups_count -= 1;
    return followup;
}

fn dispatch(event: Event) void {
    assert(!dispatching);
    dispatching = true;
    process(event);
    var rounds: u32 = 0;
    while (followup_pop()) |followup| : (rounds += 1) {
        assert(rounds < 100_000);
        process(switch (followup) {
            .frame_applied => |applied| .{
                .window_frame_applied = .{ .id = applied.id, .frame = applied.frame },
            },
            .app_unresponsive => |pid| .{ .app_unresponsive = pid },
            .window_destroyed => |id| .{ .window_destroyed = id },
            .focus_reported => |id| .{ .focus_reported = id },
        });
    }
    dispatching = false;
    border_refresh(event != .tick);
    timer_rearm();
}

/// Puts the border around the focused window, or takes it away when that window does not
/// show: none has focus, it is minimized, hidden, in native fullscreen, on a workspace
/// that does not show, or being dragged.
fn border_refresh(reorder: bool) void {
    const config = &engine.config;
    const style = border.Style{
        .width = config.border_width,
        .radius = config.border_radius,
        .color = config.border_color,
    };
    const id = engine.focused_window;
    const target = if (id == 0) null else engine.window_find(id);
    const shows = if (target) |window|
        window.focusable() and !window.fullscreen and !app_hidden(window.pid) and
            (window.sticky or engine.workspace_visible(window.workspace)) and
            !(if (window_find(id)) |shell_window| shell_window.dragging else true)
    else
        false;
    if (!shows or style.width == 0) {
        border.hide();
        border_reorder_at_ms = 0;
        return;
    }
    const before = border.target_shown();
    border.show(id, target.?.actual, style, reorder);
    if (before != id) border_reorder_at_ms = c.now_ms() + border_reorder_ms;
}

fn process(event: Event) void {
    const started_us = c.now_us();
    batch += 1;
    const effects = engine.step(event, c.now_ms());
    const count = effects.len;
    @memcpy(performing[0..count], effects);
    if (ipc.followed()) notes_publish();
    if (verbose) trace_event(event);
    for (performing[0..count]) |effect| {
        const before_us = c.now_us();
        perform(effect);
        if (verbose) trace_effect(effect, c.now_us() - before_us);
    }
    enhanced_restore();
    if (engine.revision != state_revision and state_dirty_at_ms == 0 and !quit_requested) {
        state_dirty_at_ms = c.now_ms() + state_debounce_ms;
    }
    if (verbose and count > 0) log("   {d} effects in {d} us", .{ count, c.now_us() - started_us });
}

/// Tells whoever follows 'tatami events' what the step changed. Ids only, never titles.
fn notes_publish() void {
    for (engine.notes_slice()) |note| {
        const name = @tagName(note);
        const value: u64 = switch (note) {
            .window_created, .window_closed, .focus_changed, .title_changed => |id| id,
            .workspace_changed => |workspace| workspace,
            .view_changed => |revision| revision,
            .overflow => 0,
        };
        const key = switch (note) {
            .window_created, .window_closed, .focus_changed, .title_changed => "window",
            .workspace_changed => "workspace",
            .view_changed => "revision",
            .overflow => "",
        };
        var line_buffer: [96]u8 = undefined;
        var json_buffer: [128]u8 = undefined;
        var line = stdx.Text.init(&line_buffer);
        var json = stdx.Text.init(&json_buffer);
        if (note == .overflow) {
            line.print("{s}\n", .{name});
            json.print("{{\"type\":\"{s}\"}}\n", .{name});
        } else if (note == .focus_changed and value == 0) {
            line.print("{s}\t0\n", .{name});
            json.print("{{\"type\":\"{s}\",\"window\":null}}\n", .{name});
        } else {
            line.print("{s}\t{d}\n", .{ name, value });
            json.print("{{\"type\":\"{s}\",\"{s}\":{d}}}\n", .{ name, key, value });
        }
        ipc.publish(line.slice(), json.slice());
    }
}

/// Tells followers about a change that happens outside the engine.
fn event_publish(name: []const u8, mode: ?[]const u8) void {
    if (!ipc.followed()) return;
    var line_buffer: [96]u8 = undefined;
    var json_buffer: [128]u8 = undefined;
    var line = stdx.Text.init(&line_buffer);
    var json = stdx.Text.init(&json_buffer);
    json.print("{{\"type\":\"{s}\"", .{name});
    if (mode) |mode_name| {
        line.print("{s}\t{s}\n", .{ name, mode_name });
        json.append(",\"mode\":");
        json.json_string(mode_name);
    } else {
        line.print("{s}\n", .{name});
    }
    json.append("}\n");
    ipc.publish(line.slice(), json.slice());
}

/// One line per event for 'start --verbose'. Never prints window titles.
fn trace_event(event: Event) void {
    const at = c.now_ms() % 1_000_000;
    const focus = engine.focused_window;
    switch (event) {
        .window_appeared => |e| log("{d} appeared {d} pid={d} [focus={d}]", .{
            at, e.id, e.pid, focus,
        }),
        .window_destroyed => |id| log("{d} destroyed {d} [focus={d}]", .{ at, id, focus }),
        .window_frame_applied => |e| log("{d} applied {d} {d},{d} {d}x{d}", .{
            at, e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h,
        }),
        .window_frame_changed => |e| log("{d} changed {d} {d},{d} {d}x{d} user={}", .{
            at, e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h, e.by_user,
        }),
        .window_focused => |id| log("{d} focused {d} [focus={d}]", .{ at, id, focus }),
        .focus_reported => |id| log("{d} focus-report {d} [focus={d}]", .{ at, id, focus }),
        .window_tab_changed => |e| log("{d} tab {d} of {d}", .{ at, e.id, e.tab_of }),
        .app_launched => |e| log("{d} launched {d}", .{ at, e.pid }),
        .app_terminated => |pid| log("{d} terminated {d}", .{ at, pid }),
        .app_unresponsive => |pid| log("{d} unresponsive {d}", .{ at, pid }),
        .command => |cmd| log("{d} command {s} [focus={d}]", .{ at, @tagName(cmd), focus }),
        .tick => {},
        else => log("{d} {s}", .{ at, @tagName(event) }),
    }
}

fn trace_effect(effect: Effect, took_us: u64) void {
    switch (effect) {
        .set_frame => |e| log("   -> set {d} {d},{d} {d}x{d} ({d} us)", .{
            e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h, took_us,
        }),
        .focus_window => |e| log("   -> focus {d} pid={d} ({d} us)", .{ e.id, e.pid, took_us }),
        else => log("   -> {s} ({d} us)", .{ @tagName(effect), took_us }),
    }
}

fn perform(effect: Effect) void {
    switch (effect) {
        .set_frame => |set| perform_set_frame(set.id, set.pid, set.frame),
        .focus_window => |focus| perform_focus(focus.id, focus.pid),
        .close_window => |close| {
            const window = window_find(close.id) orelse return;
            const button = ax.copy(window.element, ax.names.close_button) catch return;
            defer c.CFRelease(button);
            _ = c.AXUIElementPerformAction(button, ax.names.press);
        },
        .warp_mouse => |area| perform_warp(area),
        .exec => |span| spawn(engine.config.strings.get(span)),
        .query_focus => {
            const id = focused_window_id(false);
            if (id != 0) followup_push(.{ .focus_reported = id });
        },
        .reload => config_load(true),
        .quit => {
            state_write();
            quit_requested = true;
        },
    }
}

fn perform_set_frame(id: u32, pid: i32, frame: Rect) void {
    const window = window_find(id) orelse {
        followup_push(.{ .window_destroyed = id });
        return;
    };
    if (app_find(pid)) |app| {
        // One timeout for an application that hangs, not one for each of its windows.
        // Not when quitting: nothing is sent again then, and a parked window would stay.
        const skip = !engine.stopped;
        if (skip and app.hung_batch == batch) return;
        enhanced_off(app);
        if (skip and app.hung_batch == batch) return followup_push(.{ .app_unresponsive = pid });
    }
    const move_only = if (engine.window_find(id)) |known|
        known.actual.w == frame.w and known.actual.h == frame.h
    else
        false;
    const applied = ax.frame_set(window.element, frame, move_only) catch |err| {
        switch (err) {
            error.Unresponsive => {
                if (app_find(pid)) |app| app.hung_batch = batch;
                followup_push(.{ .app_unresponsive = pid });
            },
            error.Invalid => {
                window_forget(id);
                followup_push(.{ .window_destroyed = id });
            },
            error.Failed => {},
        }
        return;
    };
    followup_push(.{ .frame_applied = .{ .id = id, .frame = applied } });
}

/// Applications driven by assistive software animate frame changes, slowly. That is
/// turned off around the changes, as yabai does: once for all the frames of a batch, not
/// around each one, since asking costs a round trip and switching makes some applications
/// rebuild their whole Accessibility tree.
fn enhanced_off(app: *ShellApp) void {
    if (app.enhanced_batch == batch) return;
    app.enhanced_batch = batch;
    const attribute = ax.names.enhanced_user_interface;
    const enhanced = ax.bool_get_checked(app.element, attribute) catch |err| {
        if (err == error.Unresponsive) app.hung_batch = batch;
        return;
    };
    if (!enhanced) return;
    ax.bool_set(app.element, attribute, false);
    app.enhanced_off = true;
}

fn enhanced_restore() void {
    for (&apps) |*app| {
        if (app.pid == 0 or !app.enhanced_off) continue;
        app.enhanced_off = false;
        ax.bool_set(app.element, ax.names.enhanced_user_interface, true);
    }
}

fn perform_focus(id: u32, pid: i32) void {
    const window = window_find(id) orelse return;
    const app = app_find(pid) orelse return;
    // An application that does not answer costs one timeout here, not three, and the
    // engine hears about it.
    if (app.hung_batch == batch) return;
    ax.bool_set_checked(window.element, ax.names.main, true) catch |err| switch (err) {
        error.Unresponsive => {
            app.hung_batch = batch;
            return followup_push(.{ .app_unresponsive = pid });
        },
        error.Invalid => {
            // Gone: said now, not found out when the focus is never confirmed.
            window_forget(id);
            return followup_push(.{ .window_destroyed = id });
        },
        error.Failed => {},
    };
    _ = c.AXUIElementPerformAction(window.element, ax.names.raise);
    ax.bool_set(app.element, ax.names.frontmost, true);
}

fn perform_warp(area: Rect) void {
    const event = c.CGEventCreate(null);
    if (event == null) return;
    defer c.CFRelease(event);
    const location = c.CGEventGetLocation(event);
    const x: i32 = @intFromFloat(@round(location.x));
    const y: i32 = @intFromFloat(@round(location.y));
    if (area.contains_point(x, y)) return;
    _ = c.CGWarpMouseCursorPosition(.{
        .x = @floatFromInt(area.center_x()),
        .y = @floatFromInt(area.center_y()),
    });
}

/// Runs a shell command detached from us. We never wait for it.
fn spawn(text: []const u8) void {
    var buffer: [2048]u8 = undefined;
    if (text.len == 0 or text.len >= buffer.len) return;
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    const pid = c.fork();
    if (pid != 0) return;
    _ = c.setsid();
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", @ptrCast(&buffer), null };
    _ = c.execv("/bin/sh", &argv);
    c._exit(127);
}

// Focus.

/// The window that has keyboard focus according to the OS, or 0. With discover set, a
/// focused window we have not seen yet is reported to the engine first.
fn focused_window_id(discover: bool) u32 {
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const workspace = c.send(c.objc_getClass("NSWorkspace"), "sharedWorkspace");
    const front = c.send(workspace, "frontmostApplication");
    if (front == null) return 0;
    const pid: i32 = @intCast(c.send_integer(front, "processIdentifier"));
    const app = app_find(pid) orelse return 0;
    if (!app.ready) return 0;
    const element = ax.copy(app.element, ax.names.focused_window) catch return 0;
    defer c.CFRelease(element);
    const id = ax.window_id(element);
    if (id == 0) return 0;
    if (window_find(id) == null and discover) _ = window_discover(app, element);
    if (window_find(id) == null) return 0;
    return id;
}

fn focus_notify() void {
    const id = focused_window_id(true);
    if (id == 0) return;
    focus_left_check(id);
    tabs_check(id);
    dispatch(.{ .window_focused = id });
}

/// macOS reports a window that closed and the focus that moved on in either order. When
/// focus arrives on a workspace that is not in view, the window that had it is asked
/// first whether it is still there, so that the engine can tell macOS choosing the next
/// window after a close from the user going to that workspace.
fn focus_left_check(id: u32) void {
    const previous = engine.focused_window;
    if (previous == 0 or previous == id or engine.monitors_count == 0) return;
    const next = engine.window_find(id) orelse return;
    if (engine.workspace_visible(next.workspace)) return;
    const window = window_find(previous) orelse return;
    if (!ax.alive(window.element)) {
        window_forget(previous);
        return dispatch(.{ .window_destroyed = previous });
    }
    // The same for cmd-h: the notice that the application was hidden can come after
    // the focus that macOS moved on because of it.
    const app = app_find(window.pid) orelse return;
    if (!app.hidden and ax.bool_get(app.element, ax.names.hidden)) app_hidden_set(app, true);
}

/// Native tabs: when the focused window sits exactly where another window of the same
/// application sat, and that one is no longer on screen, they are tabs of each other.
fn tabs_check(focused_id: u32) void {
    const focused = window_find(focused_id) orelse return;
    if (app_hidden(focused.pid)) return;
    const frame = ax.frame_get(focused.element) catch return;
    for (&windows) |*other| {
        if (other.id == 0 or other.id == focused_id or other.pid != focused.pid) continue;
        const known = engine.window_find(other.id) orelse continue;
        if (known.tab_of != 0 or known.minimized) continue;
        if (!known.actual.eql(frame)) continue;
        if (ax.on_screen(other.id)) continue;
        dispatch(.{ .window_tab_changed = .{ .id = other.id, .tab_of = focused_id } });
    }
}

// Windows.

const Discovery = enum { tracked, not_a_window, failed };

fn window_discover(app: *ShellApp, element: Ref) Discovery {
    const id = ax.window_id(element);
    if (id == 0) return .not_a_window;
    if (window_find(id) != null) return .tracked;
    const kind = ax.window_kind(element) orelse return .not_a_window;
    if (kind == .popup) return .not_a_window;
    const frame = ax.frame_get(element) catch return .failed;
    var slot: ?*ShellWindow = null;
    for (&windows) |*window| {
        if (window.id == 0 and slot == null) slot = window;
    }
    const window = slot orelse return .failed;
    window.* = .{ .id = id, .pid = app.pid, .element = c.CFRetain(element) };
    const context: ?*anyopaque = @ptrFromInt(@as(usize, id));
    const per_window = [_]Ref{
        ax.names.destroyed,     ax.names.moved,        ax.names.resized,
        ax.names.title_changed, ax.names.miniaturized, ax.names.deminiaturized,
    };
    for (per_window) |notification| {
        _ = c.AXObserverAddNotification(app.observer, element, notification, context);
    }
    var title_buffer: [1024]u8 = undefined;
    const title = ax.string_get(element, ax.names.title, &title_buffer);
    log("window {d} pid={d} {s} '{s}'", .{ id, app.pid, @tagName(kind), title });
    dispatch(.{ .window_appeared = .{
        .id = id,
        .pid = app.pid,
        .title = title,
        .frame = frame,
        .kind = kind,
        .resizable = ax.settable(element, ax.names.size),
        .minimized = app.hidden or ax.bool_get(element, ax.names.minimized),
        .fullscreen = ax.bool_get(element, ax.names.fullscreen),
        .tab_of = tab_leader(app.pid, id, frame),
        .adopted = app.adopted,
        .workspace = if (app.adopted) left.window_find(id, app.pid) else null,
    } });
    return .tracked;
}

/// Electron, Java and other toolkits announce a window before it has the role and
/// subrole of one. Such a window is looked at a few more times before it is given up as
/// a popup; without this it would only be found when it next takes focus.
fn probe_later(pid: i32, element: Ref) void {
    for (&probes) |*probe| {
        if (probe.pid != 0) continue;
        probe.* = .{
            .pid = pid,
            .element = c.CFRetain(element),
            .at_ms = c.now_ms() + probe_delays_ms[0],
        };
        timer_rearm();
        return;
    }
}

fn probes_run(now: u64) void {
    var found_any = false;
    var hung_pid: i32 = 0;
    for (&probes) |*probe| {
        if (probe.pid == 0 or probe.at_ms > now) continue;
        const app = app_find(probe.pid);
        var found = false;
        // One timeout for an application that hangs, not one for each of its probes.
        const timeouts = ax.timeouts;
        if (app) |known| {
            const ask = known.ready and probe.pid != hung_pid;
            found = ask and window_discover(known, probe.element) == .tracked;
        }
        if (ax.timeouts != timeouts) hung_pid = probe.pid;
        found_any = found_any or found;
        probe.tries += 1;
        if (found or app == null or probe.tries == probe_delays_ms.len) {
            c.CFRelease(probe.element);
            probe.* = .{};
        } else {
            probe.at_ms = now + probe_delays_ms[probe.tries];
        }
    }
    // The focus it took was announced while it was nothing to us.
    if (found_any) focus_notify();
}

/// A new window that appears exactly on top of a window of the same application which
/// has just gone off screen is a new tab of it.
fn tab_leader(pid: i32, id: u32, frame: Rect) u32 {
    // The windows of a hidden application are off screen without being tabs of anything.
    if (app_hidden(pid)) return 0;
    for (&windows) |*other| {
        if (other.id == 0 or other.id == id or other.pid != pid) continue;
        const known = engine.window_find(other.id) orelse continue;
        if (known.minimized or !known.actual.eql(frame)) continue;
        if (!ax.on_screen(other.id)) return other.id;
    }
    return 0;
}

fn frame_notify(id: u32) void {
    const window = window_find(id) orelse return;
    // While the displays are being rearranged macOS moves windows about by itself.
    // Correcting each move against the old arrangement would be a fight; every frame is
    // read once when it is over.
    if (monitors_dirty_at_ms != 0) return;
    if (c.CGEventSourceButtonState(0, 0) and (window.dragging or pointer_at(window))) {
        // The user is dragging. Report once, when the button comes up.
        window.dragging = true;
        drag_poll_at_ms = c.now_ms() + drag_poll_ms;
        timer_rearm();
        return;
    }
    frame_report(window, false);
}

/// Whether the pointer is on the window, or near enough to hold it by an edge. A button
/// that is down anywhere else is the user dragging something else, and the window moved
/// by itself.
fn pointer_at(window: *const ShellWindow) bool {
    const frame = ax.frame_get(window.element) catch return true;
    const event = c.CGEventCreate(null);
    if (event == null) return true;
    defer c.CFRelease(event);
    const location = c.CGEventGetLocation(event);
    const area: Rect = .{
        .x = frame.x - pointer_reach,
        .y = frame.y - pointer_reach,
        .w = frame.w + 2 * pointer_reach,
        .h = frame.h + 2 * pointer_reach,
    };
    const x: i32 = @intFromFloat(@round(location.x));
    const y: i32 = @intFromFloat(@round(location.y));
    return area.contains_point(x, y);
}

/// Reads every window's frame again, after a time in which changes were not listened to.
fn frames_resync() void {
    var hung_pid: i32 = 0;
    for (&windows) |*window| {
        if (window.id == 0) continue;
        window.dragging = false;
        // One timeout for an application that hangs, not one for each of its windows.
        const pid = window.pid;
        if (pid == hung_pid) continue;
        const timeouts = ax.timeouts;
        frame_report(window, false);
        if (ax.timeouts != timeouts) hung_pid = pid;
    }
}

fn frame_report(window: *ShellWindow, by_user: bool) void {
    const id = window.id;
    const frame = ax.frame_get(window.element) catch |err| {
        if (err == error.Invalid) {
            window_forget(id);
            dispatch(.{ .window_destroyed = id });
        }
        return;
    };
    if (engine.window_find(id)) |known| {
        // Everything is asked before anything is dispatched: a dispatch can end with the
        // window forgotten, and then neither its element nor what the engine knew is
        // there to be read.
        // A background tab that is on screen again was dragged out of its tab group.
        const untabbed = known.tab_of != 0 and ax.on_screen(id) and ax.on_screen(known.tab_of);
        // Entering and leaving native fullscreen is announced as a resize and nothing
        // else. Asked only when the frame is not the one the window was sent to.
        const was = known.fullscreen;
        const ask = was or !known.desired_valid or !frame.eql(known.desired);
        // An application that does not answer has not left fullscreen.
        const name = ax.names.fullscreen;
        const fullscreen = if (ask) ax.bool_get_checked(window.element, name) catch was else was;
        if (untabbed) dispatch(.{ .window_tab_changed = .{ .id = id, .tab_of = 0 } });
        if (fullscreen != was) {
            dispatch(.{ .window_fullscreen = .{ .id = id, .fullscreen = fullscreen } });
        }
    }
    dispatch(.{ .window_frame_changed = .{ .id = id, .frame = frame, .by_user = by_user } });
}

fn ax_notify(
    observer: Ref,
    element: Ref,
    notification: Ref,
    context: ?*anyopaque,
) callconv(.c) void {
    const id: u32 = @intCast(@intFromPtr(context));
    const n = &ax.names;
    if (id == 0) return app_notify(observer, element, notification);
    const window = window_find(id) orelse return;
    if (c.CFEqual(notification, n.destroyed) != 0) {
        window_forget(id);
        dispatch(.{ .window_destroyed = id });
    } else if (c.CFEqual(notification, n.moved) != 0 or c.CFEqual(notification, n.resized) != 0) {
        frame_notify(id);
    } else if (c.CFEqual(notification, n.title_changed) != 0) {
        var buffer: [1024]u8 = undefined;
        const title = ax.string_get(window.element, n.title, &buffer);
        dispatch(.{ .window_title_changed = .{ .id = id, .title = title } });
    } else if (c.CFEqual(notification, n.miniaturized) != 0) {
        dispatch(.{ .window_minimized = .{ .id = id, .minimized = true } });
    } else if (c.CFEqual(notification, n.deminiaturized) != 0) {
        const minimized = app_hidden(window.pid);
        dispatch(.{ .window_minimized = .{ .id = id, .minimized = minimized } });
    }
}

/// Application level: a new window, the application hidden or shown, or focus moved
/// between its windows.
fn app_notify(observer: Ref, element: Ref, notification: Ref) void {
    const n = &ax.names;
    for (&apps) |*app| {
        if (app.pid == 0 or app.observer != observer) continue;
        if (c.CFEqual(notification, n.window_created) != 0) {
            if (window_discover(app, element) != .tracked) probe_later(app.pid, element);
        } else if (c.CFEqual(notification, n.app_hidden) != 0) {
            return app_hidden_set(app, true);
        } else if (c.CFEqual(notification, n.app_shown) != 0) {
            app_hidden_set(app, false);
        }
    }
    focus_notify();
}

fn app_hidden(pid: i32) bool {
    const app = app_find(pid) orelse return false;
    return app.hidden;
}

/// cmd-h hides every window of an application without minimizing any of them. Their
/// tiles close up like those of minimized windows, and open again when it is shown.
fn app_hidden_set(app: *ShellApp, hidden: bool) void {
    if (app.hidden == hidden) return;
    app.hidden = hidden;
    const pid = app.pid;
    // The focused window goes last. While others of the application still count as
    // open the engine passes the focus on to one of them, and focusing a window of a
    // hidden application brings the application straight back.
    const focused = engine.focused_window;
    for ([2]bool{ false, true }) |focused_pass| {
        for (&windows) |*window| {
            if (window.id == 0 or window.pid != pid) continue;
            if ((window.id == focused) != focused_pass) continue;
            const minimized = hidden or ax.bool_get(window.element, ax.names.minimized);
            dispatch(.{ .window_minimized = .{ .id = window.id, .minimized = minimized } });
        }
    }
}

// Applications.

const AppDetails = struct { name: []const u8, bundle: []const u8 };

/// Name and bundle identifier of a regular (Dock-visible) application, or null.
fn app_details(pid: i32, name_buffer: []u8, bundle_buffer: []u8) ?AppDetails {
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const class = c.objc_getClass("NSRunningApplication");
    const running = c.send_pid(class, "runningApplicationWithProcessIdentifier:", pid);
    if (running == null) return null;
    if (c.send_integer(running, "activationPolicy") != 0) return null;
    return .{
        .name = ax.string_utf8(c.send(running, "localizedName"), name_buffer),
        .bundle = ax.string_utf8(c.send(running, "bundleIdentifier"), bundle_buffer),
    };
}

fn app_add(pid: i32) void {
    if (pid == own_pid or pid <= 0 or app_find(pid) != null) return;
    var name_buffer: [256]u8 = undefined;
    var bundle_buffer: [256]u8 = undefined;
    const details = app_details(pid, &name_buffer, &bundle_buffer) orelse return;
    var slot: ?*ShellApp = null;
    for (&apps) |*app| {
        if (app.pid == 0 and slot == null) slot = app;
    }
    const app = slot orelse return;
    app.* = .{
        .pid = pid,
        .element = c.AXUIElementCreateApplication(pid),
        .adopted = adopting,
    };
    log("app {d} {s} ({s})", .{ pid, details.name, details.bundle });
    dispatch(.{ .app_launched = .{ .pid = pid, .name = details.name, .bundle = details.bundle } });
    app_observe(app);
}

/// Starts observing the application and adopts its windows. Retries later when the
/// application is not ready to talk yet.
fn app_observe(app: *ShellApp) void {
    assert(!app.ready);
    if (app.observer == null) {
        var observer: Ref = null;
        if (c.AXObserverCreate(app.pid, ax_notify, &observer) != c.ax_success or observer == null) {
            return app_retry(app);
        }
        app.observer = observer;
        c.CFRunLoopAddSource(
            c.CFRunLoopGetMain(),
            c.AXObserverGetRunLoopSource(observer),
            c.kCFRunLoopCommonModes,
        );
    }
    const list = ax.copy(app.element, ax.names.windows) catch return app_retry(app);
    defer c.CFRelease(list);
    const per_app = [_]Ref{
        ax.names.window_created,      ax.names.focused_window_changed,
        ax.names.main_window_changed, ax.names.app_hidden,
        ax.names.app_shown,
    };
    for (per_app) |notification| {
        _ = c.AXObserverAddNotification(app.observer, app.element, notification, null);
    }
    app.ready = true;
    app.retry_at_ms = 0;
    app.hidden = ax.bool_get(app.element, ax.names.hidden);
    windows_scan(app, list);
}

fn windows_scan(app: *ShellApp, list: Ref) void {
    const count = c.CFArrayGetCount(list);
    var index: c.CFIndex = 0;
    // An application that stops answering is not asked about the rest of its windows.
    const timeouts = ax.timeouts;
    while (index < count and ax.timeouts == timeouts) : (index += 1) {
        _ = window_discover(app, c.CFArrayGetValueAtIndex(list, index));
    }
}

/// The application that came to the front. One that was not an ordinary application when
/// it launched, or that never answered, gets another chance now; and windows that it
/// opened without announcing them (restored ones, often) are found.
fn app_front(pid: i32) void {
    const app = app_find(pid) orelse return app_add(pid);
    if (!app.ready) {
        if (app.retry_at_ms != 0) return;
        app.retries = 0;
        return app_observe(app);
    }
    const list = ax.copy(app.element, ax.names.windows) catch return;
    defer c.CFRelease(list);
    // An application in front is shown. When the notice of that was lost, or the
    // application sends none, its windows would count as minimized for ever.
    if (app.hidden and !ax.bool_get(app.element, ax.names.hidden)) app_hidden_set(app, false);
    const timeouts = ax.timeouts;
    windows_scan(app, list);
    // And the other way round: a window whose end was never announced is let go.
    for (&windows) |*window| {
        // One timeout for an application that hangs, not one for each of its windows.
        if (ax.timeouts != timeouts) break;
        if (window.id == 0 or window.pid != pid or ax.alive(window.element)) continue;
        const id = window.id;
        window_forget(id);
        dispatch(.{ .window_destroyed = id });
    }
}

fn app_retry(app: *ShellApp) void {
    if (app.retries == app_retries_max) {
        log("app {d} never answered; ignoring it", .{app.pid});
        app.retry_at_ms = 0;
        return;
    }
    app.retries += 1;
    app.retry_at_ms = c.now_ms() + (@as(u64, 50) << @as(u6, @intCast(app.retries)));
    timer_rearm();
}

fn app_remove(pid: i32) void {
    const app = app_find(pid) orelse return;
    for (&windows) |*window| {
        if (window.id != 0 and window.pid == pid) window_forget(window.id);
    }
    if (app.observer != null) c.CFRelease(app.observer);
    if (app.element != null) c.CFRelease(app.element);
    app.* = .{};
    dispatch(.{ .app_terminated = pid });
}

/// Lets go of applications whose process is gone. The notice that an application quit
/// does not always come (seen live: seven windows of processes that had ended were
/// still followed), and nothing else would ever look at their windows again. Asked
/// when the layout changed, a moment later, which is also when it would show.
fn apps_reap() void {
    for (&apps) |*app| {
        const pid = app.pid;
        if (pid == 0) continue;
        if (c.kill(pid, 0) == 0 or c.__error().* != c.esrch) continue;
        log("app {d} is gone without notice", .{pid});
        app_remove(pid);
    }
}

fn apps_adopt() void {
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const workspace = c.send(c.objc_getClass("NSWorkspace"), "sharedWorkspace");
    const running = c.send(workspace, "runningApplications");
    const count: usize = @intCast(c.send_integer(running, "count"));
    var pids: [512]i32 = undefined;
    var pids_count: usize = 0;
    var index: usize = 0;
    while (index < count and pids_count < pids.len) : (index += 1) {
        const app = c.send_index(running, "objectAtIndex:", index);
        pids[pids_count] = @intCast(c.send_integer(app, "processIdentifier"));
        pids_count += 1;
    }
    adopting = true;
    dispatch(.{ .adoption = .begin });
    for (pids[0..pids_count]) |pid| app_add(pid);
    dispatch(.{ .adoption = .end });
    adopting = false;
}

fn carbon_app_event(call: Ref, event: Ref, context: ?*anyopaque) callconv(.c) i32 {
    _ = call;
    _ = context;
    var psn: c.ProcessSerialNumber = undefined;
    const status = c.GetEventParameter(
        event,
        c.event_param_process_id,
        c.type_process_serial_number,
        null,
        @sizeOf(c.ProcessSerialNumber),
        null,
        &psn,
    );
    var pid: i32 = 0;
    if (status != 0 or c.GetProcessPID(&psn, &pid) != 0) return 0;
    switch (c.GetEventKind(event)) {
        c.event_app_launched => app_add(pid),
        c.event_app_terminated => app_remove(pid),
        c.event_app_front_switched => {
            app_front(pid);
            focus_notify();
            secure_input_check();
        },
        else => {},
    }
    return 0;
}

// Monitors.

fn rect_from(rect: c.CGRect, primary_height: f64, flip: bool) Rect {
    const y = if (flip) primary_height - (rect.origin.y + rect.size.height) else rect.origin.y;
    return .{
        .x = @intFromFloat(@round(rect.origin.x)),
        .y = @intFromFloat(@round(y)),
        .w = @intFromFloat(@round(rect.size.width)),
        .h = @intFromFloat(@round(rect.size.height)),
    };
}

pub fn monitors_read(out: *[engine_module.monitors_max]engine_module.MonitorInfo) u32 {
    var ids: [engine_module.monitors_max]c.CGDirectDisplayID = undefined;
    var count: u32 = 0;
    if (c.CGGetActiveDisplayList(ids.len, &ids, &count) != 0) return 0;
    const main = c.CGMainDisplayID();
    const primary_height = c.CGDisplayBounds(main).size.height;
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const screens = c.send(c.objc_getClass("NSScreen"), "screens");
    const screens_count: usize =
        if (screens == null) 0 else @intCast(c.send_integer(screens, "count"));
    var used: u32 = 0;
    monitors_guessed = false;
    for (ids[0..count]) |id| {
        // A display that only repeats another one is no place for windows of its own.
        if (c.CGDisplayMirrorsDisplay(id) != 0) continue;
        const frame = rect_from(c.CGDisplayBounds(id), primary_height, false);
        // Until AppKit tells us better, assume a menu bar and nothing else.
        var visible: Rect =
            .{ .x = frame.x, .y = frame.y + 25, .w = frame.w, .h = @max(0, frame.h - 25) };
        var known = false;
        var screen_index: usize = 0;
        while (screen_index < screens_count) : (screen_index += 1) {
            const screen = c.send_index(screens, "objectAtIndex:", screen_index);
            // AppKit measures from the bottom left of the primary display.
            if (!rect_from(c.send_rect(screen, "frame"), primary_height, true).eql(frame)) continue;
            visible = rect_from(c.send_rect(screen, "visibleFrame"), primary_height, true);
            known = true;
        }
        if (!known) monitors_guessed = true;
        const display = display_identity(id, out[0..used]);
        out[used] = .{ .display = display, .frame = frame, .visible = visible, .main = id == main };
        used += 1;
    }
    return used;
}

/// The number the engine knows a display by. macOS numbers a display anew when it is
/// plugged into another port or the graphics card switches, and workspaces find their
/// display by this number, so it is made from the display's UUID, which stays.
fn display_identity(id: c.CGDirectDisplayID, taken: []const engine_module.MonitorInfo) u32 {
    var identity: u32 = id;
    const uuid = c.CGDisplayCreateUUIDFromDisplayID(id);
    if (uuid != null) {
        defer c.CFRelease(uuid);
        const uuid_bytes = c.CFUUIDGetUUIDBytes(uuid);
        identity = 2166136261;
        for (uuid_bytes.bytes) |byte| identity = (identity ^ byte) *% 16777619;
    }
    // Never 0, which stands for no display, and never the number of another display.
    var tries: usize = 0;
    while (tries < taken.len + 2) : (tries += 1) {
        var free = identity != 0;
        for (taken) |other| free = free and other.display != identity;
        if (free) return identity;
        identity +%= 1;
    }
    unreachable;
}

/// Reads the displays and tells the engine when they are not what it was told last.
fn monitors_refresh() void {
    var list: [engine_module.monitors_max]engine_module.MonitorInfo = undefined;
    const count = monitors_read(&list);
    var same = !monitors_force and count == monitors_seen_count;
    for (list[0..count], 0..) |*monitor, index| {
        if (!same) break;
        const seen = &monitors_seen[index];
        same = monitor.display == seen.display and monitor.main == seen.main and
            monitor.frame.eql(seen.frame) and monitor.visible.eql(seen.visible);
    }
    monitors_force = false;
    if (monitors_guessed and monitors_recheck_at_ms == 0) {
        monitors_recheck_at_ms = c.now_ms() + usable_recheck_ms;
    }
    if (same) return;
    monitors_seen = list;
    monitors_seen_count = count;
    log("monitors: {d}", .{count});
    dispatch(.{ .monitors_changed = list[0..count] });
}

/// The Dock or the menu bar changed, or the screen was unlocked. None of these is a
/// display reconfiguration, and each can change where windows may be.
fn system_changed(
    center: Ref,
    observer: ?*anyopaque,
    name: Ref,
    object: ?*const anyopaque,
    user_info: Ref,
) callconv(.c) void {
    _ = center;
    _ = name;
    _ = object;
    _ = user_info;
    const now = c.now_ms();
    if (@intFromPtr(observer) == observer_unlocked) {
        // macOS may have moved windows while the screen was locked; go over all of them.
        monitors_force = true;
        monitors_dirty_at_ms = now + monitors_debounce_ms;
        secure_input_check();
    } else {
        monitors_recheck_at_ms = now + monitors_debounce_ms;
        monitors_recheck_again = true;
    }
    timer_rearm();
}

const observer_usable: usize = 1;
const observer_unlocked: usize = 2;

fn system_observe(center: Ref, observer: usize, text: [*:0]const u8) void {
    const name = c.CFStringCreateWithCString(null, text, c.string_encoding_utf8);
    assert(name != null);
    defer c.CFRelease(name);
    c.CFNotificationCenterAddObserver(
        center,
        @ptrFromInt(observer),
        system_changed,
        name,
        null,
        c.notification_deliver_immediately,
    );
}

fn display_changed(display: c.CGDirectDisplayID, flags: u32, info: ?*anyopaque) callconv(.c) void {
    _ = display;
    _ = flags;
    _ = info;
    // Reconfiguration arrives as a burst of callbacks; act once it has gone quiet.
    monitors_force = true;
    monitors_dirty_at_ms = c.now_ms() + monitors_debounce_ms;
    timer_rearm();
}

// Hot keys.

fn hot_keys_register() void {
    for (hot_keys[0..hot_keys_count]) |hot_key| {
        if (hot_key != null) _ = c.UnregisterEventHotKey(hot_key);
    }
    hot_keys_count = engine.config.bindings_count;
    var failed: u32 = 0;
    var registered: u32 = 0;
    for (engine.config.bindings[0..hot_keys_count], 0..) |*binding, index| {
        hot_keys[index] = null;
        if (binding.mode != mode_current) continue;
        registered += 1;
        var modifiers: u32 = 0;
        if (binding.modifiers.cmd) modifiers |= c.modifier_cmd;
        if (binding.modifiers.alt) modifiers |= c.modifier_option;
        if (binding.modifiers.ctrl) modifiers |= c.modifier_control;
        if (binding.modifiers.shift) modifiers |= c.modifier_shift;
        const id: c.EventHotKeyID = .{ .signature = c.fourcc("tata"), .id = @intCast(index) };
        const status = c.RegisterEventHotKey(
            binding.keycode,
            modifiers,
            id,
            c.GetEventDispatcherTarget(),
            0,
            &hot_keys[index],
        );
        if (status == 0) continue;
        // Never silently: a binding that did not register is a key that types a character.
        failed += 1;
        var buffer: [64]u8 = undefined;
        var chord = stdx.Text.init(&buffer);
        config_module.chord_print(&chord, binding);
        std.debug.print(
            "tatami: hot key {s} could not be registered (status {d})\n",
            .{ chord.slice(), status },
        );
    }
    log("hot keys: {d} registered in mode {s}", .{
        registered - failed, engine.config.mode_name(mode_current),
    });
}

fn hot_key_pressed(call: Ref, event: Ref, context: ?*anyopaque) callconv(.c) i32 {
    _ = call;
    _ = context;
    var id: c.EventHotKeyID = undefined;
    const status = c.GetEventParameter(
        event,
        c.event_param_direct_object,
        c.type_event_hot_key_id,
        null,
        @sizeOf(c.EventHotKeyID),
        null,
        &id,
    );
    if (status != 0 or id.signature != c.fourcc("tata") or id.id >= engine.config.bindings_count) {
        return 0;
    }
    // Copy: a reload command replaces the configuration under our feet.
    const binding = engine.config.bindings[id.id];
    if (binding.mode != mode_current) return 0;
    var mode_next: ?u8 = null;
    for (binding.commands[0..binding.commands_count]) |cmd| {
        switch (cmd) {
            .mode => |span| mode_next = engine.config.mode_find(engine.config.strings.get(span)),
            else => dispatch(.{ .command = cmd }),
        }
    }
    // After the binding's commands, so hot keys are never re-registered under the handler
    // of the one that fired, and "close-others ; mode main" still closes first.
    if (mode_next) |mode| mode_enter(mode);
    repeat_arm(id.id, &binding);
    return 0;
}

/// Hot keys fire once per press. A binding that only resizes, nudges or moves focus runs
/// again for as long as its keys are held, as it would under a key repeat.
fn repeat_arm(index: u32, binding: *const config_module.Binding) void {
    repeat_at_ms = 0;
    for (binding.commands[0..binding.commands_count]) |cmd| {
        switch (cmd) {
            .focus, .focus_wrap, .focus_cycle => {},
            .resize_edge, .resize_dimension, .move_floating => {},
            else => return,
        }
    }
    repeat_binding = index;
    repeat_count = 0;
    repeat_at_ms = c.now_ms() + repeat_delay_ms;
    timer_rearm();
}

/// Whether every key of the binding is down right now. Asked of the keyboard, because a
/// release that is never reported would otherwise repeat for ever.
fn binding_held(binding: *const config_module.Binding) bool {
    if (!c.CGEventSourceKeyState(0, binding.keycode)) return false;
    const flags = c.CGEventSourceFlagsState(0);
    if (binding.modifiers.cmd and flags & c.flag_cmd == 0) return false;
    if (binding.modifiers.alt and flags & c.flag_option == 0) return false;
    if (binding.modifiers.ctrl and flags & c.flag_control == 0) return false;
    if (binding.modifiers.shift and flags & c.flag_shift == 0) return false;
    return true;
}

fn repeat_fire(now_ms: u64) void {
    repeat_at_ms = 0;
    if (repeat_binding >= engine.config.bindings_count) return;
    const binding = engine.config.bindings[repeat_binding];
    if (binding.mode != mode_current or !binding_held(&binding)) return;
    repeat_count += 1;
    if (repeat_count > repeats_max) return;
    for (binding.commands[0..binding.commands_count]) |cmd| dispatch(.{ .command = cmd });
    repeat_at_ms = now_ms + repeat_interval_ms;
}

fn mode_enter(mode: u8) void {
    assert(mode < engine.config.modes_count);
    if (mode == mode_current) return;
    mode_current = mode;
    repeat_at_ms = 0;
    hot_keys_register();
    event_publish("mode_changed", engine.config.mode_name(mode));
}

// Timer: one run loop timer serves every deadline.

fn timer_fired(fired: Ref, info: ?*anyopaque) callconv(.c) void {
    _ = fired;
    _ = info;
    if (quit_requested) {
        // Deferred to here so that whoever asked us to quit gets its reply first.
        ipc.server_close();
        c.exit(0);
    }
    const now = c.now_ms();
    for (&apps) |*app| {
        if (app.pid != 0 and !app.ready and app.retry_at_ms != 0 and app.retry_at_ms <= now) {
            app_observe(app);
        }
    }
    if (drag_poll_at_ms != 0 and drag_poll_at_ms <= now) {
        if (c.CGEventSourceButtonState(0, 0)) {
            drag_poll_at_ms = now + drag_poll_ms;
        } else {
            drag_poll_at_ms = 0;
            for (&windows) |*window| {
                if (window.id == 0 or !window.dragging) continue;
                window.dragging = false;
                frame_report(window, true);
            }
        }
    }
    if (monitors_dirty_at_ms != 0 and monitors_dirty_at_ms <= now) {
        monitors_dirty_at_ms = 0;
        monitors_refresh();
        // Frames were not listened to meanwhile, and AppKit may yet correct itself.
        frames_resync();
        monitors_recheck_at_ms = now + usable_recheck_ms;
    } else if (monitors_recheck_at_ms != 0 and monitors_recheck_at_ms <= now) {
        monitors_recheck_at_ms = if (monitors_recheck_again) now + usable_recheck_ms else 0;
        monitors_recheck_again = false;
        monitors_refresh();
    }
    probes_run(now);
    if (state_dirty_at_ms != 0 and state_dirty_at_ms <= now) {
        apps_reap();
        state_write();
    }
    if (repeat_at_ms != 0 and repeat_at_ms <= now) repeat_fire(now);
    if (border_reorder_at_ms != 0 and border_reorder_at_ms <= now) {
        border_reorder_at_ms = 0;
        border_refresh(true);
    }
    if (engine.next_deadline_ms()) |deadline| {
        if (deadline <= c.now_ms()) dispatch(.tick);
    }
    timer_rearm();
}

fn timer_rearm() void {
    if (timer == null) return;
    var next: ?u64 = engine.next_deadline_ms();
    if (quit_requested) next = 1;
    const extras = [_]u64{
        drag_poll_at_ms,        monitors_dirty_at_ms, repeat_at_ms,
        monitors_recheck_at_ms, state_dirty_at_ms,    border_reorder_at_ms,
    };
    for (extras) |at| {
        if (at != 0 and (next == null or at < next.?)) next = at;
    }
    for (&probes) |*probe| {
        if (probe.pid != 0 and (next == null or probe.at_ms < next.?)) next = probe.at_ms;
    }
    for (&apps) |*app| {
        if (app.pid == 0 or app.ready or app.retry_at_ms == 0) continue;
        if (next == null or app.retry_at_ms < next.?) next = app.retry_at_ms;
    }
    const now = c.now_ms();
    const delay_seconds: f64 = if (next) |at|
        @as(f64, @floatFromInt(if (at > now) at - now else 0)) / 1000.0
    else
        far_future_seconds;
    c.CFRunLoopTimerSetNextFireDate(timer, c.CFAbsoluteTimeGetCurrent() + delay_seconds);
}

// Configuration.

fn config_path(buffer: []u8) ?[*:0]const u8 {
    var text = stdx.Text.init(buffer);
    if (c.getenv("XDG_CONFIG_HOME")) |base| {
        text.print("{s}/tatami/tatami.conf\x00", .{std.mem.span(base)});
    } else if (c.getenv("HOME")) |home| {
        text.print("{s}/.config/tatami/tatami.conf\x00", .{std.mem.span(home)});
    } else return null;
    if (text.truncated) return null;
    return @ptrCast(buffer.ptr);
}

/// Reads the user's configuration into config_scratch. False when there is no file or it
/// has errors; the errors go to stderr with line numbers.
fn config_read() bool {
    var path_buffer: [1024]u8 = undefined;
    const path = config_path(&path_buffer) orelse return false;
    const fd = c.open(path, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var len: usize = 0;
    while (len < config_bytes.len) {
        const got = c.read(fd, config_bytes[len..].ptr, config_bytes.len - len);
        if (got <= 0) break;
        len += @intCast(got);
    }
    if (len == config_bytes.len) {
        // Never half a file: what was cut off would be bindings that silently do nothing.
        std.debug.print(
            "tatami: {s} is larger than {d} bytes and was not loaded\n",
            .{ std.mem.span(path), config_bytes.len - 1 },
        );
        return false;
    }
    var diagnostics_buffer: [4096]u8 = undefined;
    var diagnostics = stdx.Text.init(&diagnostics_buffer);
    if (config_scratch.load(config_bytes[0..len], &diagnostics)) return true;
    std.debug.print(
        "tatami: {s} has errors and was not loaded:\n{s}",
        .{ std.mem.span(path), diagnostics.slice() },
    );
    return false;
}

/// At start a missing or broken file means the built-in defaults. On reload a broken file
/// changes nothing: the bindings that worked keep working.
fn config_load(reload: bool) void {
    if (config_read()) {
        if (reload) engine.config_replace(&config_scratch) else engine.init(&config_scratch);
    } else if (!reload) {
        config_scratch.load_default();
        engine.init(&config_scratch);
    } else {
        return;
    }
    if (reload) {
        mode_current = 0;
        repeat_at_ms = 0;
        hot_keys_register();
        event_publish("config_reloaded", null);
    }
}

// Commands from the command line client.

fn ipc_request(text: []const u8, reply: *stdx.Text) void {
    var pool: command.StringPool = .{};
    const parsed = command.parse(text, &pool) catch |err| {
        reply.print("error: {s}: {s}\n", .{ @errorName(err), text });
        return;
    };
    if (parsed == .exec) {
        reply.print("error: exec is only available in key bindings\n", .{});
        return;
    }
    if (parsed == .mode) {
        const name = pool.get(parsed.mode);
        const mode = engine.config.mode_find(name) orelse {
            reply.print("error: no mode named {s}\n", .{name});
            return;
        };
        mode_enter(mode);
        reply.print("ok\n", .{});
        return;
    }
    if (parsed == .query and parsed.query.what == .modes) {
        // Only the shell knows which mode's keys are registered.
        engine.config.modes_print(reply, parsed.query.json, mode_current);
        return;
    }
    dispatch(.{ .command = parsed });
    if (engine.reply().len > 0) {
        reply.print("{s}", .{engine.reply()});
    } else {
        reply.print("ok\n", .{});
    }
}

fn signal_quit(number: c_int) callconv(.c) void {
    _ = number;
    ipc.wake_for_quit();
}

fn quit_from_signal() void {
    var pool: command.StringPool = .{};
    dispatch(.{ .command = command.parse("quit", &pool) catch unreachable });
}

/// What main was started with, to start over once the permission has been granted.
pub var restart_argv: ?[*]const ?[*:0]const u8 = null;

/// Set in the environment of the processes that wait for the permission after the first.
const waiting_variable = "TATAMI_WAITING";

/// Asks for the Accessibility permission, once, and waits for it. Exiting instead would
/// have launchd start us over and over, and the user would have nothing to click on.
///
/// A running process never sees the permission arrive: the answer is cached (seen live,
/// the first version polled for an hour and a half after it was granted). So every two
/// seconds we start over as a fresh process, which asks again.
fn accessibility_wait() noreturn {
    if (c.getenv(waiting_variable) == null) {
        const keys = [_]Ref{c.kAXTrustedCheckOptionPrompt};
        const values = [_]Ref{c.kCFBooleanTrue};
        const options = c.CFDictionaryCreate(
            null,
            &keys,
            &values,
            keys.len,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        assert(options != null);
        _ = c.AXIsProcessTrustedWithOptions(options);
        c.CFRelease(options);
        std.debug.print(
            "tatami: waiting for the Accessibility permission. Grant it to tatami, or to\n" ++
                "the program that starts it, in System Settings > Privacy & Security >\n" ++
                "Accessibility.\n",
            .{},
        );
        _ = c.setenv(waiting_variable, "1", 1);
    }
    _ = c.usleep(2_000_000);
    var path: [1024]u8 = undefined;
    var size: u32 = path.len;
    if (restart_argv) |argv| {
        if (c._NSGetExecutablePath(&path, &size) == 0) _ = c.execv(@ptrCast(&path), argv);
    }
    // Could not start over: leave it to whoever started us.
    c.exit(1);
}

fn secure_input_warn() void {
    var buffer: [256]u8 = undefined;
    var pid: i32 = 0;
    const holder = ax.secure_input_holder(&buffer, &pid) orelse return;
    std.debug.print("tatami: Secure Input is ON, held by {s} (pid {d}).\n", .{ holder, pid });
    // What it means is said once for each kind of holder. A terminal that keeps its
    // keyboard secure takes it and gives it back every time it comes to the front.
    const stuck = @intFromBool(std.mem.eql(u8, holder, "loginwindow"));
    if (secure_input_explained[stuck]) return;
    secure_input_explained[stuck] = true;
    std.debug.print("{s}{s}", .{ ax.secure_input_effect, ax.secure_input_advice(holder) });
}

/// Secure Input comes and goes with password fields, and macOS can leave it on after the
/// lock screen. A dead option key is explained in the log at the moment it dies.
fn secure_input_check() void {
    const on = c.IsSecureEventInputEnabled() != 0;
    if (on == secure_input_on) return;
    secure_input_on = on;
    if (on) secure_input_warn() else std.debug.print("tatami: Secure Input is off again\n", .{});
    event_publish(if (on) "secure_input_on" else "secure_input_off", null);
}

// What the manager knew is kept in a small file, so that a restart changes nothing.

fn state_path(buffer: []u8, suffix: []const u8) [*:0]const u8 {
    var text = stdx.Text.init(buffer);
    text.print("/tmp/tatami-{d}.state{s}\x00", .{ c.getuid(), suffix });
    assert(!text.truncated);
    return @ptrCast(buffer.ptr);
}

/// Writes the state file when its content changed. It is replaced in one step, so that a
/// reader never sees half of it.
fn state_write() void {
    state_dirty_at_ms = 0;
    state_revision = engine.revision;
    var bytes: [state_module.bytes_max]u8 = undefined;
    var text = stdx.Text.init(&bytes);
    state_module.print(&text, &engine);
    // Windows of the last run that have not been seen yet, such as those on another
    // Space, keep their line for as long as their application runs.
    for (left.windows_slice()) |window| {
        if (engine.window_find(window.id) != null or app_find(window.pid) == null) continue;
        state_module.window_print(&text, window);
    }
    const content = text.slice();
    if (content.len == 0 or text.truncated) return;
    if (std.mem.eql(u8, content, state_written[0..state_written_len])) return;
    var path_buffer: [64]u8 = undefined;
    var draft_buffer: [64]u8 = undefined;
    const path = state_path(&path_buffer, "");
    const draft = state_path(&draft_buffer, ".new");
    _ = c.unlink(draft);
    const flags = c.o_wronly | c.o_creat | c.o_excl | c.o_nofollow;
    const fd = c.open(draft, flags, @as(c_int, 0o600));
    if (fd < 0) return;
    const wrote = c.write(fd, content.ptr, content.len);
    _ = c.close(fd);
    if (wrote != @as(isize, @intCast(content.len)) or c.rename(draft, path) != 0) {
        _ = c.unlink(draft);
        return;
    }
    @memcpy(state_written[0..content.len], content);
    state_written_len = content.len;
}

/// Reads what the tatami that ran before this one left behind, and tells the engine
/// what it knew of its windows and which workspaces were where.
fn state_read() void {
    left = .{};
    var path_buffer: [64]u8 = undefined;
    // Without waiting: /tmp is everybody's, and a FIFO that someone else left under
    // this name would hold the start for ever, until somebody wrote to it.
    const fd = c.open(state_path(&path_buffer, ""), c.o_nofollow | c.o_nonblock);
    if (fd < 0) return;
    defer _ = c.close(fd);
    var bytes: [state_module.bytes_max]u8 = undefined;
    var len: usize = 0;
    while (len < bytes.len) {
        const got = c.read(fd, bytes[len..].ptr, bytes.len - len);
        if (got <= 0) break;
        len += @intCast(got);
    }
    state_module.parse(bytes[0..len], &left);
    log("state: {d} workspaces, {d} windows", .{ left.workspaces_count, left.windows_count });
    // The windows first: a workspace that windows were left on is then not taken for
    // an empty one when the displays are given theirs.
    dispatch(.{ .windows_remembered = left.windows_slice() });
    if (left.workspaces_count == 0) return;
    dispatch(.{ .workspaces_remembered = left.workspaces_slice() });
}

/// Subscribes to hot keys, application launches and exits, and display changes.
fn events_install() void {
    const hot_key_types = [_]c.EventTypeSpec{
        .{ .class = c.event_class_keyboard, .kind = c.event_hot_key_pressed },
    };
    _ = c.InstallEventHandler(
        c.GetEventDispatcherTarget(),
        hot_key_pressed,
        hot_key_types.len,
        &hot_key_types,
        null,
        null,
    );
    const app_types = [_]c.EventTypeSpec{
        .{ .class = c.event_class_application, .kind = c.event_app_launched },
        .{ .class = c.event_class_application, .kind = c.event_app_terminated },
        .{ .class = c.event_class_application, .kind = c.event_app_front_switched },
    };
    _ = c.InstallEventHandler(
        c.GetApplicationEventTarget(),
        carbon_app_event,
        app_types.len,
        &app_types,
        null,
        null,
    );
    mouse_tap_install();
    _ = c.CGDisplayRegisterReconfigurationCallback(display_changed, null);
    const local = c.CFNotificationCenterGetLocalCenter();
    const distributed = c.CFNotificationCenterGetDistributedCenter();
    const screens_changed = "NSApplicationDidChangeScreenParametersNotification";
    system_observe(local, observer_usable, screens_changed);
    system_observe(distributed, observer_usable, "com.apple.dock.prefchanged");
    const menu_bar = "AppleInterfaceMenuBarHidingChangedNotification";
    system_observe(distributed, observer_usable, menu_bar);
    system_observe(distributed, observer_unlocked, "com.apple.screenIsUnlocked");
}

/// Listens to mouse buttons, without changing or holding up any event, to put the
/// border back above a window that a click raised.
fn mouse_tap_install() void {
    const types = [_]u32{
        c.event_left_mouse_down,  c.event_left_mouse_up,
        c.event_right_mouse_down, c.event_right_mouse_up,
        c.event_other_mouse_down, c.event_other_mouse_up,
    };
    var mask: u64 = 0;
    for (types) |event_type| mask |= @as(u64, 1) << @intCast(event_type);
    mouse_tap = c.CGEventTapCreate(
        c.event_tap_session,
        c.event_tap_head_insert,
        c.event_tap_listen_only,
        mask,
        mouse_button_event,
        null,
    );
    if (mouse_tap == null) {
        std.debug.print("tatami: no mouse event tap: the border may hide after a click\n", .{});
        return;
    }
    const source = c.CFMachPortCreateRunLoopSource(null, mouse_tap, 0);
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
    c.CFRelease(source);
}

fn mouse_button_event(proxy: Ref, event_type: u32, event: Ref, info: ?*anyopaque) callconv(.c) Ref {
    _ = proxy;
    _ = info;
    if (event_type == c.event_tap_disabled_by_timeout or
        event_type == c.event_tap_disabled_by_user_input)
    {
        if (mouse_tap != null) c.CGEventTapEnable(mouse_tap, true);
        return event;
    }
    if (border.target_shown() == 0) return event;
    const at = c.now_ms() + border_click_reorder_ms;
    if (border_reorder_at_ms == 0 or border_reorder_at_ms < at) border_reorder_at_ms = at;
    timer_rearm();
    return event;
}

pub fn run() noreturn {
    own_pid = getpid();
    for (&apps) |*app| app.* = .{};
    for (&windows) |*window| window.* = .{};
    if (c.AXIsProcessTrusted() == 0) accessibility_wait();
    if (c.getenv(waiting_variable) != null) {
        std.debug.print("tatami: Accessibility granted\n", .{});
        _ = c.unsetenv(waiting_variable);
    }
    ax.init();
    _ = c.NSApplicationLoad();
    const application = c.send(c.objc_getClass("NSApplication"), "sharedApplication");
    assert(application != null);
    _ = c.signal(20, c.sig_ign); // SIGCHLD: exec children are never waited for.
    config_load(false);

    timer = c.CFRunLoopTimerCreate(
        null,
        c.CFAbsoluteTimeGetCurrent() + far_future_seconds,
        far_future_seconds,
        0,
        0,
        timer_fired,
        null,
    );
    c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), timer, c.kCFRunLoopCommonModes);

    // Before any window is touched: a second manager must not start beside a first.
    ipc.server_open(ipc_request, quit_from_signal);
    _ = c.signal(2, @intFromPtr(&signal_quit)); // SIGINT
    _ = c.signal(15, @intFromPtr(&signal_quit)); // SIGTERM
    // SIGHUP: the terminal that started us closed. Not when we were started to outlive
    // it, as under nohup, which is told by the signal being ignored already.
    if (c.signal(1, @intFromPtr(&signal_quit)) == c.sig_ign) _ = c.signal(1, c.sig_ign);
    for (&probes) |*probe| probe.* = .{};
    monitors_refresh();
    state_read();
    apps_adopt();
    focus_notify();
    border_refresh(true);

    events_install();
    hot_keys_register();
    secure_input_check();

    std.debug.print(
        "tatami: managing {d} windows on {d} monitors\n",
        .{ windows_count(), engine.monitors_count },
    );
    _ = c.send(application, "run");
    c.exit(0);
}

fn windows_count() u32 {
    var count: u32 = 0;
    for (&windows) |*window| count += @intFromBool(window.id != 0);
    return count;
}
