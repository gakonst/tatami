//! The command language shared by key bindings and the command line client.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const Direction = geometry.Direction;

pub const Target = union(enum) {
    /// One-based index, as typed by the user.
    index: u8,
    next,
    prev,
    recent,
    /// The lowest numbered empty workspace. Only meaningful for workspaces.
    new,
};

pub const Toggle = enum { split, float, zoom_parent, zoom_fullscreen, sticky, gaps };
pub const MirrorAxis = enum { x_axis, y_axis };
pub const Dimension = enum { width, height };
pub const Layout = enum { bsp, float };
pub const Query = enum { windows, workspaces, monitors, focus, stats };

pub const Grid = struct { rows: u8, cols: u8, x: u8, y: u8, w: u8, h: u8 };
pub const Move = struct { target: Target, follow: bool };

/// A span inside the string pool that the command was parsed into.
pub const Span = struct { offset: u16, len: u16 };

pub const Command = union(enum) {
    focus: Direction,
    swap: Direction,
    warp: Direction,
    insert: Direction,
    resize_edge: struct { edge: Direction, delta: i32 },
    resize_dimension: struct { dimension: Dimension, delta: i32 },
    balance,
    retile,
    rotate: u16,
    mirror: MirrorAxis,
    toggle: Toggle,
    workspace: Target,
    send: Move,
    focus_monitor: Target,
    send_monitor: Move,
    grid: Grid,
    move_floating: struct { dx: i32, dy: i32 },
    layout: Layout,
    close,
    close_others,
    exec: Span,
    query: Query,
    reload,
    /// Switch the active set of key bindings. The name is resolved by whoever runs it.
    mode: Span,
    quit,
};

pub const ParseError = error{
    Empty,
    UnknownCommand,
    MissingArgument,
    BadArgument,
    TooManyArguments,
    StringPoolFull,
};

pub const words_max = 6;

const Words = struct {
    items: [words_max][]const u8 = undefined,
    count: u32 = 0,
    /// Everything after the first word, trimmed. Used by exec.
    rest: []const u8 = "",
};

fn is_space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

pub fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = text.len;
    while (start < end and is_space(text[start])) start += 1;
    while (end > start and is_space(text[end - 1])) end -= 1;
    return text[start..end];
}

fn split_words(text: []const u8) ParseError!Words {
    var words: Words = .{};
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and is_space(text[index])) index += 1;
        if (index == text.len) break;
        const start = index;
        while (index < text.len and !is_space(text[index])) index += 1;
        if (words.count == words_max) return error.TooManyArguments;
        words.items[words.count] = text[start..index];
        words.count += 1;
        if (words.count == 1) words.rest = trim(text[index..]);
    }
    assert(words.count <= words_max);
    return words;
}

fn parse_direction(word: []const u8) ?Direction {
    const names = [_]struct { []const u8, Direction }{
        .{ "west", .west },   .{ "left", .west },
        .{ "south", .south }, .{ "down", .south },
        .{ "north", .north }, .{ "up", .north },
        .{ "east", .east },   .{ "right", .east },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, word, entry[0])) return entry[1];
    }
    return null;
}

fn parse_target(word: []const u8, allow_new: bool) ParseError!Target {
    if (std.mem.eql(u8, word, "next")) return .next;
    if (std.mem.eql(u8, word, "prev")) return .prev;
    if (std.mem.eql(u8, word, "recent")) return .recent;
    if (std.mem.eql(u8, word, "new")) return if (allow_new) .new else error.BadArgument;
    const value = stdx.parse_int(word) orelse return error.BadArgument;
    if (value < 1 or value > 255) return error.BadArgument;
    return .{ .index = @intCast(value) };
}

fn parse_move(words: *const Words, allow_new: bool) ParseError!Move {
    if (words.count < 2) return error.MissingArgument;
    if (words.count > 3) return error.TooManyArguments;
    var move: Move = .{ .target = try parse_target(words.items[1], allow_new), .follow = false };
    if (words.count == 3) {
        if (!std.mem.eql(u8, words.items[2], "--follow")) return error.BadArgument;
        move.follow = true;
    }
    return move;
}

fn parse_grid(word: []const u8) ParseError!Grid {
    var values: [6]u8 = undefined;
    var count: u32 = 0;
    var parts = std.mem.splitScalar(u8, word, ':');
    while (parts.next()) |part| {
        if (count == values.len) return error.BadArgument;
        const value = stdx.parse_int(part) orelse return error.BadArgument;
        if (value < 0 or value > 64) return error.BadArgument;
        values[count] = @intCast(value);
        count += 1;
    }
    if (count != values.len) return error.BadArgument;
    const grid: Grid = .{
        .rows = values[0],
        .cols = values[1],
        .x = values[2],
        .y = values[3],
        .w = values[4],
        .h = values[5],
    };
    if (grid.rows == 0 or grid.cols == 0 or grid.w == 0 or grid.h == 0) return error.BadArgument;
    if (grid.x + grid.w > grid.cols or grid.y + grid.h > grid.rows) return error.BadArgument;
    return grid;
}

