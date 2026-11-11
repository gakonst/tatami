//! tatami: a tiling window manager for macOS.
//!
//!   tatami start            run the window manager (this is what launchd runs)
//!   tatami <command...>     send a command to the running manager, e.g. tatami focus west
//!   tatami check            permissions, configuration and whether a manager is running
//!   tatami probe            read-only: list every window Accessibility reports, with timings
//!   tatami rescue           bring windows that are parked off screen back; needs no manager
//!   tatami bench            time the engine on a synthetic workload
//!   tatami default-config   print the built-in configuration
const std = @import("std");
const assert = std.debug.assert;
const c = @import("macos/c.zig");
const ax = @import("macos/ax.zig");
const ipc = @import("macos/ipc.zig");
const shell = @import("macos/shell.zig");
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");

const Rect = geometry.Rect;

fn out(comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var text = stdx.Text.init(&buffer);
    text.print(format, args);
    _ = c.write(1, &buffer, text.len);
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    const count: usize = @intCast(argc);
    if (count < 2) return usage(2);
    const first = std.mem.span(argv[1]);
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help")) return usage(0);
    if (std.mem.eql(u8, first, "start")) {
        shell.verbose = count > 2 and std.mem.eql(u8, std.mem.span(argv[2]), "--verbose");
        crash_handlers_install();
        shell.run();
    }
    if (std.mem.eql(u8, first, "check")) return check();
    if (std.mem.eql(u8, first, "probe")) {
        return probe(count > 2 and std.mem.eql(u8, std.mem.span(argv[2]), "--titles"));
    }
    if (std.mem.eql(u8, first, "rescue")) return rescue();
    if (std.mem.eql(u8, first, "bench")) return bench();
    if (std.mem.eql(u8, first, "default-config")) {
        _ = c.write(1, config_module.default_source.ptr, config_module.default_source.len);
        return 0;
    }
    // Anything else is a command for the running manager.
    var request: [ipc.request_max]u8 = undefined;
    var text = stdx.Text.init(&request);
    for (argv[1..count], 0..) |arg, index| {
        text.print("{s}{s}", .{ if (index == 0) "" else " ", std.mem.span(arg) });
    }
    if (text.truncated) {
        std.debug.print("tatami: command too long\n", .{});
        return 2;
    }
    var pool: command.StringPool = .{};
    _ = command.parse(text.slice(), &pool) catch |err| {
        std.debug.print("tatami: {s}: {s}\n", .{ @errorName(err), text.slice() });
        return 2;
    };
    const ok = ipc.client(text.slice()) catch |err| {
        switch (err) {
            error.NotRunning => {
                std.debug.print("tatami: not running (start it with: tatami start)\n", .{});
            },
            error.Timeout => {
                std.debug.print("tatami: no reply within {d} ms\n", .{ipc.reply_timeout_ms});
            },
        }
        return 1;
    };
    return if (ok) 0 else 1;
}

fn usage(code: c_int) c_int {
    out(
        \\usage: tatami start [--verbose] | check | probe | rescue | bench | default-config
        \\       tatami <command>      for example: tatami focus west, tatami workspace 3,
        \\                             tatami query windows, tatami reload, tatami quit
        \\
    , .{});
    return code;
}

// If the manager dies, windows parked off screen must not stay there. On a fatal signal
// we replace the process with 'tatami rescue', which needs none of the state that is gone.

var executable_path: [1024]u8 = undefined;

fn crash_handlers_install() void {
    var size: u32 = executable_path.len;
    if (c._NSGetExecutablePath(&executable_path, &size) != 0) return;
    const fatal = [_]c_int{ 4, 5, 6, 10, 11 }; // SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGSEGV
    for (fatal) |number| _ = c.signal(number, @intFromPtr(&crashed));
}

fn crashed(number: c_int) callconv(.c) void {
    _ = number;
    const argv = [_]?[*:0]const u8{ @ptrCast(&executable_path), "rescue", null };
    _ = c.execv(@ptrCast(&executable_path), &argv);
    c._exit(70);
}

fn trusted_or_explain() bool {
    if (c.AXIsProcessTrusted() != 0) return true;
    out("no Accessibility permission for this process. Grant it to the program that runs\n" ++
        "tatami in System Settings > Privacy & Security > Accessibility.\n", .{});
    return false;
}

