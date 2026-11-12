//! Hostile input: nothing that arrives from outside may crash the manager or leave the
//! engine in a bad state. Commands come from a socket that any local program can write
//! to, the configuration is written by hand, and titles and names come from other
//! applications.
//!
//! Most tests here drive the engine directly, without the simulated OS, because they
//! need more windows and stranger displays than the simulator has. The world they run
//! in does as it is told: a frame that is set is the frame that is reported back.
const std = @import("std");
const testing = std.testing;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const tree = @import("tree.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const Config = config_module.Config;
const WindowId = engine_module.WindowId;
const MonitorInfo = engine_module.MonitorInfo;

/// Far beyond any display, and far inside what an i32 holds.
const coordinate_limit: i64 = 1 << 30;
const pending_max: u32 = 4096;

const Pending = union(enum) {
    applied: struct { id: WindowId, frame: Rect },
    focused: WindowId,
    destroyed: WindowId,
    focus_report,
};

/// An obedient macOS around one engine. It counts what must never happen instead of
/// stopping at it, so that a test fails with a message.
const World = struct {
    engine: Engine,
    now_ms: u64,
    os_focus: WindowId,
    pending: [pending_max]Pending,
    pending_count: u32,
    /// Windows close when asked to.
    closes: bool,
    /// Check the engine's invariants after every event. With hundreds of windows that
    /// is slow, and they are checked whenever the world has gone quiet instead.
    verify_each: bool,
    frames_sent: u32,
    frames_bad: u32,
    frame_bad_first: Rect,
    quit_seen: bool,
    /// What the configuration file holds, for when the engine asks to read it again.
    reload_with: ?*const Config,
    exec_bytes: usize,
    /// The last answer. The engine's own copy is only good until its next step.
    reply_kept: [engine_module.reply_max]u8,
    reply_len: u32,

    fn init(world: *World, config: *const Config) void {
        world.engine.init(config);
        world.now_ms = 1000;
        world.os_focus = 0;
        world.pending_count = 0;
        world.closes = true;
        world.verify_each = true;
        world.frames_sent = 0;
        world.frames_bad = 0;
        world.frame_bad_first = Rect.zero;
        world.quit_seen = false;
        world.reload_with = null;
        world.exec_bytes = 0;
        world.reply_len = 0;
    }

    fn push(world: *World, entry: Pending) void {
        std.debug.assert(world.pending_count < pending_max);
        world.pending[world.pending_count] = entry;
        world.pending_count += 1;
    }

    /// One event, then everything the obedient world answers, until it is quiet.
    fn step(world: *World, event: engine_module.Event) void {
        world.deliver(event);
        world.drain();
    }

    fn drain(world: *World) void {
        var done: u32 = 0;
        while (done < world.pending_count) : (done += 1) {
            std.debug.assert(done < pending_max - 1024);
            switch (world.pending[done]) {
                .applied => |e| world.deliver(.{
                    .window_frame_applied = .{ .id = e.id, .frame = e.frame },
                }),
                .focused => |id| world.deliver(.{ .window_focused = id }),
                .destroyed => |id| world.deliver(.{ .window_destroyed = id }),
                .focus_report => world.deliver(.{ .focus_reported = world.os_focus }),
            }
        }
        world.pending_count = 0;
        if (!world.verify_each) world.engine.verify();
    }

    fn deliver(world: *World, event: engine_module.Event) void {
        world.now_ms += 1;
        const effects = world.engine.step(event, world.now_ms);
        for (effects) |effect| {
            switch (effect) {
                .set_frame => |set| {
                    world.frame_check(set.frame);
                    world.push(.{ .applied = .{ .id = set.id, .frame = set.frame } });
                },
                .focus_window => |focus| {
                    world.os_focus = focus.id;
                    world.push(.{ .focused = focus.id });
                },
                .close_window => |close| {
                    if (!world.closes) continue;
                    if (world.os_focus == close.id) world.os_focus = 0;
                    world.push(.{ .destroyed = close.id });
                },
                .query_focus => world.push(.focus_report),
                .quit => world.quit_seen = true,
                // The shell reads the file again and swaps the configuration in.
                .reload => if (world.reload_with) |config| world.engine.config_replace(config),
                // The shell looks the words up in the configuration that is in use.
                .exec => |span| world.exec_bytes += world.engine.config.strings.get(span).len,
                .warp_mouse => {},
            }
        }
        if (world.verify_each) world.engine.verify();
    }

    /// A frame that is sent has a positive size and stays far inside an i32.
    fn frame_check(world: *World, frame: Rect) void {
        world.frames_sent += 1;
        const right = @as(i64, frame.x) + frame.w;
        const bottom = @as(i64, frame.y) + frame.h;
        const inside = frame.x > -coordinate_limit and frame.y > -coordinate_limit and
            right < coordinate_limit and bottom < coordinate_limit;
        if (frame.w > 0 and frame.h > 0 and inside) return;
        if (world.frames_bad == 0) world.frame_bad_first = frame;
        world.frames_bad += 1;
    }

    fn expect_frames_sane(world: *const World) !void {
        if (world.frames_bad == 0) return;
        const frame = world.frame_bad_first;
        std.debug.print("{d} of {d} frames sent were bad, the first {d},{d} {d}x{d}\n", .{
            world.frames_bad, world.frames_sent, frame.x, frame.y, frame.w, frame.h,
        });
        return error.TestUnexpectedResult;
    }

    /// Lets every timer of the engine run out.
    fn settle(world: *World) void {
        var rounds: u32 = 0;
        while (world.engine.next_deadline_ms()) |deadline| : (rounds += 1) {
            std.debug.assert(rounds < 10_000);
            world.now_ms = @max(world.now_ms, deadline);
            world.step(.tick);
        }
    }

    fn displays(world: *World, list: []const MonitorInfo) void {
        world.step(.{ .monitors_changed = list });
    }

    fn app(world: *World, pid: i32, name: []const u8, bundle: []const u8) void {
        world.step(.{ .app_launched = .{ .pid = pid, .name = name, .bundle = bundle } });
    }

    const Opening = struct {
        title: []const u8 = "Untitled",
        frame: Rect = .{ .x = 100, .y = 100, .w = 800, .h = 600 },
        kind: engine_module.WindowKind = .standard,
        resizable: bool = true,
        tab_of: WindowId = 0,
        focus: bool = true,
    };

    fn open(world: *World, id: WindowId, pid: i32, opening: Opening) void {
        world.step(.{ .window_appeared = .{
            .id = id,
            .pid = pid,
            .title = opening.title,
            .frame = opening.frame,
            .kind = opening.kind,
            .resizable = opening.resizable,
            .tab_of = opening.tab_of,
        } });
        if (!opening.focus) return;
        world.os_focus = id;
        world.step(.{ .window_focused = id });
    }

    /// Parses and runs a command, and returns what the engine answered.
    fn run(world: *World, text: []const u8) []const u8 {
        var pool: command.StringPool = .{};
        const parsed = command.parse(text, &pool) catch |err| {
            std.debug.print("{s} does not parse: {s}\n", .{ text, @errorName(err) });
            unreachable;
        };
        return world.run_parsed(parsed);
    }

    fn run_parsed(world: *World, parsed: command.Command) []const u8 {
        world.deliver(.{ .command = parsed });
        const reply = world.engine.reply();
        world.reply_len = @intCast(reply.len);
        @memcpy(world.reply_kept[0..reply.len], reply);
        world.drain();
        return world.reply_kept[0..world.reply_len];
    }
};

var world_one: World = undefined;

fn display(id: u32, x: i32, y: i32, w: i32, h: i32, main: bool) MonitorInfo {
    const menu_bar: i32 = @min(25, h);
    return .{
        .display = id,
        .frame = .{ .x = x, .y = y, .w = w, .h = h },
        .visible = .{ .x = x, .y = y + menu_bar, .w = w, .h = h - menu_bar },
        .main = main,
    };
}

const laptop = [_]MonitorInfo{display(1, 0, 0, 1728, 1117, true)};

fn config_default() Config {
    var config: Config = undefined;
    config.load_default();
    return config;
}

fn config_from(source: []const u8) Config {
    var config: Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    if (!config.load(source, &diagnostics)) {
        std.debug.print("{s}", .{diagnostics.slice()});
        unreachable;
    }
    return config;
}

/// A fresh engine with this configuration and no display yet.
fn boot(source: []const u8) *World {
    const config = if (source.len == 0) config_default() else config_from(source);
    world_one.init(&config);
    return &world_one;
}

fn frame_wanted(os: *World, id: WindowId) Rect {
    const window = os.engine.window_find(id).?;
    std.debug.assert(window.desired_valid);
    return window.desired;
}

test "a floating window nudged by the largest number there is comes back into view" {
    const os = boot("");
    os.displays(&laptop);
    os.app(10, "Ghostty", "com.mitchellh.ghostty");
    os.open(1, 10, .{});
    _ = os.run("toggle float");
    const moves = [_][]const u8{
        "move-floating 2147483647 2147483647", "move-floating -2147483647 -2147483647",
        "move-floating 2147483647 0",          "move-floating 2147483647 0",
        "move-floating 0 -2147483647",         "move-floating -2147483647 2147483647",
        "move-floating 1000000 0",             "move-floating 0 99999",
    };
    for (moves) |text| {
        _ = os.run(text);
        // Carried off every display, the window returns to the middle of its own.
        try testing.expect(frame_wanted(os, 1).intersects(laptop[0].frame));
    }
    // A nudge that keeps it on the display is taken as it is.
    const before = frame_wanted(os, 1);
    _ = os.run("move-floating -7 +5");
    const after = frame_wanted(os, 1);
    try testing.expectEqual(before.x - 7, after.x);
    try testing.expectEqual(before.y + 5, after.y);
    try os.expect_frames_sane();
}

/// Opens count windows, numbered from first, spread over a few applications.
fn open_many(os: *World, first: WindowId, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const pid: i32 = @intCast(10 + index % 4);
        if (index < 4) os.app(pid, "Ghostty", "com.mitchellh.ghostty");
        os.open(first + index, pid, .{});
    }
}