fn parse_enum(comptime E: type, word: []const u8) ParseError!E {
    var name: [32]u8 = undefined;
    if (word.len == 0 or word.len > name.len) return error.BadArgument;
    for (word, 0..) |byte, index| {
        name[index] = if (byte == '-') '_' else byte;
    }
    return std.meta.stringToEnum(E, name[0..word.len]) orelse error.BadArgument;
}

fn expect_count(words: *const Words, count: u32) ParseError!void {
    if (words.count < count) return error.MissingArgument;
    if (words.count > count) return error.TooManyArguments;
}

/// Appends text to the pool. The pool is append only; a reload starts a fresh one.
pub const StringPool = struct {
    bytes: [8192]u8 = undefined,
    len: u32 = 0,

    pub fn add(pool: *StringPool, text: []const u8) ParseError!Span {
        if (text.len > pool.bytes.len - pool.len) return error.StringPoolFull;
        const span: Span = .{ .offset = @intCast(pool.len), .len = @intCast(text.len) };
        @memcpy(pool.bytes[pool.len..][0..text.len], text);
        pool.len += @intCast(text.len);
        return span;
    }

    pub fn get(pool: *const StringPool, span: Span) []const u8 {
        assert(@as(u32, span.offset) + span.len <= pool.len);
        return pool.bytes[span.offset..][0..span.len];
    }
};

pub fn parse(text: []const u8, pool: *StringPool) ParseError!Command {
    const words = try split_words(text);
    if (words.count == 0) return error.Empty;
    const name = words.items[0];
    if (std.mem.eql(u8, name, "exec")) {
        if (words.rest.len == 0) return error.MissingArgument;
        return .{ .exec = try pool.add(words.rest) };
    }
    if (std.mem.eql(u8, name, "mode")) {
        try expect_count(&words, 2);
        return .{ .mode = try pool.add(words.items[1]) };
    }
    if (parse_directional(name, &words)) |result| return try result;
    if (parse_simple(name, &words)) |result| return try result;
    return parse_compound(name, &words);
}

fn parse_directional(name: []const u8, words: *const Words) ?ParseError!Command {
    const Kind = enum { focus, swap, warp, insert };
    const kind = std.meta.stringToEnum(Kind, name) orelse return null;
    if (words.count < 2) return error.MissingArgument;
    if (words.count > 2) return error.TooManyArguments;
    const direction = parse_direction(words.items[1]) orelse return error.BadArgument;
    return switch (kind) {
        .focus => .{ .focus = direction },
        .swap => .{ .swap = direction },
        .warp => .{ .warp = direction },
        .insert => .{ .insert = direction },
    };
}

fn parse_simple(name: []const u8, words: *const Words) ?ParseError!Command {
    const Kind = enum { balance, retile, close, @"close-others", reload, quit };
    const kind = std.meta.stringToEnum(Kind, name) orelse return null;
    if (words.count > 1) return error.TooManyArguments;
    return switch (kind) {
        .balance => .balance,
        .retile => .retile,
        .close => .close,
        .@"close-others" => .close_others,
        .reload => .reload,
        .quit => .quit,
    };
}

fn parse_compound(name: []const u8, words: *const Words) ParseError!Command {
    const Kind = enum {
        resize,
        rotate,
        mirror,
        toggle,
        workspace,
        send,
        @"focus-monitor",
        @"send-monitor",
        grid,
        @"move-floating",
        layout,
        query,
    };
    const kind = std.meta.stringToEnum(Kind, name) orelse return error.UnknownCommand;
    switch (kind) {
        .resize => return parse_resize(words),
        .rotate => {
            try expect_count(words, 2);
            const degrees = stdx.parse_int(words.items[1]) orelse return error.BadArgument;
            if (degrees != 90 and degrees != 180 and degrees != 270) return error.BadArgument;
            return .{ .rotate = @intCast(degrees) };
        },
        .mirror => {
            try expect_count(words, 2);
            return .{ .mirror = try parse_enum(MirrorAxis, words.items[1]) };
        },
        .toggle => {
            try expect_count(words, 2);
            return .{ .toggle = try parse_enum(Toggle, words.items[1]) };
        },
        .workspace => {
            try expect_count(words, 2);
            return .{ .workspace = try parse_target(words.items[1], true) };
        },
        .send => return .{ .send = try parse_move(words, true) },
        .@"focus-monitor" => {
            try expect_count(words, 2);
            return .{ .focus_monitor = try parse_target(words.items[1], false) };
        },
        .@"send-monitor" => return .{ .send_monitor = try parse_move(words, false) },
        .grid => {
            try expect_count(words, 2);
            return .{ .grid = try parse_grid(words.items[1]) };
        },
        .@"move-floating" => {
            try expect_count(words, 3);
            const dx = stdx.parse_int(words.items[1]) orelse return error.BadArgument;
            const dy = stdx.parse_int(words.items[2]) orelse return error.BadArgument;
            return .{ .move_floating = .{ .dx = dx, .dy = dy } };
        },
        .layout => {
            try expect_count(words, 2);
            return .{ .layout = try parse_enum(Layout, words.items[1]) };
        },
        .query => {
            try expect_count(words, 2);
            return .{ .query = try parse_enum(Query, words.items[1]) };
        },
    }
}

