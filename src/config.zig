//! Configuration: gaps, key bindings and window rules, parsed from a line-based file.
//!
//! Loading is all or nothing. Every problem is reported with its line number, and a file
//! with any problem leaves the caller's previous configuration untouched.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const command = @import("command.zig");
const Command = command.Command;
const Span = command.Span;

pub const bindings_max = 192;
pub const rules_max = 64;
pub const commands_per_binding_max = 4;
pub const gap_max = 200;

pub const default_source = @embedFile("default.conf");

pub const Modifiers = packed struct(u8) {
    cmd: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    padding: u4 = 0,
};

pub const Binding = struct {
    modifiers: Modifiers,
    /// macOS virtual key code (ANSI layout positions).
    keycode: u16,
    commands: [commands_per_binding_max]Command,
    commands_count: u8,
};

pub const RuleAction = union(enum) {
    float,
    tile,
    sticky,
    ignore,
    /// Zero-based workspace index.
    workspace: u8,
};

pub const Rule = struct {
    app: Span,
    bundle: Span,
    title: Span,
    action: RuleAction,
};

const Key = struct { name: []const u8, code: u16 };

const keys = [_]Key{
    .{ .name = "a", .code = 0 },            .{ .name = "s", .code = 1 },
    .{ .name = "d", .code = 2 },            .{ .name = "f", .code = 3 },
    .{ .name = "h", .code = 4 },            .{ .name = "g", .code = 5 },
    .{ .name = "z", .code = 6 },            .{ .name = "x", .code = 7 },
    .{ .name = "c", .code = 8 },            .{ .name = "v", .code = 9 },
    .{ .name = "b", .code = 11 },           .{ .name = "q", .code = 12 },
    .{ .name = "w", .code = 13 },           .{ .name = "e", .code = 14 },
    .{ .name = "r", .code = 15 },           .{ .name = "y", .code = 16 },
    .{ .name = "t", .code = 17 },           .{ .name = "1", .code = 18 },
    .{ .name = "2", .code = 19 },           .{ .name = "3", .code = 20 },
    .{ .name = "4", .code = 21 },           .{ .name = "6", .code = 22 },
    .{ .name = "5", .code = 23 },           .{ .name = "equal", .code = 24 },
    .{ .name = "9", .code = 25 },           .{ .name = "7", .code = 26 },
    .{ .name = "minus", .code = 27 },       .{ .name = "8", .code = 28 },
    .{ .name = "0", .code = 29 },           .{ .name = "rightbracket", .code = 30 },
    .{ .name = "o", .code = 31 },           .{ .name = "u", .code = 32 },
    .{ .name = "leftbracket", .code = 33 }, .{ .name = "i", .code = 34 },
    .{ .name = "p", .code = 35 },           .{ .name = "enter", .code = 36 },
    .{ .name = "l", .code = 37 },           .{ .name = "j", .code = 38 },
    .{ .name = "quote", .code = 39 },       .{ .name = "k", .code = 40 },
    .{ .name = "semicolon", .code = 41 },   .{ .name = "backslash", .code = 42 },
    .{ .name = "comma", .code = 43 },       .{ .name = "slash", .code = 44 },
    .{ .name = "n", .code = 45 },           .{ .name = "m", .code = 46 },
    .{ .name = "period", .code = 47 },      .{ .name = "tab", .code = 48 },
    .{ .name = "space", .code = 49 },       .{ .name = "backtick", .code = 50 },
    .{ .name = "backspace", .code = 51 },   .{ .name = "esc", .code = 53 },
    .{ .name = "left", .code = 123 },       .{ .name = "right", .code = 124 },
    .{ .name = "down", .code = 125 },       .{ .name = "up", .code = 126 },
    .{ .name = "f1", .code = 122 },         .{ .name = "f2", .code = 120 },
    .{ .name = "f3", .code = 99 },          .{ .name = "f4", .code = 118 },
    .{ .name = "f5", .code = 96 },          .{ .name = "f6", .code = 97 },
    .{ .name = "f7", .code = 98 },          .{ .name = "f8", .code = 100 },
    .{ .name = "f9", .code = 101 },         .{ .name = "f10", .code = 109 },
    .{ .name = "f11", .code = 103 },        .{ .name = "f12", .code = 111 },
};

pub fn key_name(code: u16) []const u8 {
    for (keys) |key| {
        if (key.code == code) return key.name;
    }
    return "?";
}

const LineError = error{
    UnknownDirective,
    MissingSeparator,
    BadKey,
    BadModifier,
    DuplicateBinding,
    TooManyBindings,
    TooManyCommands,
    TooManyRules,
    BadGap,
    BadRule,
    BadAction,
} || command.ParseError;