fn windows_count(os: *World) u32 {
    var count: u32 = 0;
    for (&os.engine.windows) |*window| count += @intFromBool(window.id != 0);
    return count;
}

const geometry_commands = [_][]const u8{
    "balance",                            "rotate 90",
    "mirror x-axis",                      "toggle zoom-parent",
    "toggle zoom-parent",                 "toggle zoom-fullscreen",
    "toggle zoom-fullscreen",             "toggle gaps",
    "resize left -10000",                 "resize right 10000",
    "resize height -10000",               "resize ratio 1",
    "resize ratio 99",                    "insert west --ratio 1",
    "insert south --ratio 99",            "toggle float",
    "grid 64:64:63:63:1:1",               "grid 1:1:0:0:1:1",
    "move-floating -5 -5",                "float --bounds 0,0,1,1",
    "float --bounds .999,.999,.001,.001", "float --bounds 0.5,0.5,0.001,0.5",
    "tile",                               "toggle sticky",
    "toggle sticky",                      "layout float",
    "layout bsp",                         "send 2",
    "workspace 2",                        "workspace 1",
    "send-monitor next --follow",         "focus-monitor next",
    "warp east",                          "swap north",
    "retile",                             "toggle gaps",
};

fn geometry_exercise(os: *World) !void {
    for (geometry_commands, 0..) |text, index| {
        _ = os.run(text);
        os.settle();
        try os.expect_frames_sane();
        // Now and then the user drags the window in use, or pulls at its edges.
        const window = os.engine.window_find(os.engine.focused_window) orelse continue;
        var frame = window.actual;
        if (index % 3 == 0) frame.x += 40 else frame.w += 7;
        if (index % 3 == 1) frame.h += 9;
        os.step(.{ .window_frame_changed = .{ .id = window.id, .frame = frame, .by_user = true } });
        os.settle();
        try os.expect_frames_sane();
    }
    _ = os.run("quit");
    try testing.expect(os.quit_seen);
    try os.expect_frames_sane();
}

test "on a display of one pixel every frame that is sent still has a size" {
    const os = boot("");
    os.displays(&.{display(1, 0, 0, 1, 1, true)});
    open_many(os, 1, 5);
    try os.expect_frames_sane();
    try geometry_exercise(os);
}

test "a display smaller than the gaps never gets a tile without a size" {
    const os = boot("gap inner 200\ngap outer 200\ngap toggle 150\n");
    os.displays(&.{display(1, 0, 0, 300, 180, true)});
    open_many(os, 1, 6);
    try os.expect_frames_sane();
    try geometry_exercise(os);
}

test "as many windows as there can be on one small display all get a frame with a size" {
    const os = boot("");
    os.verify_each = false;
    os.displays(&.{display(1, 0, 0, 100, 100, true)});
    open_many(os, 1, engine_module.windows_max);
    try testing.expectEqual(engine_module.windows_max, windows_count(os));
    try testing.expectEqual(@as(u64, 0), os.engine.stats.windows_dropped);
    try os.expect_frames_sane();
    // A tile that is too small to have a size is one pixel, inside the display.
    for (&os.engine.windows) |*window| {
        try testing.expect(window.desired_valid);
        try testing.expect(window.desired.x >= 0 and window.desired.right() <= 100);
        try testing.expect(window.desired.y >= 25 and window.desired.bottom() <= 100);
    }
    // One more than fits is dropped and counted, not a crash.
    os.open(1000, 10, .{});
    try testing.expectEqual(@as(u64, 1), os.engine.stats.windows_dropped);
    try geometry_exercise(os);
}

test "sixteen displays are more than the manager follows, and it keeps working" {
    const os = boot("");
    var list: [16]MonitorInfo = undefined;
    for (&list, 0..) |*info, index| {
        const x: i32 = @intCast(index * 800);
        info.* = display(@intCast(index + 1), x, 0, 800, 600, index == 15);
    }
    os.displays(&list);
    try testing.expect(os.engine.monitors_count <= engine_module.monitors_max);
    open_many(os, 1, 12);
    try geometry_exercise(os);
}

fn count_of(text: []const u8, byte: u8) u32 {
    var count: u32 = 0;
    for (text) |other| count += @intFromBool(other == byte);
    return count;
}

test "an application whose name has line breaks still gets one line per window" {
    const os = boot("");
    os.displays(&laptop);
    os.app(10, "Evil\nerror: not-found\t*9\r", "com.evil\n\x00\x7f\tapp");
    os.open(1, 10, .{ .title = "a\nb\tc\x00d" });
    os.open(2, 10, .{ .title = "second" });
    const windows = os.run("query windows");
    try testing.expectEqual(@as(u32, 2), count_of(windows, '\n'));
    try testing.expectEqual(@as(u32, 12), count_of(windows, '\t'));
    const focus = os.run("query focus");
    try testing.expectEqual(@as(u32, 1), count_of(focus, '\n'));
    try testing.expectEqual(@as(u32, 2), count_of(focus, '\t'));
    const one = os.run("query window 1");
    try testing.expectEqual(@as(u32, 14), count_of(one, '\n'));
}

test "a rule that makes a native tab sticky does not break workspace switches" {
    const os = boot("rule app=\"Ghostty\" : sticky\n");
    os.displays(&laptop);
    os.app(10, "Ghostty", "com.mitchellh.ghostty");
    os.open(1, 10, .{});
    os.open(2, 10, .{ .tab_of = 1 });
    os.open(3, 10, .{ .tab_of = 1, .focus = false });
    _ = os.run("workspace 2");
    _ = os.run("workspace 1");
    os.displays(&.{ laptop[0], display(2, 1728, 0, 2560, 1440, false) });
    _ = os.run("send-monitor next --follow");
    os.step(.{ .window_destroyed = 1 });
    _ = os.run("toggle sticky");
    _ = os.run("workspace 3");
    try os.expect_frames_sane();
}

// A small JSON checker, to tell whether what a query answers would parse.

/// Whether the text is exactly one JSON value as RFC 8259 has it: in valid UTF-8, with
/// no raw control character in a string and nothing but white space around the value.
const Json = struct {
    text: []const u8,
    at: usize = 0,

    const depth_max: u32 = 1024;

    fn valid(text: []const u8) bool {
        var json: Json = .{ .text = text };
        var open: [depth_max]u8 = undefined;
        var depth: u32 = 0;
        var value_next = true;
        while (true) {
            json.space();
            if (!value_next) {
                if (depth == 0) return json.at == text.len;
                const object = open[depth - 1] == '{';
                const byte = json.take() orelse return false;
                if (byte == ',') {
                    if (object and !json.key()) return false;
                    value_next = true;
                } else if (byte == @as(u8, if (object) '}' else ']')) {
                    depth -= 1;
                } else return false;
                continue;
            }
            const byte = json.peek() orelse return false;
            if (byte != '{' and byte != '[') {
                if (!json.scalar()) return false;
                value_next = false;
                continue;
            }
            if (depth == depth_max) return false;
            json.at += 1;
            open[depth] = byte;
            depth += 1;
            json.space();
            if (json.peek() == @as(u8, if (byte == '{') '}' else ']')) {
                json.at += 1;
                depth -= 1;
                value_next = false;
            } else if (byte == '{' and !json.key()) return false;
        }
    }

    fn peek(json: *const Json) ?u8 {
        return if (json.at < json.text.len) json.text[json.at] else null;
    }

    fn take(json: *Json) ?u8 {
        const byte = json.peek() orelse return null;
        json.at += 1;
        return byte;
    }

    fn space(json: *Json) void {
        while (json.peek()) |byte| : (json.at += 1) {
            if (byte != ' ' and byte != '\t' and byte != '\n' and byte != '\r') return;
        }
    }

    /// The name of a member and the colon after it.
    fn key(json: *Json) bool {
        json.space();
        if (json.peek() != @as(u8, '"') or !json.string()) return false;
        json.space();
        return json.take() == @as(u8, ':');
    }

    fn scalar(json: *Json) bool {
        return switch (json.peek().?) {
            '"' => json.string(),
            '-', '0'...'9' => json.number(),
            't' => json.word("true"),
            'f' => json.word("false"),
            'n' => json.word("null"),
            else => false,
        };
    }

    fn word(json: *Json, name: []const u8) bool {
        if (!std.mem.startsWith(u8, json.text[json.at..], name)) return false;
        json.at += name.len;
        return true;
    }

    fn digits(json: *Json) bool {
        const start = json.at;
        while (json.peek()) |byte| : (json.at += 1) {
            if (byte < '0' or byte > '9') break;
        }
        return json.at > start;
    }

    fn number(json: *Json) bool {
        if (json.peek() == @as(u8, '-')) json.at += 1;
        const start = json.at;
        if (!json.digits()) return false;
        // No leading zeros.
        if (json.text[start] == '0' and json.at - start > 1) return false;
        if (json.peek() == @as(u8, '.')) {
            json.at += 1;
            if (!json.digits()) return false;
        }
        if (json.peek() == @as(u8, 'e') or json.peek() == @as(u8, 'E')) {
            json.at += 1;
            if (json.peek() == @as(u8, '+') or json.peek() == @as(u8, '-')) json.at += 1;
            if (!json.digits()) return false;
        }
        return true;
    }

    fn string(json: *Json) bool {
        std.debug.assert(json.text[json.at] == '"');
        json.at += 1;
        while (json.take()) |byte| {
            if (byte == '"') return true;
            if (byte < 0x20) return false;
            if (byte == '\\') {
                const escape = json.take() orelse return false;
                if (escape == 'u') {
                    var count: u32 = 0;
                    while (count < 4) : (count += 1) {
                        const hex = json.take() orelse return false;
                        if (!std.ascii.isHex(hex)) return false;
                    }
                } else if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", escape) == null) {
                    return false;
                }
            } else if (byte >= 0x80) {
                const len = utf8_strict(json.text[json.at - 1 ..]);
                if (len == 0) return false;
                json.at += len - 1;
            }
        }
        return false;
    }
};

