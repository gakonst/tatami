//! The macOS shell around the engine: it turns Accessibility notifications, Carbon hot keys
//! and display changes into engine events, and performs the effects the engine returns.
//! Everything runs on the main thread. No call here can block for longer than the
//! Accessibility timeout, and an application that hits it is suspended by the engine.
const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const ax = @import("ax.zig");
const ipc = @import("ipc.zig");
const stdx = @import("../stdx.zig");
const geometry = @import("../geometry.zig");
const command = @import("../command.zig");
const config_module = @import("../config.zig");
const engine_module = @import("../engine.zig");

const Ref = c.Ref;
const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const Event = engine_module.Event;
const Effect = engine_module.Effect;

const followups_max: u32 = 2048;
const app_retries_max: u8 = 6;
const drag_poll_ms: u64 = 30;
const monitors_debounce_ms: u64 = 250;
const far_future_seconds: f64 = 3.0e9;
const config_bytes_max: usize = 64 * 1024;

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
var hot_keys: [config_module.bindings_max]Ref = undefined;
var hot_keys_count: u32 = 0;
var config_scratch: Config = undefined;
var config_bytes: [config_bytes_max]u8 = undefined;
var own_pid: i32 = 0;
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
    timer_rearm();
}

fn process(event: Event) void {
    const started_us = c.now_us();
    const effects = engine.step(event, c.now_ms());
    const count = effects.len;
    @memcpy(performing[0..count], effects);
    if (verbose) trace_event(event);
    for (performing[0..count]) |effect| {
        const before_us = c.now_us();
        perform(effect);
        if (verbose) trace_effect(effect, c.now_us() - before_us);
    }
    if (verbose and count > 0) log("   {d} effects in {d} us", .{ count, c.now_us() - started_us });
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
        .quit => quit_requested = true,
    }
}