pub const Config = struct {
    gap_inner: i32,
    gap_outer: i32,
    gap_toggle: i32,
    bindings: [bindings_max]Binding,
    bindings_count: u32,
    rules: [rules_max]Rule,
    rules_count: u32,
    strings: command.StringPool,

    pub fn init(config: *Config) void {
        config.gap_inner = 0;
        config.gap_outer = 0;
        config.gap_toggle = 10;
        config.bindings_count = 0;
        config.rules_count = 0;
        config.strings = .{};
    }

    /// Parses source into config. On failure config is left in an unspecified state, so
    /// callers parse into a scratch Config and copy it over the live one on success.
    pub fn load(config: *Config, source: []const u8, diagnostics: *stdx.Text) bool {
        config.init();
        var ok = true;
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            line_number += 1;
            const line = command.trim(raw);
            if (line.len == 0 or line[0] == '#') continue;
            config.load_line(line) catch |err| {
                ok = false;
                diagnostics.print("line {d}: {s}: {s}\n", .{ line_number, @errorName(err), line });
            };
        }
        assert(config.bindings_count <= bindings_max);
        assert(config.rules_count <= rules_max);
        return ok;
    }

    pub fn load_default(config: *Config) void {
        var buffer: [1024]u8 = undefined;
        var diagnostics = stdx.Text.init(&buffer);
        const ok = config.load(default_source, &diagnostics);
        assert(ok);
        assert(config.bindings_count > 0);
    }

    fn load_line(config: *Config, line: []const u8) LineError!void {
        const space = std.mem.indexOfAny(u8, line, " \t") orelse return error.UnknownDirective;
        const directive = line[0..space];
        const rest = command.trim(line[space..]);
        if (std.mem.eql(u8, directive, "gap")) return config.load_gap(rest);
        if (std.mem.eql(u8, directive, "bind")) return config.load_binding(rest);
        if (std.mem.eql(u8, directive, "rule")) return config.load_rule(rest);
        return error.UnknownDirective;
    }

    fn load_gap(config: *Config, rest: []const u8) LineError!void {
        const space = std.mem.indexOfAny(u8, rest, " \t") orelse return error.BadGap;
        const value = stdx.parse_int(command.trim(rest[space..])) orelse return error.BadGap;
        if (value < 0 or value > gap_max) return error.BadGap;
        const which = rest[0..space];
        if (std.mem.eql(u8, which, "inner")) {
            config.gap_inner = value;
        } else if (std.mem.eql(u8, which, "outer")) {
            config.gap_outer = value;
        } else if (std.mem.eql(u8, which, "toggle")) {
            config.gap_toggle = value;
        } else {
            return error.BadGap;
        }
    }

    fn load_binding(config: *Config, rest: []const u8) LineError!void {
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.MissingSeparator;
        var binding: Binding = undefined;
        binding.commands_count = 0;
        try parse_chord(command.trim(rest[0..colon]), &binding);
        for (config.bindings[0..config.bindings_count]) |*other| {
            const same_modifiers =
                @as(u8, @bitCast(other.modifiers)) == @as(u8, @bitCast(binding.modifiers));
            if (same_modifiers and other.keycode == binding.keycode) return error.DuplicateBinding;
        }
        var parts = std.mem.splitScalar(u8, rest[colon + 1 ..], ';');
        while (parts.next()) |part| {
            if (binding.commands_count == commands_per_binding_max) return error.TooManyCommands;
            binding.commands[binding.commands_count] = try command.parse(part, &config.strings);
            binding.commands_count += 1;
        }
        assert(binding.commands_count > 0);
        if (config.bindings_count == bindings_max) return error.TooManyBindings;
        config.bindings[config.bindings_count] = binding;
        config.bindings_count += 1;
    }

    fn load_rule(config: *Config, rest: []const u8) LineError!void {
        const colon = find_separator(rest) orelse return error.MissingSeparator;
        var rule: Rule = .{
            .app = .{ .offset = 0, .len = 0 },
            .bundle = .{ .offset = 0, .len = 0 },
            .title = .{ .offset = 0, .len = 0 },
            .action = try parse_action(command.trim(rest[colon + 1 ..])),
        };
        var conditions = command.trim(rest[0..colon]);
        var conditions_count: u32 = 0;
        while (conditions.len > 0) : (conditions_count += 1) {
            if (conditions_count == 3) return error.BadRule;
            const equals = std.mem.indexOfScalar(u8, conditions, '=') orelse return error.BadRule;
            const name = conditions[0..equals];
            const after = conditions[equals + 1 ..];
            if (after.len < 2 or after[0] != '"') return error.BadRule;
            const close = std.mem.indexOfScalarPos(u8, after, 1, '"') orelse return error.BadRule;
            const value = after[1..close];
            if (value.len == 0) return error.BadRule;
            const span = try config.strings.add(value);
            if (std.mem.eql(u8, name, "app")) {
                rule.app = span;
            } else if (std.mem.eql(u8, name, "bundle")) {
                rule.bundle = span;
            } else if (std.mem.eql(u8, name, "title")) {
                rule.title = span;
            } else {
                return error.BadRule;
            }
            conditions = command.trim(after[close + 1 ..]);
        }
        if (conditions_count == 0) return error.BadRule;
        if (config.rules_count == rules_max) return error.TooManyRules;
        config.rules[config.rules_count] = rule;
        config.rules_count += 1;
    }

    pub fn binding_find(config: *const Config, modifiers: Modifiers, keycode: u16) ?*const Binding {
        for (config.bindings[0..config.bindings_count]) |*binding| {
            const same = @as(u8, @bitCast(binding.modifiers)) == @as(u8, @bitCast(modifiers));
            if (same and binding.keycode == keycode) return binding;
        }
        return null;
    }
};