/// The length of the well-formed UTF-8 sequence at the start of the bytes, or 0: not
/// the shortest form, a surrogate and anything past U+10FFFF are all malformed.
fn utf8_strict(bytes: []const u8) usize {
    const lead = bytes[0];
    const len: usize = switch (lead) {
        0x00...0x7f => return 1,
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => return 0,
    };
    if (bytes.len < len) return 0;
    for (bytes[1..len]) |byte| {
        if (byte & 0xc0 != 0x80) return 0;
    }
    const second = bytes[1];
    if (lead == 0xe0 and second < 0xa0) return 0;
    if (lead == 0xed and second > 0x9f) return 0;
    if (lead == 0xf0 and second < 0x90) return 0;
    if (lead == 0xf4 and second > 0x8f) return 0;
    return len;
}

test "the JSON checker of these tests takes JSON and nothing else" {
    const good = [_][]const u8{
        "{}",                                               "[]",
        " {\"a\":[1,2,{\"b\":null}]}\n",                    "\"\\u00e9\\n\\\"\\\\\"",
        "-0.5e+10",                                         "[true,false,null,0,-1,1.25]",
        "{\"t\":\"\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\"}", "{\"a\":{\"b\":{\"c\":[[[]]]}}}",
    };
    for (good) |text| try testing.expect(Json.valid(text));
    const bad = [_][]const u8{
        "",                 "{",                 "{\"a\":1,}",           "[1,]",
        "{\"a\" 1}",        "{a:1}",             "\"abc",                "\"a\nb\"",
        "\"\\x41\"",        "\"\\u12g4\"",       "01",                   "1.",
        "{} {}",            "nul",               "\"\xff\"",             "\"\xc3\"",
        "\"\xe0\x80\x80\"", "\"\xed\xa0\x80\"",  "\"\xf4\x90\x80\x80\"", "\"\xc0\xaf\"",
        "[1 2]",            "{\"a\":1 \"b\":2}", "-",                    "\"\x7f\x01\"",
    };
    for (bad) |text| try testing.expect(!Json.valid(text));
}

// Queries.

const hostile_pieces = [_][]const u8{
    "\"",           "\\",           "\\\"",             "\n",               "\t",
    "\r",           "\x00",         "\x01",             "\x1f",             "\x7f",
    "\xc3\xa9",     "\xe6\x97\xa5", "\xf0\x9f\x98\x80", "\xff",             "\xc0\xaf",
    "\xed\xa0\x80", "\xe0\x80\x80", "\xc3",             "\xf4\x90\x80\x80", "\xe2\x82",
    "\xf0\x9f\x98", "a",            " ",                "\\u0000",          "{\"a\":1}",
    "error: ",      "]}",           "\"\"\"\"\"\"",     "\\\\\\\\",         "*",
};

/// Fills the whole buffer with quotes, backslashes, control characters and UTF-8, some
/// of it malformed. The last piece is cut wherever the buffer ends.
fn text_hostile(prng: *stdx.Prng, buffer: []u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
        const piece = hostile_pieces[prng.below(hostile_pieces.len)];
        const take = @min(piece.len, buffer.len - len);
        @memcpy(buffer[len..][0..take], piece[0..take]);
        len += take;
    }
    return buffer;
}

/// Opens one more window with a title, an application name and a bundle identifier of
/// 255 hostile bytes each, and now and then floats it, labels it or sends it away.
fn crowd_open(os: *World, prng: *stdx.Prng, id: WindowId) void {
    var title: [255]u8 = undefined;
    var name: [255]u8 = undefined;
    var bundle: [255]u8 = undefined;
    const pid: i32 = @intCast(100 + id % 100);
    os.app(pid, text_hostile(prng, &name), text_hostile(prng, &bundle));
    os.open(id, pid, .{ .title = text_hostile(prng, &title) });
    var buffer: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "label w{d:0>23}", .{id}) catch unreachable;
    _ = os.run(label);
    switch (id % 8) {
        1 => _ = os.run("toggle float"),
        2 => _ = os.run("send 2"),
        3 => _ = os.run("send 16"),
        4 => _ = os.run("toggle zoom-fullscreen"),
        else => {},
    }
}