fn check() c_int {
    const trusted = c.AXIsProcessTrusted() != 0;
    out("accessibility permission: {s}\n", .{if (trusted) "granted" else "MISSING"});
    var config: config_module.Config = undefined;
    config.load_default();
    out(
        "built-in configuration: {d} bindings, {d} rules\n",
        .{ config.bindings_count, config.rules_count },
    );
    var monitors: [engine_module.monitors_max]engine_module.MonitorInfo = undefined;
    const monitors_count = shell.monitors_read(&monitors);
    for (monitors[0..monitors_count]) |monitor| {
        const v = monitor.visible;
        out("display {d}{s}: usable {d},{d} {d}x{d}\n", .{
            monitor.display, if (monitor.main) " (main)" else "", v.x, v.y, v.w, v.h,
        });
    }
    var holder_buffer: [256]u8 = undefined;
    var holder_pid: i32 = 0;
    if (ax.secure_input_holder(&holder_buffer, &holder_pid)) |holder| {
        out("secure input: ON, held by {s} (pid {d})\n", .{ holder, holder_pid });
        out("{s}", .{ax.secure_input_advice});
    } else {
        out("secure input: off\n", .{});
    }
    out("manager: ", .{});
    const running = ipc.client("query stats") catch false;
    if (!running) out("not running\n", .{});
    return if (trusted) 0 else 1;
}

const RunningApp = struct { pid: i32, name: [64]u8, name_len: usize };

/// The regular (Dock-visible) applications that are running.
fn running_apps(apps: []RunningApp) usize {
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const workspace = c.send(c.objc_getClass("NSWorkspace"), "sharedWorkspace");
    const running = c.send(workspace, "runningApplications");
    const total: usize = @intCast(c.send_integer(running, "count"));
    var count: usize = 0;
    var index: usize = 0;
    while (index < total and count < apps.len) : (index += 1) {
        const app = c.send_index(running, "objectAtIndex:", index);
        if (c.send_integer(app, "activationPolicy") != 0) continue;
        apps[count].pid = @intCast(c.send_integer(app, "processIdentifier"));
        var buffer: [256]u8 = undefined;
        const name = ax.string_utf8(c.send(app, "localizedName"), &buffer);
        apps[count].name_len = stdx.copy_truncate(&apps[count].name, name);
        count += 1;
    }
    return count;
}

/// The id of the window an application names in one of its attributes, 0 when none.
fn probe_window(app: c.Ref, attribute: c.Ref) u32 {
    const window = ax.copy(app, attribute) catch return 0;
    defer c.CFRelease(window);
    return ax.window_id(window);
}

fn probe(titles: bool) c_int {
    if (!trusted_or_explain()) return 1;
    ax.init();
    var apps: [256]RunningApp = undefined;
    const apps_count = running_apps(&apps);
    var windows_total: u32 = 0;
    var micros_total: u64 = 0;
    var micros_worst: u64 = 0;
    for (apps[0..apps_count]) |*app| {
        const element = c.AXUIElementCreateApplication(app.pid);
        defer c.CFRelease(element);
        const started = c.now_us();
        const list = ax.copy(element, ax.names.windows) catch |err| {
            out(
                "{s} (pid {d}): {s} after {d} us\n",
                .{ app.name[0..app.name_len], app.pid, @errorName(err), c.now_us() - started },
            );
            continue;
        };
        defer c.CFRelease(list);
        const count = c.CFArrayGetCount(list);
        out("{s} (pid {d}): {d} windows, focused={d} main={d} frontmost={}\n", .{
            app.name[0..app.name_len],
            app.pid,
            count,
            probe_window(element, ax.names.focused_window),
            probe_window(element, ax.names.main_window),
            ax.bool_get(element, ax.names.frontmost),
        });
        var index: c.CFIndex = 0;
        while (index < count) : (index += 1) {
            const window = c.CFArrayGetValueAtIndex(list, index);
            const before = c.now_us();
            const id = ax.window_id(window);
            const kind = ax.window_kind(window);
            const frame = ax.frame_get(window) catch Rect.zero;
            const took = c.now_us() - before;
            var title_buffer: [1024]u8 = undefined;
            const title = if (titles) ax.string_get(window, ax.names.title, &title_buffer) else "";
            const kind_name = if (kind) |k| @tagName(k) else "not-a-window";
            const where = if (ax.on_screen(id)) "on-screen" else "off-screen";
            out("  {d}\t{s}\t{d},{d} {d}x{d}\t{s}\t{d} us\t{s}\n", .{
                id,                            kind_name,
                frame.x,                       frame.y,
                frame.w,                       frame.h,
                where,                         took,
                title[0..@min(title.len, 60)],
            });
            windows_total += 1;
            micros_total += took;
            micros_worst = @max(micros_worst, took);
        }
    }
    const micros_average = if (windows_total > 0) micros_total / windows_total else 0;
    out("{d} apps, {d} windows; reading one window (id, role, subrole, frame): " ++
        "avg {d} us, worst {d} us\n", .{ apps_count, windows_total, micros_average, micros_worst });
    return 0;
}