/// The colon that separates rule conditions from the action: the first one outside quotes.
fn find_separator(text: []const u8) ?usize {
    var quoted = false;
    for (text, 0..) |byte, index| {
        if (byte == '"') quoted = !quoted;
        if (byte == ':' and !quoted) return index;
    }
    return null;
}

fn parse_action(text: []const u8) LineError!RuleAction {
    if (std.mem.eql(u8, text, "float")) return .float;
    if (std.mem.eql(u8, text, "tile")) return .tile;
    if (std.mem.eql(u8, text, "sticky")) return .sticky;
    if (std.mem.eql(u8, text, "ignore")) return .ignore;
    const prefix = "workspace ";
    if (std.mem.startsWith(u8, text, prefix)) {
        const value =
            stdx.parse_int(command.trim(text[prefix.len..])) orelse return error.BadAction;
        if (value < 1 or value > 16) return error.BadAction;
        return .{ .workspace = @intCast(value - 1) };
    }
    return error.BadAction;
}

fn parse_chord(text: []const u8, binding: *Binding) LineError!void {
    binding.modifiers = .{};
    var key_found = false;
    var parts = std.mem.splitScalar(u8, text, '-');
    while (parts.next()) |part| {
        if (key_found) return error.BadKey;
        if (parts.peek() == null) {
            for (keys) |key| {
                if (std.mem.eql(u8, key.name, part)) {
                    binding.keycode = key.code;
                    key_found = true;
                }
            }
            if (!key_found) return error.BadKey;
        } else if (std.mem.eql(u8, part, "cmd")) {
            binding.modifiers.cmd = true;
        } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "option")) {
            binding.modifiers.alt = true;
        } else if (std.mem.eql(u8, part, "ctrl")) {
            binding.modifiers.ctrl = true;
        } else if (std.mem.eql(u8, part, "shift")) {
            binding.modifiers.shift = true;
        } else {
            return error.BadModifier;
        }
    }
    if (!key_found) return error.BadKey;
}

const testing = std.testing;

test "the built-in configuration loads" {
    var config: Config = undefined;
    config.load_default();
    try testing.expectEqual(@as(u32, 86), config.bindings_count);
    try testing.expectEqual(@as(u32, 23), config.rules_count);
    const focus = config.binding_find(.{ .cmd = true }, 4).?;
    try testing.expectEqual(Command{ .focus = .west }, focus.commands[0]);
    const float = config.binding_find(.{ .alt = true }, 17).?;
    try testing.expectEqual(@as(u8, 2), float.commands_count);
    try testing.expectEqual(Command{ .toggle = .float }, float.commands[0]);
    const ten = config.binding_find(.{ .alt = true }, 29).?;
    try testing.expectEqual(Command{ .workspace = .{ .index = 10 } }, ten.commands[0]);
    const wallet = config.rules[config.rules_count - 1];
    try testing.expectEqualStrings("com.brave.Browser", config.strings.get(wallet.bundle));
    try testing.expectEqualStrings("wallet.tempo.xyz", config.strings.get(wallet.title));
}

test "a bad file reports every bad line and loads nothing partially" {
    var config: Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const source =
        \\gap inner 4
        \\auto-reload-config = true
        \\bind cmd-h : focus west
        \\bind cmd-h : focus east
        \\bind hyper-h : focus west
        \\bind cmd-h1 : focus west
        \\rule app="Finder" : explode
        \\rule title="a:b" : float
    ;
    try testing.expect(!config.load(source, &diagnostics));
    const report = diagnostics.slice();
    try testing.expect(std.mem.indexOf(u8, report, "line 2: UnknownDirective") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 4: DuplicateBinding") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 5: BadModifier") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 6: BadKey") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 7: BadAction") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 8") == null);
    try testing.expect(std.mem.indexOf(u8, report, "line 1:") == null);
}