/// What a query answers is whole: an error on one line, or JSON that parses, or lines
/// with no control character in them but the tabs between columns.
fn expect_reply_whole(reply: []const u8, json: bool) !void {
    if (reply.len == 0) return;
    try testing.expectEqual(@as(u8, '\n'), reply[reply.len - 1]);
    if (std.mem.startsWith(u8, reply, "error: ")) {
        return testing.expectEqual(@as(u32, 1), count_of(reply, '\n'));
    }
    if (json) {
        if (Json.valid(reply)) return;
        std.debug.print("not JSON: {s}\n", .{reply[0..@min(reply.len, 400)]});
        return error.TestUnexpectedResult;
    }
    for (reply) |byte| {
        const control = (byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f;
        try testing.expect(!control);
    }
}

const query_names = [_][]const u8{
    "windows", "workspaces", "monitors", "focus", "stats", "window", "tree", "bindings",
    "modes",   "commands",
};

/// Runs every query both ways. Returns how many could not answer.
fn queries_all(os: *World) !u32 {
    var failed: u32 = 0;
    for (query_names) |name| {
        for ([2]bool{ false, true }) |json| {
            var buffer: [64]u8 = undefined;
            const flag = if (json) " --json" else "";
            const reply = os.run(
                std.fmt.bufPrint(&buffer, "query {s}{s}", .{ name, flag }) catch unreachable,
            );
            try expect_reply_whole(reply, json);
            failed += @intFromBool(std.mem.startsWith(u8, reply, "error: "));
        }
    }
    return failed;
}

const three_displays = [_]MonitorInfo{
    display(3, 0, 0, 1920, 1080, false),
    display(1, 1920, 0, 1728, 1117, true),
    display(2, 3648, 0, 2560, 1440, false),
};

test "whatever the titles are, a query answers whole or says that it cannot" {
    const os = boot("");
    os.verify_each = false;
    os.displays(&three_displays);
    var prng = stdx.Prng.init(11);
    _ = os.run("label-workspace web");
    var id: WindowId = 1;
    while (id <= engine_module.windows_max) : (id += 1) {
        crowd_open(os, &prng, id);
        // The answers grow with the windows, so many sizes are tried, also sizes close
        // to the first one that no longer fits.
        if (id % 3 != 0) continue;
        try expect_reply_whole(os.run("query windows --json"), true);
        try expect_reply_whole(os.run("query windows"), false);
        if (id % 48 == 0) _ = try queries_all(os);
    }
    try testing.expectEqual(engine_module.windows_max, windows_count(os));
    _ = try queries_all(os);
    // The same with every display asleep.
    os.displays(&.{});
    _ = try queries_all(os);
}

test "every query can answer for as many windows as there can be" {
    const os = boot("");
    os.verify_each = false;
    os.displays(&laptop);
    // The longest answers: every byte of a title and of a name is one that JSON spells
    // with two, the windows have the largest ids that a command can name, and the
    // layout is one long chain, the deepest tree there can be.
    const quotes: [255]u8 = @splat('"');
    var index: u32 = 0;
    while (index < engine_module.windows_max) : (index += 1) {
        const pid: i32 = @intCast(100 + index % 100);
        os.app(pid, &quotes, &quotes);
        os.open(std.math.maxInt(i32) - index, pid, .{ .title = &quotes });
        var buffer: [64]u8 = undefined;
        _ = os.run(std.fmt.bufPrint(&buffer, "label w{d:0>23}", .{index}) catch unreachable);
    }
    try testing.expectEqual(@as(u32, 0), try queries_all(os));
    const windows = os.run("query windows");
    try testing.expectEqual(engine_module.windows_max, count_of(windows, '\n'));
    try testing.expectEqual(engine_module.windows_max * 6, count_of(windows, '\t'));
    const layout = os.run("query tree");
    try testing.expectEqual(engine_module.windows_max * 2 + 1, count_of(layout, '\n'));
}

// Commands: anything at all can arrive on the socket.

/// One command of every kind the language has, and most of their forms.
const corpus = [_][]const u8{
    "focus west",                           "focus down --wrap",
    "focus next",                           "focus prev --wrap",
    "focus 3",                              "focus logs",
    "focus focused",                        "swap east",
    "swap 1 2",                             "swap logs build",
    "warp north",                           "warp below",
    "move left 2",                          "move 3 above logs --ratio 30",
    "move 4 right build --ratio=99",        "insert south",
    "insert east --ratio 1",                "insert west --ratio=99",
    "resize left -20",                      "resize right 10000",
    "resize top -10000",                    "resize bottom 1",
    "resize width +50",                     "resize height -50",
    "resize ratio 1",                       "resize ratio 99",
    "balance",                              "retile",
    "rotate 90",                            "rotate 180",
    "rotate 270",                           "mirror x-axis",
    "mirror y-axis",                        "toggle split",
    "toggle float",                         "toggle zoom-parent",
    "toggle zoom-fullscreen",               "toggle sticky",
    "toggle gaps",                          "zoom",
    "zoom --on",                            "zoom 2 --off",
    "zoom logs",                            "float",
    "float 3",                              "float --bounds 0,0,1,1",
    "float 5 --bounds=.25,.25,.5,.5",       "float --bounds .999,.999,.001,.001",
    "tile",                                 "tile 4",
    "grid 4:4:1:1:2:2",                     "grid 64:64:63:63:1:1",
    "grid 1:1:0:0:1:1",                     "move-floating 20 -20",
    "move-floating 2147483647 -2147483647", "layout bsp",
    "layout float",                         "close",
    "close 5",                              "close-others",
    "label logs",                           "label 2 build",
    "label --clear",                        "label 3 --clear",
    "label-workspace web",                  "label-workspace --clear",
    "workspace 1",                          "workspace 16",
    "workspace 17",                         "workspace 255",
    "workspace next",                       "workspace prev",
    "workspace recent",                     "workspace new",
    "workspace web",                        "send 2",
    "send 3 --follow",                      "send new",
    "send web --follow",                    "send next",
    "send recent",                          "focus-monitor 1",
    "focus-monitor 3",                      "focus-monitor next",
    "focus-monitor prev",                   "focus-monitor recent",
    "focus-monitor 255",                    "send-monitor 2",
    "send-monitor next --follow",           "send-monitor recent",
    "query windows",                        "query workspaces --json",
    "query monitors",                       "query focus --json",
    "query stats",                          "query window",
    "query window 3 --json",                "query window logs",
    "query tree --json",                    "query bindings",
    "query modes --json",                   "query commands",
    "mode main",                            "mode service",
    "exec open -a Ghostty",                 "reload",
    "quit",
};

const nines: [40]u8 = @splat('9');
const zeds: [300]u8 = @splat('z');

/// Words to splice in: numbers at their edges, labels at theirs, flags, and bytes that
/// no command is made of.
const tokens = [_][]const u8{
    "0",                         "-1",               "1",
    "2",                         "3",                "5",
    "16",                        "17",               "99",
    "100",                       "101",              "255",
    "256",                       "10000",            "-10001",
    "2147483647",                "-2147483647",      "-2147483648",
    "2147483648",                "4294967295",       "99999999999",
    "1e9",                       "0x10",             "+5",
    "007",                       "00000000001",      "1.5",
    "west",                      "left",             "up",
    "below",                     "above",            "next",
    "prev",                      "recent",           "new",
    "focused",                   "on",               "off",
    "logs",                      "build",            "web",
    "West",                      "FOCUSED",          "x1",
    "west1",                     "a",                "--wrap",
    "--follow",                  "--json",           "--on",
    "--off",                     "--clear",          "--ratio",
    "--ratio=0",                 "--ratio=1",        "--ratio=50",
    "--ratio=99",                "--ratio=100",      "--ratio=",
    "--bounds",                  "--bounds=0,0,1,1", "--bounds=0,0,0,0",
    "--bounds=1,1,1,1",          "--bounds=.,.,1,1", "0.25,0.25,0.5,0.5",
    "1,1,1,1",                   "0,0,1.0001,1",     "1:1:0:0:1:1",
    "64:64:0:0:64:64",           "65:1:0:0:1:1",     "0:0:0:0:0:0",
    "1:1:1:1:1:1",               "ratio",            "width",
    "height",                    "top",              "bottom",
    "x-axis",                    "y_axis",           "bsp",
    "float",                     "split",            "gaps",
    "sticky",                    "zoom-parent",      "windows",
    "window",                    "tree",             "bindings",
    "modes",                     "focus",            "swap",
    "move",                      "insert",           "resize",
    "zoom",                      "tile",             "close",
    "label",                     "send",             "query",
    "mode",                      "exec",             "quit",
    "reload",                    "workspace",        ";",
    ":",                         "\"",               "'unclosed",
    "\x00",                      "\xff\xfe",         "\xc3\xa9",
    "\xe2\x82",                  "a\x00b",           "abcdefghijklmnopqrstuvwx",
    "abcdefghijklmnopqrstuvwxy", "-",                "--",
    "=",                         &nines,             &zeds,
};

const line_max: usize = 1024;

/// A line with words replaced, added, dropped, doubled, swapped or taken from another
/// line, and now and then a byte changed or the end cut off.
fn splice(
    prng: *stdx.Prng,
    buffer: *[line_max]u8,
    lines: []const []const u8,
    pool: []const []const u8,
) []const u8 {
    var words: [24][]const u8 = undefined;
    var count: u32 = 0;
    var parts = std.mem.tokenizeScalar(u8, lines[prng.below(@intCast(lines.len))], ' ');
    while (parts.next()) |part| {
        if (count == words.len - 8) break;
        words[count] = part;
        count += 1;
    }
    var changes = 1 + prng.below(3);
    while (changes > 0) : (changes -= 1) {
        const at = prng.below(count + 1);
        const token = pool[prng.below(@intCast(pool.len))];
        switch (prng.below(6)) {
            0 => if (at < count) {
                words[at] = token;
            },
            1 => if (count < words.len - 8) {
                std.mem.copyBackwards([]const u8, words[at + 1 .. count + 1], words[at..count]);
                words[at] = token;
                count += 1;
            },
            2 => if (at < count and count > 1) {
                std.mem.copyForwards([]const u8, words[at .. count - 1], words[at + 1 .. count]);
                count -= 1;
            },
            3 => if (at < count and count < words.len - 8) {
                words[count] = words[at];
                count += 1;
            },
            4 => if (at < count) {
                std.mem.swap([]const u8, &words[at], &words[prng.below(count)]);
            },
            else => {
                const line = lines[prng.below(@intCast(lines.len))];
                var other = std.mem.tokenizeScalar(u8, line, ' ');
                if (prng.chance(1, 2)) _ = other.next();
                while (other.next()) |part| {
                    if (count == words.len) break;
                    words[count] = part;
                    count += 1;
                }
            },
        }
    }
    return mangle(prng, buffer, join(prng, buffer, words[0..count]));
}

fn join(prng: *stdx.Prng, buffer: *[line_max]u8, words: []const []const u8) usize {
    const gaps = [_][]const u8{ " ", " ", " ", " ", "  ", "\t", " \t ", "\r\n", "" };
    var text = stdx.Text.init(buffer);
    if (prng.chance(1, 8)) text.append(gaps[prng.below(gaps.len)]);
    for (words, 0..) |word, index| {
        if (index > 0) text.append(gaps[prng.below(gaps.len)]);
        text.append(word);
    }
    if (prng.chance(1, 8)) text.append(gaps[prng.below(gaps.len)]);
    return text.len;
}

fn mangle(prng: *stdx.Prng, buffer: *[line_max]u8, len: usize) []const u8 {
    if (len == 0 or !prng.chance(1, 4)) return buffer[0..len];
    const at = prng.below(@intCast(len));
    switch (prng.below(4)) {
        0 => buffer[at] = @intCast(prng.below(256)),
        1 => buffer[at] = ([_]u8{ 0, '\t', '\r', '\n', '"', '\\', 0xff, '-' })[prng.below(8)],
        2 => return buffer[0..at],
        else => for (buffer[0..len]) |*byte| {
            byte.* = std.ascii.toUpper(byte.*);
        },
    }
    return buffer[0..len];
}

/// Random bytes, or random letters, digits and signs of the kind commands are made of.
fn noise(prng: *stdx.Prng, buffer: *[line_max]u8) []const u8 {
    const alphabet = "focuswapmvetilzrgbqydhknx-  0123456789:,.=+\t";
    const len = prng.below(48);
    const raw = prng.chance(1, 2);
    for (buffer[0..len]) |*byte| {
        byte.* = if (raw) @intCast(prng.below(256)) else alphabet[prng.below(alphabet.len)];
    }
    return buffer[0..len];
}

/// The name of a command followed by words that may or may not belong after it.
fn babble(prng: *stdx.Prng, buffer: *[line_max]u8) []const u8 {
    var words: [6][]const u8 = undefined;
    var first = std.mem.tokenizeScalar(u8, corpus[prng.below(corpus.len)], ' ');
    words[0] = first.next().?;
    const count = 1 + prng.below(words.len);
    for (words[1..count]) |*word| word.* = tokens[prng.below(tokens.len)];
    return buffer[0..join(prng, buffer, words[0..count])];
}

const State = enum {
    no_display,
    no_window,
    one_window,
    three_displays,
    zoomed,
    floating_focus,
    asleep,
    one_pixel,
};

const states = [_]State{
    .no_display, .no_window,      .one_window, .three_displays,
    .zoomed,     .floating_focus, .asleep,     .one_pixel,
};

var worlds: [states.len]World = undefined;

/// Three displays and windows of every kind on several workspaces: tiled, floating,
/// sticky, zoomed, minimized, native fullscreen, a dialog, native tabs, labels.
fn state_busy(os: *World) void {
    os.displays(&three_displays);
    open_many(os, 1, 12);
    const setup = [_][]const u8{
        "label 3 logs",   "label 5 build", "label-workspace web",    "focus 2",
        "send 2",         "focus 4",       "send 3 --follow",        "focus 6",
        "send-monitor 1", "focus 7",       "toggle float",           "focus 8",
        "toggle sticky",  "focus 9",       "toggle zoom-fullscreen", "focus 10",
        "send 2",         "workspace 2",   "label-workspace mail",   "focus 1",
        "insert south",
    };
    for (setup) |text| _ = os.run(text);
    os.open(13, 10, .{ .tab_of = 1, .focus = false });
    os.open(14, 11, .{ .kind = .dialog, .resizable = false, .focus = false });
    os.step(.{ .window_minimized = .{ .id = 11, .minimized = true } });
    os.step(.{ .window_fullscreen = .{ .id = 12, .fullscreen = true } });
}

fn state_build(os: *World, state: State) void {
    const config = config_default();
    os.init(&config);
    switch (state) {
        // Windows can be reported before any display is.
        .no_display => open_many(os, 1, 3),
        .no_window => os.displays(&laptop),
        .one_window => {
            os.displays(&laptop);
            open_many(os, 1, 1);
        },
        .three_displays => state_busy(os),
        .zoomed => {
            os.displays(&laptop);
            open_many(os, 1, 4);
            _ = os.run("toggle zoom-parent");
            _ = os.run("focus 2");
            _ = os.run("zoom --on");
        },
        .floating_focus => {
            os.displays(&laptop);
            open_many(os, 1, 3);
            _ = os.run("label logs");
            os.open(4, 10, .{ .kind = .dialog });
        },
        .asleep => {
            state_busy(os);
            os.displays(&.{});
        },
        .one_pixel => {
            os.displays(&.{display(1, 0, 0, 1, 1, true)});
            open_many(os, 1, 5);
        },
    }
}

fn states_build() void {
    for (&worlds, states) |*os, state| state_build(os, state);
}

var parsed_total: u32 = 0;

/// The whole promise: a line either does not parse, or it is a command that the engine
/// runs in every state without tripping an assertion, sending a bad frame or answering
/// with something that is not whole.
fn hostile_line(text: []const u8) !void {
    var pool: command.StringPool = .{};
    const parsed = command.parse(text, &pool) catch return;
    switch (parsed) {
        .exec => |span| try testing.expect(pool.get(span).len > 0),
        .mode => |span| try testing.expect(pool.get(span).len > 0),
        else => {},
    }
    parsed_total += 1;
    if (parsed_total % 128 == 0) states_build();
    for (&worlds, states) |*os, state| {
        const reply = os.run_parsed(parsed);
        if (parsed == .query) {
            try expect_reply_whole(reply, parsed.query.json);
        } else if (reply.len > 0) {
            try testing.expect(std.mem.startsWith(u8, reply, "error: "));
            try testing.expectEqual(@as(u32, 1), count_of(reply, '\n'));
        }
        try os.expect_frames_sane();
        if (os.engine.stopped) state_build(os, state);
    }
}

test "every prefix of every command is refused or runs in every state" {
    states_build();
    for (corpus) |text| {
        var len: usize = 0;
        while (len <= text.len) : (len += 1) try hostile_line(text[0..len]);
    }
}

test "commands spliced from each other are refused or run in every state" {
    states_build();
    parsed_total = 0;
    var prng = stdx.Prng.init(21);
    var buffer: [line_max]u8 = undefined;
    var round: u32 = 0;
    while (round < 12_000) : (round += 1) {
        try hostile_line(splice(&prng, &buffer, &corpus, &tokens));
        try hostile_line(babble(&prng, &buffer));
    }
    // Enough of them were commands for this to have tried the engine.
    try testing.expect(parsed_total > 2000);
}

test "random bytes are refused or run in every state" {
    states_build();
    parsed_total = 0;
    var prng = stdx.Prng.init(22);
    var buffer: [line_max]u8 = undefined;
    var round: u32 = 0;
    while (round < 10_000) : (round += 1) try hostile_line(noise(&prng, &buffer));
}

const Verdict = enum { ok, empty, unknown, missing, bad, too_many, full };

fn verdict(text: []const u8) Verdict {
    var pool: command.StringPool = .{};
    _ = command.parse(text, &pool) catch |err| return switch (err) {
        error.Empty => .empty,
        error.UnknownCommand => .unknown,
        error.MissingArgument => .missing,
        error.BadArgument => .bad,
        error.TooManyArguments => .too_many,
        error.StringPoolFull => .full,
    };
    return .ok;
}

const Edge = struct { []const u8, Verdict };

fn expect_verdicts(edges: []const Edge) !void {
    for (edges) |edge| {
        const found = verdict(edge[0]);
        if (found == edge[1]) continue;
        std.debug.print("{s}: expected {s}, found {s}\n", .{
            edge[0], @tagName(edge[1]), @tagName(found),
        });
        return error.TestUnexpectedResult;
    }
}

test "numbers at their edges are taken as written or refused, never wrapped" {
    try expect_verdicts(&.{
        .{ "workspace +5", .ok },                         .{ "workspace 007", .ok },
        .{ "workspace 255", .ok },                        .{ "workspace 0", .bad },
        .{ "workspace -1", .bad },                        .{ "workspace 256", .bad },
        .{ "workspace 99999999999", .bad },               .{ "workspace 1e9", .bad },
        .{ "workspace 0x10", .bad },                      .{ "focus 00000000001", .ok },
        .{ "focus 2147483647", .ok },                     .{ "focus 2147483648", .bad },
        .{ "focus 4294967295", .bad },                    .{ "focus 0", .bad },
        .{ "focus -1", .bad },                            .{ "focus -2147483648", .bad },
        .{ "focus 1.5", .bad },                           .{ "resize ratio 1", .ok },
        .{ "resize ratio 99", .ok },                      .{ "resize ratio 0", .bad },
        .{ "resize ratio 100", .bad },                    .{ "resize ratio 101", .bad },
        .{ "resize ratio -1", .bad },                     .{ "insert west --ratio 1", .ok },
        .{ "insert west --ratio=99", .ok },               .{ "insert west --ratio 0", .bad },
        .{ "insert west --ratio=100", .bad },             .{ "insert west --ratio=", .bad },
        .{ "move left 2 --ratio 100", .bad },             .{ "resize left -10000", .ok },
        .{ "resize width 10000", .ok },                   .{ "resize left 10001", .bad },
        .{ "resize left -10001", .bad },                  .{ "resize top 99999999999", .bad },
        .{ "move-floating 2147483647 -2147483647", .ok }, .{ "move-floating 2147483648 0", .bad },
        .{ "move-floating 0 -2147483648", .bad },         .{ "move-floating 1e9 0", .bad },
        .{ "move-floating 0x10 0", .bad },                .{ "rotate 0", .bad },
        .{ "rotate 360", .bad },                          .{ "rotate -90", .bad },
        .{ "rotate 090", .ok },                           .{ "float --bounds 0,0,1,1", .ok },
        .{ "float --bounds .999,.999,.001,.001", .ok },   .{ "float --bounds 0,0,0,0", .bad },
        .{ "float --bounds 0,0,1,0", .bad },              .{ "float --bounds 1,1,1,1", .bad },
        .{ "float --bounds 0,0,1.001,1", .bad },          .{ "float --bounds -0.1,0,1,1", .bad },
        .{ "float --bounds 0,0,1,1,1", .bad },            .{ "float --bounds 0,0,1", .bad },
        .{ "float --bounds 0,0,1e0,1", .bad },            .{ "float --bounds 2,2,2,2", .bad },
        .{ "grid 64:64:63:63:1:1", .ok },                 .{ "grid 65:1:0:0:1:1", .bad },
        .{ "grid 1:1:0:0:2:1", .bad },                    .{ "grid 0:0:0:0:0:0", .bad },
        .{ "grid 1:1:0:0:1", .bad },                      .{ "grid 1:1:-1:0:1:1", .bad },
        .{ "focus-monitor 0", .bad },                     .{ "focus-monitor 255", .ok },
        .{ "focus-monitor 256", .bad },
    });
}

test "labels, doubled flags and stray bytes are refused, not misread" {
    try expect_verdicts(&.{
        .{ "label 7up", .bad },                     .{ "label 123", .bad },
        .{ "label west", .bad },                    .{ "label below", .bad },
        .{ "label focused", .bad },                 .{ "label next", .bad },
        .{ "label on", .bad },                      .{ "label west1", .ok },
        .{ "label a\x00b", .bad },                  .{ "label caf\xc3\xa9", .bad },
        .{ "label \"logs", .bad },                  .{ "label -x", .bad },
        .{ "label --clear --clear", .bad },         .{ "zoom --on --off", .bad },
        .{ "zoom --on --on", .bad },                .{ "focus west --wrap --wrap", .too_many },
        .{ "send 2 --follow --follow", .too_many }, .{ "insert --ratio west", .missing },
        .{ "float --bounds", .missing },            .{ "focus --wrap", .missing },
        .{ "move left", .missing },                 .{ "mode", .missing },
        .{ "exec", .missing },                      .{ "query", .missing },
        .{ "balance balance", .too_many },          .{ "a b c d e f g", .too_many },
        .{ "Focus west", .unknown },                .{ "focus\x00 west", .unknown },
        .{ "\xff\xfe", .unknown },                  .{ "focus;west", .unknown },
        .{ "fo", .unknown },                        .{ "", .empty },
        .{ "   ", .empty },                         .{ "\t\r\n", .empty },
        .{ "focus\twest\r\n", .ok },                .{ "  focus   west  ", .ok },
        .{ "focus west\x00", .bad },                .{ "focus \xe2\x86\x90", .bad },
        .{ "query windows --JSON", .too_many },
    });
    try expect_verdicts(&.{
        .{ "label-workspace --clear web", .too_many },
        .{ "query windows --json --json", .too_many },
        .{ "label abcdefghijklmnopqrstuvwx", .ok },
        .{ "label abcdefghijklmnopqrstuvwxy", .bad },
        .{ "insert west --ratio 30 --ratio 40", .too_many },
        .{ "float --bounds 0,0,1,1 --bounds 0,0,1,1", .too_many },
    });
}

var long_line: [128 * 1024]u8 = undefined;

test "a very long line is read to its end or refused, and nothing is written past a limit" {
    @memset(&long_line, ' ');
    @memcpy(long_line[0..5], "focus");
    @memcpy(long_line[100_000..][0..4], "west");
    try testing.expectEqual(Verdict.ok, verdict(long_line[0..100_004]));
    try testing.expectEqual(Verdict.empty, verdict(long_line[5..100_000]));
    for (long_line[0..120_000], 0..) |*byte, index| byte.* = if (index % 2 == 0) 'a' else ' ';
    try testing.expectEqual(Verdict.too_many, verdict(long_line[0..120_000]));
    @memset(&long_line, 'x');
    try testing.expectEqual(Verdict.unknown, verdict(&long_line));
    // What exec runs and the name of a mode are kept in a pool of 16 KiB.
    @memcpy(long_line[0..5], "exec ");
    try testing.expectEqual(Verdict.ok, verdict(long_line[0 .. 5 + 16 * 1024]));
    try testing.expectEqual(Verdict.full, verdict(long_line[0 .. 6 + 16 * 1024]));
    @memcpy(long_line[0..5], "mode ");
    try testing.expectEqual(Verdict.full, verdict(&long_line));
    @memcpy(long_line[0..6], "label ");
    try testing.expectEqual(Verdict.bad, verdict(&long_line));
    // A pool that many commands are read into fills up and then says so.
    var pool: command.StringPool = .{};
    var added: u32 = 0;
    while (command.parse("mode main", &pool)) |_| : (added += 1) {
        try testing.expect(added < 16 * 1024);
    } else |err| try testing.expectEqual(error.StringPoolFull, err);
    try testing.expectEqual(@as(u32, 4096), added);
}

// The configuration file: written by hand, so anything can be in it.

var source_buffer: [96 * 1024]u8 = undefined;
var config_loaded: Config = undefined;
var report_buffer: [4096]u8 = undefined;

const Loaded = struct { ok: bool, report: []const u8, truncated: bool };

/// Loads into config_loaded and returns what was reported, as the shell would print it.
fn load(source: []const u8) Loaded {
    var diagnostics = stdx.Text.init(&report_buffer);
    const ok = config_loaded.load(source, &diagnostics);
    return .{ .ok = ok, .report = diagnostics.slice(), .truncated = diagnostics.truncated };
}

const chord_prefixes = [_][]const u8{
    "",          "cmd-",       "alt-",      "ctrl-",      "shift-",      "cmd-alt-",
    "cmd-ctrl-", "cmd-shift-", "alt-ctrl-", "alt-shift-", "ctrl-shift-", "cmd-alt-ctrl-",
};

/// Writes count bindings, every one on keys of its own.
fn bindings_write(text: *stdx.Text, count: u32) void {
    var written: u32 = 0;
    for (chord_prefixes) |prefix| {
        var code: u16 = 0;
        while (code < 0x80) : (code += 1) {
            if (written == count) return;
            const key = config_module.key_name(code);
            if (std.mem.eql(u8, key, "?")) continue;
            text.print("bind {s}{s} : focus west\n", .{ prefix, key });
            written += 1;
        }
    }
    std.debug.assert(written == count);
}

test "bindings, rules and modes load up to their limits, and one more is refused by its line" {
    var text = stdx.Text.init(&source_buffer);
    bindings_write(&text, config_module.bindings_max);
    try testing.expect(load(text.slice()).ok);
    try testing.expectEqual(@as(u32, config_module.bindings_max), config_loaded.bindings_count);
    text.append("bind cmd-alt-ctrl-shift-a : focus west\n");
    var loaded = load(text.slice());
    try testing.expect(!loaded.ok);
    try testing.expect(std.mem.indexOf(u8, loaded.report, "line 193: TooManyBindings") != null);

    text = stdx.Text.init(&source_buffer);
    var index: u32 = 0;
    while (index < config_module.rules_max) : (index += 1) {
        text.print("rule app=\"App {d}\" title=\"t\" bundle=\"b\" : workspace 16\n", .{index});
    }
    try testing.expect(load(text.slice()).ok);
    try testing.expectEqual(@as(u32, config_module.rules_max), config_loaded.rules_count);
    text.append("rule app=\"One more\" : float\n");
    loaded = load(text.slice());
    try testing.expect(!loaded.ok);
    try testing.expect(std.mem.indexOf(u8, loaded.report, "line 65: TooManyRules") != null);

    text = stdx.Text.init(&source_buffer);
    index = 1;
    while (index < config_module.modes_max) : (index += 1) {
        text.print("bind alt-{d} : mode m{d}\nbind mode:m{d} esc : mode main\n", .{
            index, index, index,
        });
    }
    try testing.expect(load(text.slice()).ok);
    try testing.expectEqual(@as(u8, config_module.modes_max), config_loaded.modes_count);
    text.append("bind mode:m8 esc : mode main\n");
    loaded = load(text.slice());
    try testing.expect(!loaded.ok);
    try testing.expect(std.mem.indexOf(u8, loaded.report, "line 15: TooManyModes") != null);
}

test "64 KiB of bindings, of rules or of one line is refused with a report" {
    var text = stdx.Text.init(&source_buffer);
    var round: u32 = 0;
    while (text.len < 64 * 1024) : (round += 1) bindings_write(&text, 1000);
    var loaded = load(text.slice()[0 .. 64 * 1024]);
    try testing.expect(!loaded.ok);
    try testing.expect(std.mem.startsWith(u8, loaded.report, "line 193: TooManyBindings"));
    // The report does not fit either, and says so instead of running over.
    try testing.expect(loaded.truncated);

    text = stdx.Text.init(&source_buffer);
    round = 0;
    while (text.len < 64 * 1024) : (round += 1) {
        text.print("rule title=\"{d} {s}\" : float\n", .{ round, zeds });
    }
    loaded = load(text.slice()[0 .. 64 * 1024]);
    try testing.expect(!loaded.ok);
    try testing.expect(std.mem.indexOf(u8, loaded.report, "StringPoolFull") != null);

    // One line with no end, a quote that never closes, and bytes that are no text at all.
    @memset(&source_buffer, 'a');
    @memcpy(source_buffer[0..12], "rule title=\"");
    try testing.expect(!load(source_buffer[0 .. 64 * 1024]).ok);
    @memcpy(source_buffer[64 * 1024 ..][0..9], "\" : float");
    loaded = load(source_buffer[0 .. 64 * 1024 + 9]);
    try testing.expect(!loaded.ok);
    try testing.expect(std.mem.startsWith(u8, loaded.report, "line 1: StringPoolFull"));
    var prng = stdx.Prng.init(31);
    for (source_buffer[0 .. 64 * 1024]) |*byte| byte.* = @intCast(prng.below(256));
    try testing.expect(!load(source_buffer[0 .. 64 * 1024]).ok);
}

test "gaps are whole numbers from 0 to 200 and nothing else" {
    const bad = [_][]const u8{
        "gap inner -1",   "gap outer 201",    "gap toggle 99999999999", "gap inner 1e2",
        "gap inner 0x10", "gap inner",        "gap middle 4",           "gap inner 4 4",
        "gap inner 4.5",  "gap  outer  -0x1", "gap inner \x00",         "gap inner 2147483648",
    };
    for (bad) |line| {
        const loaded = load(line);
        try testing.expect(!loaded.ok);
        try testing.expect(std.mem.startsWith(u8, loaded.report, "line 1: BadGap"));
    }
    try testing.expect(load("gap inner +5\r\ngap\touter\t007\r\ngap toggle 200").ok);
    try testing.expectEqual(@as(i32, 5), config_loaded.gap_inner);
    try testing.expectEqual(@as(i32, 7), config_loaded.gap_outer);
    try testing.expectEqual(@as(i32, 200), config_loaded.gap_toggle);
}

test "a rule whose title is longer than a title can be matches nothing and breaks nothing" {
    var text = stdx.Text.init(&source_buffer);
    text.print("rule title=\"{s}\" : float\n", .{zeds[0 .. engine_module.title_max + 1]});
    text.print("rule app=\"{s}\" : ignore\n", .{zeds});
    text.print("rule title=\"{s}\" : workspace 3\n", .{zeds[0..engine_module.title_max]});
    const os = boot(text.slice());
    os.displays(&laptop);
    os.app(10, "Ghostty", "com.mitchellh.ghostty");
    // The title is cut to what the manager keeps of it: the second rule's 96 bytes.
    os.open(1, 10, .{ .title = &zeds });
    os.open(2, 10, .{ .title = zeds[0 .. engine_module.title_max - 1] });
    const first = os.engine.window_find(1).?;
    try testing.expectEqual(engine_module.Mode.tiled, first.mode);
    try testing.expect(!first.ignored);
    try testing.expectEqual(@as(u8, 2), first.workspace);
    try testing.expectEqual(@as(u8, 0), os.engine.window_find(2).?.workspace);
    try os.expect_frames_sane();
}

var config_other: Config = undefined;

/// A display and a few windows of two applications, one of them a native tab.
fn stage(os: *World) void {
    os.displays(&laptop);
    os.app(10, "Ghostty", "com.mitchellh.ghostty");
    os.app(11, "Finder", "com.apple.finder");
    os.open(1, 10, .{});
    os.open(2, 11, .{ .title = "Inbox" });
    os.open(3, 10, .{ .tab_of = 1, .focus = false });
    os.open(4, 11, .{ .title = "Tempo Wallet" });
}

/// Presses every key of the configuration in turn. The commands of a binding run the
/// way the shell runs them: from a copy, because a reload replaces the configuration,
/// and with the mode they name looked up in the configuration in use. Returns how many
/// commands ran.
fn keys_press_all(os: *World) !u32 {
    var ran: u32 = 0;
    var index: u32 = 0;
    while (index < os.engine.config.bindings_count) : (index += 1) {
        const binding = os.engine.config.bindings[index];
        for (binding.commands[0..binding.commands_count]) |cmd| {
            if (cmd == .mode) {
                const name = os.engine.config.strings.get(cmd.mode);
                try testing.expect(os.engine.config.mode_find(name) != null);
                continue;
            }
            const reply = os.run_parsed(cmd);
            if (cmd == .query) try expect_reply_whole(reply, cmd.query.json);
            ran += 1;
        }
        try os.expect_frames_sane();
        if (!os.engine.stopped) continue;
        // A binding quit the manager. Start it again, as launchd does.
        const config = os.engine.config;
        const reload_with = os.reload_with;
        os.init(&config);
        os.reload_with = reload_with;
        stage(os);
    }
    return ran;
}

test "every key of the built-in configuration can be pressed in any order of things" {
    const os = boot("");
    stage(os);
    try testing.expect(try keys_press_all(os) > 80);
    os.displays(&.{});
    _ = try keys_press_all(os);
    os.displays(&three_displays);
    _ = try keys_press_all(os);
    try testing.expect(os.exec_bytes > 0);
}

const odd_bindings =
    \\gap inner 200
    \\gap outer 199
    \\bind alt-q : quit ; focus west ; mode main ; close-others
    \\bind alt-w : mode service ; mode main ; balance ; mode service
    \\bind alt-e : focus west ; quit
    \\bind alt-r : reload
    \\bind alt-t : exec true ; exec false ; close ; close-others
    \\bind alt-y : query windows --json ; query tree ; quit ; quit
    \\bind alt-u : toggle float ; move-floating 2147483647 0 ; tile ; resize ratio 99
    \\bind mode:service esc : mode main
    \\bind mode:service q : quit ; mode main
    \\bind mode:service r : reload
    \\bind mode:service x : exec echo a very long command that sits far into the strings
    \\rule app="Ghostty" : sticky
    \\rule app="Finder" title="Inbox" : workspace 16
    \\rule title="Wallet" : ignore
;

test "bindings that quit, reload and switch modes in odd places run like any others" {
    const os = boot(odd_bindings);
    // The file that a reload finds is another one, much shorter.
    config_other = config_from("bind alt-r : reload\nbind alt-x : exec true\n");
    os.reload_with = &config_other;
    stage(os);
    try testing.expectEqual(@as(u32, 11), os.engine.config.bindings_count);
    _ = try keys_press_all(os);
    // The reload happened: what is in use now is the short file.
    try testing.expectEqual(@as(u32, 2), os.engine.config.bindings_count);
    try testing.expect(os.engine.config.mode_find("service") == null);
    try expect_reply_whole(os.run("query modes --json"), true);
    try expect_reply_whole(os.run("query bindings --json"), true);
    try os.expect_frames_sane();
}

test "a binding cannot reload the configuration and then run what the old one said" {
    // After the reload the rest of the binding would be looked up in the new file.
    try testing.expect(!load("bind alt-r : reload ; exec open -a Ghostty\n").ok);
    try testing.expect(!load("bind alt-r : mode main ; reload\n").ok);
    try testing.expect(!load("bind alt-r : reload ; reload\n").ok);
    try testing.expect(load("bind alt-r : reload\nbind alt-q : quit ; balance\n").ok);
}

const config_extra = [_][]const u8{
    "gap inner 200",
    "gap outer 0",
    "gap toggle 7",
    "bind alt-m : mode resize",
    "bind mode:resize h : resize left -20",
    "bind mode:resize esc : mode main",
    "bind mode:resize q : quit ; mode main",
    "bind ctrl-0x32 : exec true ; focus next --wrap",
    "bind cmd-f19 : float --bounds 0,0,1,1 ; move-floating 2147483647 0 ; zoom --on ; tile",
    "rule app=\"Ghostty\" : sticky",
    "rule app=\"Finder\" title=\"Inbox\" : workspace 16",
    "rule title=\"Wallet\" : ignore",
    "rule bundle=\"com.apple.finder\" : float",
    "rule title=\"a:b \\ c\" : tile",
    "# a comment : with ; signs",
};

const config_tokens = [_][]const u8{
    "bind",           "rule",    "gap",          "inner",          "outer",         "toggle",
    "mode:resize",    "mode:",   "mode:service", "app=\"Finder\"", "title=\"a:b\"", "bundle=\"",
    "app=",           "=\"\"",   ":",            ";",              "cmd-h",         "alt-0x32",
    "alt-0x80",       "hyper-h", "cmd-",         "-",              "float",         "tile",
    "sticky",         "ignore",  "workspace",    "0",              "16",            "17",
    "reload",         "quit",    "mode",         "main",           "service",       "nowhere",
    "\"",             "#",       "\x00",         "\xff\xfe",       "200",           "201",
    "-1",             "exec",    "focus",        "west",           "99999999999",   &zeds,
    "title=\"\xc3\"", "\t",      "balance",      "query",          "windows",
};

var default_lines: [256][]const u8 = undefined;

/// The lines of the built-in configuration that say something, and a few more.
fn config_lines() []const []const u8 {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, config_module.default_source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        default_lines[count] = line;
        count += 1;
    }
    for (config_extra) |line| {
        default_lines[count] = line;
        count += 1;
    }
    return default_lines[0..count];
}