fn perform_set_frame(id: u32, pid: i32, frame: Rect) void {
    const window = window_find(id) orelse {
        followup_push(.{ .window_destroyed = id });
        return;
    };
    const app = app_find(pid);
    // Applications driven by assistive software animate frame changes, slowly. Turn that
    // off around the change, as yabai does.
    var enhanced = false;
    if (app) |known| {
        enhanced = ax.bool_get(known.element, ax.names.enhanced_user_interface);
        if (enhanced) ax.bool_set(known.element, ax.names.enhanced_user_interface, false);
    }
    defer if (enhanced) ax.bool_set(app.?.element, ax.names.enhanced_user_interface, true);
    const move_only = if (engine.window_find(id)) |known|
        known.actual.w == frame.w and known.actual.h == frame.h
    else
        false;
    const applied = ax.frame_set(window.element, frame, move_only) catch |err| {
        switch (err) {
            error.Unresponsive => followup_push(.{ .app_unresponsive = pid }),
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

fn perform_focus(id: u32, pid: i32) void {
    const window = window_find(id) orelse return;
    const app = app_find(pid) orelse return;
    ax.bool_set(window.element, ax.names.main, true);
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
    if (window_find(id) == null and discover) window_discover(app, element);
    if (window_find(id) == null) return 0;
    return id;
}

fn focus_notify() void {
    const id = focused_window_id(true);
    if (id == 0) return;
    tabs_check(id);
    dispatch(.{ .window_focused = id });
}

/// Native tabs: when the focused window sits exactly where another window of the same
/// application sat, and that one is no longer on screen, they are tabs of each other.
fn tabs_check(focused_id: u32) void {
    const focused = window_find(focused_id) orelse return;
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

fn window_discover(app: *ShellApp, element: Ref) void {
    const id = ax.window_id(element);
    if (id == 0 or window_find(id) != null) return;
    const kind = ax.window_kind(element) orelse return;
    if (kind == .popup) return;
    const frame = ax.frame_get(element) catch return;
    var slot: ?*ShellWindow = null;
    for (&windows) |*window| {
        if (window.id == 0 and slot == null) slot = window;
    }
    const window = slot orelse return;
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
        .minimized = ax.bool_get(element, ax.names.minimized),
        .fullscreen = ax.bool_get(element, ax.names.fullscreen),
        .tab_of = tab_leader(app.pid, id, frame),
        .adopted = app.adopted,
    } });
}

/// A new window that appears exactly on top of a window of the same application which
/// has just gone off screen is a new tab of it.
fn tab_leader(pid: i32, id: u32, frame: Rect) u32 {
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
    if (c.CGEventSourceButtonState(0, 0)) {
        // The user is dragging. Report once, when the button comes up.
        window.dragging = true;
        drag_poll_at_ms = c.now_ms() + drag_poll_ms;
        timer_rearm();
        return;
    }
    frame_report(window, false);
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
        // A background tab that is on screen again was dragged out of its tab group.
        if (known.tab_of != 0 and ax.on_screen(id) and ax.on_screen(known.tab_of)) {
            dispatch(.{ .window_tab_changed = .{ .id = id, .tab_of = 0 } });
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
    if (id == 0) {
        // Application level: a new window, or focus moved between its windows.
        if (c.CFEqual(notification, n.window_created) != 0) {
            for (&apps) |*app| {
                if (app.pid != 0 and app.observer == observer) window_discover(app, element);
            }
        }
        focus_notify();
        return;
    }
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
        dispatch(.{ .window_minimized = .{ .id = id, .minimized = false } });
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
        ax.names.window_created,
        ax.names.focused_window_changed,
        ax.names.main_window_changed,
    };
    for (per_app) |notification| {
        _ = c.AXObserverAddNotification(app.observer, app.element, notification, null);
    }
    app.ready = true;
    app.retry_at_ms = 0;
    const count = c.CFArrayGetCount(list);
    var index: c.CFIndex = 0;
    while (index < count) : (index += 1) {
        window_discover(app, c.CFArrayGetValueAtIndex(list, index));
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
    for (pids[0..pids_count]) |pid| app_add(pid);
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
        c.event_app_front_switched => focus_notify(),
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
    for (ids[0..count], 0..) |id, index| {
        const frame = rect_from(c.CGDisplayBounds(id), primary_height, false);
        // Until AppKit tells us better, assume a menu bar and nothing else.
        var visible: Rect =
            .{ .x = frame.x, .y = frame.y + 25, .w = frame.w, .h = @max(0, frame.h - 25) };
        var screen_index: usize = 0;
        while (screen_index < screens_count) : (screen_index += 1) {
            const screen = c.send_index(screens, "objectAtIndex:", screen_index);
            // AppKit measures from the bottom left of the primary display.
            if (!rect_from(c.send_rect(screen, "frame"), primary_height, true).eql(frame)) continue;
            visible = rect_from(c.send_rect(screen, "visibleFrame"), primary_height, true);
        }
        out[index] = .{ .display = id, .frame = frame, .visible = visible, .main = id == main };
    }
    return count;
}

fn monitors_refresh() void {
    var list: [engine_module.monitors_max]engine_module.MonitorInfo = undefined;
    const count = monitors_read(&list);
    log("monitors: {d}", .{count});
    dispatch(.{ .monitors_changed = list[0..count] });
}

fn display_changed(display: c.CGDirectDisplayID, flags: u32, info: ?*anyopaque) callconv(.c) void {
    _ = display;
    _ = flags;
    _ = info;
    // Reconfiguration arrives as a burst of callbacks; act once it has gone quiet.
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
    for (engine.config.bindings[0..hot_keys_count], 0..) |*binding, index| {
        var modifiers: u32 = 0;
        if (binding.modifiers.cmd) modifiers |= c.modifier_cmd;
        if (binding.modifiers.alt) modifiers |= c.modifier_option;
        if (binding.modifiers.ctrl) modifiers |= c.modifier_control;
        if (binding.modifiers.shift) modifiers |= c.modifier_shift;
        const id: c.EventHotKeyID = .{ .signature = c.fourcc("tata"), .id = @intCast(index) };
        hot_keys[index] = null;
        const status = c.RegisterEventHotKey(
            binding.keycode,
            modifiers,
            id,
            c.GetEventDispatcherTarget(),
            0,
            &hot_keys[index],
        );
        if (status != 0) failed += 1;
    }
    // Never silently: a binding that did not register is a key that types a character.
    if (failed > 0) std.debug.print("tatami: {d} hot keys could not be registered\n", .{failed});
    log("hot keys: {d} registered", .{hot_keys_count - failed});
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
    for (binding.commands[0..binding.commands_count]) |cmd| dispatch(.{ .command = cmd });
    return 0;
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
    const extras = [_]u64{ drag_poll_at_ms, monitors_dirty_at_ms };
    for (extras) |at| {
        if (at != 0 and (next == null or at < next.?)) next = at;
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
    if (reload) hot_keys_register();
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
    std.debug.print("tatami: Secure Input is ON, held by {s} (pid {d}).\n{s}{s}", .{
        holder, pid, ax.secure_input_effect, ax.secure_input_advice(holder),
    });
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
    _ = c.CGDisplayRegisterReconfigurationCallback(display_changed, null);
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

    monitors_refresh();
    apps_adopt();
    focus_notify();

    events_install();
    hot_keys_register();
    secure_input_warn();
    ipc.server_open(ipc_request, quit_from_signal);
    _ = c.signal(2, @intFromPtr(&signal_quit)); // SIGINT
    _ = c.signal(15, @intFromPtr(&signal_quit)); // SIGTERM
    _ = c.signal(1, @intFromPtr(&signal_quit)); // SIGHUP: the terminal that started us closed.

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