/// Moves every window whose centre is on no display back onto the main display.
fn rescue() c_int {
    if (!trusted_or_explain()) return 1;
    ax.init();
    var monitors: [engine_module.monitors_max]engine_module.MonitorInfo = undefined;
    const monitors_count = shell.monitors_read(&monitors);
    if (monitors_count == 0) return 1;
    var home = monitors[0].visible;
    for (monitors[0..monitors_count]) |monitor| {
        if (monitor.main) home = monitor.visible;
    }
    var apps: [256]RunningApp = undefined;
    const apps_count = running_apps(&apps);
    var moved: u32 = 0;
    for (apps[0..apps_count]) |*app| {
        const element = c.AXUIElementCreateApplication(app.pid);
        defer c.CFRelease(element);
        const list = ax.copy(element, ax.names.windows) catch continue;
        defer c.CFRelease(list);
        const count = c.CFArrayGetCount(list);
        var index: c.CFIndex = 0;
        while (index < count) : (index += 1) {
            const window = c.CFArrayGetValueAtIndex(list, index);
            if (ax.window_kind(window) == null) continue;
            const frame = ax.frame_get(window) catch continue;
            var visible = false;
            for (monitors[0..monitors_count]) |monitor| {
                if (monitor.frame.contains_point(frame.center_x(), frame.center_y())) {
                    visible = true;
                }
            }
            if (visible) continue;
            const w = @min(frame.w, home.w);
            const h = @min(frame.h, home.h);
            const x = home.x + @divTrunc(home.w - w, 2);
            const y = home.y + @divTrunc(home.h - h, 2);
            _ = ax.frame_set(window, .{ .x = x, .y = y, .w = w, .h = h }, false) catch continue;
            moved += 1;
        }
    }
    out("rescued {d} windows\n", .{moved});
    return 0;
}

// Engine benchmark: how long the manager itself takes to decide, with a perfect OS.

var bench_engine: engine_module.Engine = undefined;
var bench_effects: [engine_module.effects_max]engine_module.Effect = undefined;

fn bench_step(event: engine_module.Event) u32 {
    var frames: u32 = 0;
    var pending: [engine_module.effects_max]engine_module.Effect = undefined;
    var pending_count: usize = 0;
    const first = bench_engine.step(event, 1000);
    @memcpy(pending[0..first.len], first);
    pending_count = first.len;
    var rounds: u32 = 0;
    while (pending_count > 0) : (rounds += 1) {
        assert(rounds < 10_000);
        pending_count -= 1;
        switch (pending[pending_count]) {
            .set_frame => |set| {
                frames += 1;
                const more = bench_engine.step(
                    .{ .window_frame_applied = .{ .id = set.id, .frame = set.frame } },
                    1000,
                );
                assert(more.len == 0);
            },
            .focus_window => |focus| _ = bench_engine.step(.{ .window_focused = focus.id }, 1000),
            else => {},
        }
    }
    return frames;
}

fn bench_command(text: []const u8) u32 {
    var pool: command.StringPool = .{};
    return bench_step(.{ .command = command.parse(text, &pool) catch unreachable });
}

fn bench() c_int {
    var config: config_module.Config = undefined;
    config.load_default();
    bench_engine.init(&config);
    const monitor = [_]engine_module.MonitorInfo{.{
        .display = 1,
        .frame = Rect.init(0, 0, 1728, 1117),
        .visible = Rect.init(0, 38, 1728, 1079),
        .main = true,
    }};
    _ = bench_step(.{ .monitors_changed = &monitor });
    _ = bench_step(.{ .app_launched = .{ .pid = 7, .name = "Bench", .bundle = "bench" } });
    // Three workspaces with ten windows each.
    var id: u32 = 100;
    var workspace: u32 = 1;
    while (workspace <= 3) : (workspace += 1) {
        var text_buffer: [32]u8 = undefined;
        var text = stdx.Text.init(&text_buffer);
        text.print("workspace {d}", .{workspace});
        _ = bench_command(text.slice());
        var index: u32 = 0;
        while (index < 10) : (index += 1) {
            id += 1;
            _ = bench_step(.{ .window_appeared = .{
                .id = id,
                .pid = 7,
                .title = "window",
                .frame = Rect.init(100, 100, 800, 600),
                .kind = .standard,
                .resizable = true,
            } });
            _ = bench_step(.{ .window_focused = id });
        }
    }
    const rounds: u32 = 20_000;
    const cases = [_]struct { name: []const u8, a: []const u8, b: []const u8 }{
        .{ .name = "focus a neighbour", .a = "focus west", .b = "focus east" },
        .{ .name = "swap with a neighbour", .a = "swap north", .b = "swap south" },
        .{
            .name = "switch workspace (10 windows out, 10 in)",
            .a = "workspace 1",
            .b = "workspace 2",
        },
        .{
            .name = "send window to workspace and back",
            .a = "send 1 --follow",
            .b = "send 2 --follow",
        },
        .{ .name = "rotate the tree", .a = "rotate 90", .b = "rotate 270" },
    };
    for (cases) |case| {
        var frames: u64 = 0;
        const started = c.now_us();
        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            frames += bench_command(if (round % 2 == 0) case.a else case.b);
        }
        const elapsed = c.now_us() - started;
        out("{s}: {d} ns per command, {d} frames sent per command\n", .{
            case.name, elapsed * 1000 / rounds, frames / rounds,
        });
    }
    bench_engine.verify();
    return 0;
}