/// A file made of lines of a good configuration, most of them left out and, unless it
/// is to be a clean file, some of them spliced into each other or replaced by noise.
fn config_file(prng: *stdx.Prng, lines: []const []const u8, clean: bool) []const u8 {
    var text = stdx.Text.init(&source_buffer);
    var buffer: [line_max]u8 = undefined;
    const keep = 1 + prng.below(4);
    const odd = if (clean) 0 else 1 + prng.below(40);
    for (lines) |line| {
        if (!prng.chance(keep, 4)) continue;
        if (prng.below(100) < odd) {
            const bytes = prng.chance(1, 8);
            const pool = &config_tokens;
            text.append(if (bytes) noise(prng, &buffer) else splice(prng, &buffer, lines, pool));
        } else {
            text.append(line);
        }
        text.append(if (prng.chance(1, 4)) "\r\n" else "\n");
    }
    std.debug.assert(!text.truncated);
    return text.slice();
}

/// What a configuration that loaded promises to whoever uses it.
fn config_check(config: *const Config) !void {
    const gap_max = config_module.gap_max;
    try testing.expect(config.gap_inner >= 0 and config.gap_inner <= gap_max);
    try testing.expect(config.gap_outer >= 0 and config.gap_outer <= gap_max);
    try testing.expect(config.gap_toggle >= 0 and config.gap_toggle <= gap_max);
    try testing.expect(config.bindings_count <= config_module.bindings_max);
    try testing.expect(config.rules_count <= config_module.rules_max);
    try testing.expect(config.modes_count >= 1 and config.modes_count <= config_module.modes_max);
    try testing.expectEqualStrings("main", config.mode_name(0));
    for (config.bindings[0..config.bindings_count]) |*binding| {
        try testing.expect(binding.mode < config.modes_count);
        try testing.expect(binding.commands_count >= 1);
        try testing.expect(binding.commands_count <= config_module.commands_per_binding_max);
        try testing.expect(config.strings.get(binding.keys).len > 0);
        try testing.expect(config.strings.get(binding.source).len > 0);
        for (binding.commands[0..binding.commands_count]) |cmd| switch (cmd) {
            .exec => |span| try testing.expect(config.strings.get(span).len > 0),
            .mode => |span| {
                try testing.expect(config.mode_find(config.strings.get(span)) != null);
            },
            else => {},
        };
    }
    for (config.rules[0..config.rules_count]) |rule| {
        const app = config.strings.get(rule.app);
        const bundle = config.strings.get(rule.bundle);
        const title = config.strings.get(rule.title);
        try testing.expect(app.len + bundle.len + title.len > 0);
        if (rule.action == .workspace) {
            try testing.expect(rule.action.workspace < engine_module.workspaces_max);
        }
    }
}