fn parse_resize(words: *const Words) ParseError!Command {
    try expect_count(words, 3);
    const delta = stdx.parse_int(words.items[2]) orelse return error.BadArgument;
    if (delta < -10_000 or delta > 10_000) return error.BadArgument;
    const what = words.items[1];
    if (std.mem.eql(u8, what, "width")) {
        return .{ .resize_dimension = .{ .dimension = .width, .delta = delta } };
    }
    if (std.mem.eql(u8, what, "height")) {
        return .{ .resize_dimension = .{ .dimension = .height, .delta = delta } };
    }
    const edges = [_]struct { []const u8, Direction }{
        .{ "left", .west }, .{ "right", .east }, .{ "top", .north }, .{ "bottom", .south },
    };
    for (edges) |entry| {
        if (std.mem.eql(u8, what, entry[0])) {
            return .{ .resize_edge = .{ .edge = entry[1], .delta = delta } };
        }
    }
    return error.BadArgument;
}

const testing = std.testing;

test "parse commands" {
    var pool: StringPool = .{};
    try testing.expectEqual(Command{ .focus = .west }, try parse("focus west", &pool));
    try testing.expectEqual(Command{ .focus = .west }, try parse("  focus   left ", &pool));
    try testing.expectEqual(Command{ .warp = .north }, try parse("warp up", &pool));
    try testing.expectEqual(Command.balance, try parse("balance", &pool));
    try testing.expectEqual(Command{ .rotate = 90 }, try parse("rotate 90", &pool));
    try testing.expectEqual(Command{ .mirror = .y_axis }, try parse("mirror y-axis", &pool));
    try testing.expectEqual(
        Command{ .toggle = .zoom_fullscreen },
        try parse("toggle zoom-fullscreen", &pool),
    );
    try testing.expectEqual(
        Command{ .workspace = .{ .index = 10 } },
        try parse("workspace 10", &pool),
    );
    try testing.expectEqual(Command{ .workspace = .new }, try parse("workspace new", &pool));
    try testing.expectEqual(
        Command{ .send = .{ .target = .next, .follow = true } },
        try parse("send next --follow", &pool),
    );
    try testing.expectEqual(
        Command{ .resize_edge = .{ .edge = .west, .delta = -20 } },
        try parse("resize left -20", &pool),
    );
    try testing.expectEqual(
        Command{ .resize_dimension = .{ .dimension = .width, .delta = 50 } },
        try parse("resize width +50", &pool),
    );
    try testing.expectEqual(
        Command{ .grid = .{ .rows = 4, .cols = 4, .x = 1, .y = 1, .w = 2, .h = 2 } },
        try parse("grid 4:4:1:1:2:2", &pool),
    );
    const exec = try parse("exec open -a Ghostty", &pool);
    try testing.expectEqualStrings("open -a Ghostty", pool.get(exec.exec));
}

test "parse rejects malformed commands" {
    var pool: StringPool = .{};
    try testing.expectError(error.Empty, parse("   ", &pool));
    try testing.expectError(error.UnknownCommand, parse("fly away", &pool));
    const mode = try parse("mode service", &pool);
    try testing.expectEqualStrings("service", pool.get(mode.mode));
    try testing.expectError(error.MissingArgument, parse("mode", &pool));
    try testing.expectError(error.MissingArgument, parse("focus", &pool));
    try testing.expectError(error.BadArgument, parse("focus sideways", &pool));
    try testing.expectError(error.TooManyArguments, parse("balance now", &pool));
    try testing.expectError(error.BadArgument, parse("rotate 45", &pool));
    try testing.expectError(error.BadArgument, parse("workspace 0", &pool));
    try testing.expectError(error.BadArgument, parse("focus-monitor new", &pool));
    try testing.expectError(error.BadArgument, parse("grid 1:2:2:0:1:1", &pool));
    try testing.expectError(error.BadArgument, parse("send 3 --now", &pool));
    try testing.expectError(error.MissingArgument, parse("exec", &pool));
}