test "a configuration spliced from good and bad lines loads whole or is refused with a report" {
    const lines = config_lines();
    var prng = stdx.Prng.init(41);
    var loaded_count: u32 = 0;
    var round: u32 = 0;
    while (round < 400) : (round += 1) {
        const loaded = load(config_file(&prng, lines, round % 4 == 0));
        if (!loaded.ok) {
            try testing.expect(loaded.report.len > 0);
            continue;
        }
        loaded_count += 1;
        try config_check(&config_loaded);
        const os = &world_one;
        os.init(&config_loaded);
        stage(os);
        _ = try keys_press_all(os);
        try expect_reply_whole(os.run("query bindings --json"), true);
        try expect_reply_whole(os.run("query bindings"), false);
        try expect_reply_whole(os.run("query modes --json"), true);
    }
    try testing.expect(loaded_count > 20);
}

test "a reload that takes away the rule that floated a window leaves the window floating" {
    const os = boot(
        \\gap inner 10
        \\bind alt-m : mode service
        \\bind mode:service esc : mode main
        \\rule app="Finder" : float
        \\rule app="Ghostty" : workspace 2
    );
    stage(os);
    const finder = os.engine.window_find(2).?;
    try testing.expectEqual(engine_module.Mode.floating, finder.mode);
    try testing.expectEqual(@as(u8, 1), os.engine.window_find(1).?.workspace);
    config_other = config_from("gap inner 0\nbind alt-r : reload\n");
    os.reload_with = &config_other;
    _ = os.run("reload");
    // Windows stay as they were: rules are for windows that appear from now on.
    try testing.expectEqual(engine_module.Mode.floating, finder.mode);
    try testing.expectEqual(@as(u8, 1), os.engine.window_find(1).?.workspace);
    try testing.expect(os.engine.config.mode_find("service") == null);
    try testing.expectEqualStrings("{\"modes\":[{\"name\":\"main\",\"active\":false}]}\n", os.run(
        "query modes --json",
    ));
    os.open(5, 11, .{});
    try testing.expectEqual(engine_module.Mode.tiled, os.engine.window_find(5).?.mode);
    try testing.expectEqual(@as(u8, 0), os.engine.window_find(5).?.workspace);
    // The window that a rule floated can still be tiled by hand.
    _ = os.run("tile 2");
    try testing.expectEqual(engine_module.Mode.tiled, finder.mode);
    try os.expect_frames_sane();
}

test "a title that comes late and sends the window in use away leaves focus behind" {
    const os = boot("rule title=\"Inbox\" : workspace 2\n");
    os.displays(&laptop);
    os.app(10, "Ghostty", "com.mitchellh.ghostty");
    os.open(1, 10, .{});
    os.open(2, 10, .{});
    try testing.expectEqual(@as(WindowId, 2), os.engine.focused_window);
    os.step(.{ .window_title_changed = .{ .id = 2, .title = "Inbox" } });
    try testing.expectEqual(@as(u8, 1), os.engine.window_find(2).?.workspace);
    try testing.expectEqual(@as(u8, 0), os.engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 1), os.engine.focused_window);
    try testing.expectEqual(@as(WindowId, 1), os.os_focus);
    // The same with no other window to take the focus.
    os.step(.{ .window_destroyed = 1 });
    os.open(3, 10, .{});
    os.step(.{ .window_title_changed = .{ .id = 3, .title = "Inbox" } });
    try testing.expectEqual(@as(WindowId, 0), os.engine.focused_window);
    try testing.expectEqual(@as(u8, 0), os.engine.workspace_current());
    try os.expect_frames_sane();
}

test "a window that its rule keeps on the workspace in use takes focus like any other" {
    const os = boot("rule app=\"Finder\" : workspace 1\nrule app=\"Slack\" : workspace 3\n");
    os.displays(&laptop);
    os.app(11, "Finder", "com.apple.finder");
    os.app(12, "Slack", "com.tinyspeck.slackmacgap");
    os.open(1, 11, .{});
    try testing.expectEqual(@as(WindowId, 1), os.engine.focused_window);
    // A window that its rule sends away is another matter: it does not pull the
    // workspace in use along, however much its application asks for focus.
    os.open(2, 12, .{});
    try testing.expectEqual(@as(u8, 2), os.engine.window_find(2).?.workspace);
    try testing.expectEqual(@as(u8, 0), os.engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 1), os.engine.focused_window);
    try testing.expectEqual(@as(WindowId, 1), os.os_focus);
}

// The simulated macOS, with its faults, under a configuration that is all edges.

var sim_engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

const edge_config =
    \\gap inner 200
    \\gap outer 200
    \\gap toggle 0
    \\rule app="Ghostty" : sticky
    \\rule app="Slack" : workspace 16
    \\rule title="Inbox" : float
    \\rule app="Zed" title="main.zig" : ignore
    \\rule title="Tempo Wallet" : tile
    \\rule bundle="com.apple.finder" : workspace 1
    \\rule app="Chrome" title="Untitled" : sticky
    \\rule title="~" : workspace 2
;

test "the simulated desktop holds up under rules of every kind and the widest gaps" {
    const config = config_from(edge_config);
    var seed: u64 = 1;
    while (seed <= 8) : (seed += 1) {
        sim_engine.init(&config);
        simulator.init(&sim_engine, .{ .seed = seed, .faults = true });
        simulator.run(500);
    }
}

const rule_matchers = [_][]const u8{
    "app=\"Ghostty\"",
    "app=\"Brave\"",
    "app=\"Chrome\"",
    "app=\"Slack\"",
    "app=\"Finder\"",
    "app=\"Zed\"",
    "app=\"o\"",
    "title=\"Untitled\"",
    "title=\"main.zig\"",
    "title=\"Inbox\"",
    "title=\"Tempo Wallet\"",
    "title=\"~\"",
    "title=\"e\"",
    "bundle=\"com.apple.finder\"",
    "bundle=\"dev.zed.Zed\"",
    "app=\"Ghostty\" title=\"Inbox\"",
    "app=\"e\" title=\"n\"",
};

const rule_actions = [_][]const u8{
    "float",       "tile",        "sticky",      "ignore",
    "workspace 1", "workspace 2", "workspace 3", "workspace 16",
};

test "the simulated desktop holds up under any rules and any gaps" {
    var seed: u64 = 1;
    while (seed <= 16) : (seed += 1) {
        var prng = stdx.Prng.init(seed *% 7919);
        var text = stdx.Text.init(&source_buffer);
        text.print("gap inner {d}\ngap outer {d}\ngap toggle {d}\n", .{
            prng.below(4) * prng.below(67), prng.below(4) * prng.below(67), prng.below(201),
        });
        var rules = prng.below(7);
        while (rules > 0) : (rules -= 1) {
            const matcher = rule_matchers[prng.below(rule_matchers.len)];
            const action = rule_actions[prng.below(rule_actions.len)];
            text.print("rule {s} : {s}\n", .{ matcher, action });
        }
        const config = config_from(text.slice());
        sim_engine.init(&config);
        simulator.init(&sim_engine, .{ .seed = seed, .faults = true });
        simulator.run(400);
    }
}
