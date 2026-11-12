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
pub const border_width_max = 32;
pub const border_radius_max = 64;
/// Binding modes, including main.
pub const modes_max = 8;

comptime {
    // A set of modes is kept as the bits of one byte.
    assert(modes_max <= 8);
}
pub const mode_name_max = 16;

pub const default_source = @embedFile("default.conf");

pub const Modifiers = packed struct(u8) {
    cmd: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    padding: u4 = 0,
};

pub const Binding = struct {
    /// Index into Config.modes. 0 is main, the mode the manager starts in.
    mode: u8,
    modifiers: Modifiers,
    /// macOS virtual key code (ANSI layout positions).
    keycode: u16,
    commands: [commands_per_binding_max]Command,
    commands_count: u8,
    /// The keys and the commands as the configuration wrote them, for 'query bindings'.
    keys: Span,
    source: Span,
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
    .{ .name = "f13", .code = 105 },        .{ .name = "f14", .code = 107 },
    .{ .name = "f15", .code = 113 },        .{ .name = "f16", .code = 106 },
    .{ .name = "f17", .code = 64 },         .{ .name = "f18", .code = 79 },
    .{ .name = "f19", .code = 80 },         .{ .name = "f20", .code = 90 },
    .{ .name = "home", .code = 115 },       .{ .name = "end", .code = 119 },
    .{ .name = "pageup", .code = 116 },     .{ .name = "pagedown", .code = 121 },
    .{ .name = "delete", .code = 117 },     .{ .name = "section", .code = 10 },
    .{ .name = "kp0", .code = 82 },         .{ .name = "kp1", .code = 83 },
    .{ .name = "kp2", .code = 84 },         .{ .name = "kp3", .code = 85 },
    .{ .name = "kp4", .code = 86 },         .{ .name = "kp5", .code = 87 },
    .{ .name = "kp6", .code = 88 },         .{ .name = "kp7", .code = 89 },
    .{ .name = "kp8", .code = 91 },         .{ .name = "kp9", .code = 92 },
    .{ .name = "kpdecimal", .code = 65 },   .{ .name = "kpmultiply", .code = 67 },
    .{ .name = "kpplus", .code = 69 },      .{ .name = "kpclear", .code = 71 },
    .{ .name = "kpdivide", .code = 75 },    .{ .name = "kpenter", .code = 76 },
    .{ .name = "kpminus", .code = 78 },     .{ .name = "kpequal", .code = 81 },
    // Other names for keys above. key_name answers with the first name of a code.
    .{ .name = "return", .code = 36 },      .{ .name = "escape", .code = 53 },
    .{ .name = "grave", .code = 50 },
};

/// The largest key code a keyboard sends; a code written as a number may not be larger.
const keycode_max: u16 = 0x7f;

/// The code of a key given by name, or as a number such as 0x32 for a key with no name.
fn key_code(text: []const u8) ?u16 {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, text)) return key.code;
    }
    if (!std.mem.startsWith(u8, text, "0x") or text.len < 3 or text.len > 4) return null;
    const code = std.fmt.parseUnsigned(u16, text[2..], 16) catch return null;
    return if (code <= keycode_max) code else null;
}

/// Writes a binding's keys the way the configuration file spells them.
pub fn chord_print(text: *stdx.Text, binding: *const Binding) void {
    if (binding.modifiers.cmd) text.append("cmd-");
    if (binding.modifiers.ctrl) text.append("ctrl-");
    if (binding.modifiers.alt) text.append("alt-");
    if (binding.modifiers.shift) text.append("shift-");
    const name = key_name(binding.keycode);
    if (name.len > 1 or name[0] != '?') return text.append(name);
    text.print("0x{x:0>2}", .{binding.keycode});
}

pub fn key_name(code: u16) []const u8 {
    for (keys) |key| {
        if (key.code == code) return key.name;
    }
    return "?";
}

/// RRGGBB or AARRGGBB in hex, with or without a leading # or 0x, as 0xAARRGGBB.
fn color_parse(text: []const u8) ?u32 {
    var digits = text;
    if (std.mem.startsWith(u8, digits, "#")) digits = digits[1..];
    if (std.mem.startsWith(u8, digits, "0x")) digits = digits[2..];
    if (digits.len != 6 and digits.len != 8) return null;
    var value: u32 = 0;
    for (digits) |digit| {
        const nibble: u32 = switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 10,
            'A'...'F' => digit - 'A' + 10,
            else => return null,
        };
        value = value << 4 | nibble;
    }
    if (digits.len == 6) value |= 0xff000000;
    return value;
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
    BadBorder,
    BadRule,
    BadAction,
    BadMode,
    TooManyModes,
    ReloadNotAlone,
} || command.ParseError;

pub const Config = struct {
    gap_inner: i32,
    gap_outer: i32,
    gap_toggle: i32,
    /// The border drawn around the focused window, in pixels. 0 draws none.
    border_width: i32,
    border_radius: i32,
    /// 0xAARRGGBB.
    border_color: u32,
    bindings: [bindings_max]Binding,
    bindings_count: u32,
    rules: [rules_max]Rule,
    rules_count: u32,
    modes: [modes_max]Span,
    modes_count: u8,
    strings: command.StringPool,

    pub fn init(config: *Config) void {
        config.gap_inner = 0;
        config.gap_outer = 0;
        config.gap_toggle = 10;
        config.border_width = 0;
        config.border_radius = 0;
        config.border_color = 0xff4c7899;
        config.bindings_count = 0;
        config.rules_count = 0;
        config.strings = .{};
        config.modes[0] = config.strings.add("main") catch unreachable;
        config.modes_count = 1;
    }

    pub fn mode_name(config: *const Config, mode: u8) []const u8 {
        assert(mode < config.modes_count);
        return config.strings.get(config.modes[mode]);
    }

    pub fn mode_find(config: *const Config, name: []const u8) ?u8 {
        var mode: u8 = 0;
        while (mode < config.modes_count) : (mode += 1) {
            if (std.mem.eql(u8, config.mode_name(mode), name)) return mode;
        }
        return null;
    }

    fn mode_intern(config: *Config, name: []const u8) LineError!u8 {
        if (name.len == 0 or name.len > mode_name_max) return error.BadMode;
        if (config.mode_find(name)) |mode| return mode;
        if (config.modes_count == modes_max) return error.TooManyModes;
        config.modes[config.modes_count] = try config.strings.add(name);
        config.modes_count += 1;
        return config.modes_count - 1;
    }

    /// For every mode, the modes that its bindings switch to, one bit each. Of the mode
    /// commands of one binding the last is the one that takes effect. False when a mode
    /// command names a mode that has no bindings.
    fn modes_leads(config: *const Config, leads: *[modes_max]u8, diagnostics: *stdx.Text) bool {
        var ok = true;
        for (config.bindings[0..config.bindings_count]) |*binding| {
            var target: ?u8 = null;
            for (binding.commands[0..binding.commands_count]) |cmd| {
                if (cmd != .mode) continue;
                const name = config.strings.get(cmd.mode);
                target = config.mode_find(name);
                if (target != null) continue;
                ok = false;
                // A name longer than a mode's can be is cut, so the report holds it.
                const shown = name[0..@min(name.len, mode_name_max + 1)];
                diagnostics.print("mode \"{s}\" has no bindings\n", .{shown});
            }
            if (target) |mode| leads[binding.mode] |= @as(u8, 1) << @intCast(mode);
        }
        return ok;
    }

    /// Every mode command names a mode that has bindings, and from every mode some keys
    /// lead back to main, so no key press can strand the user in a mode or in a ring of
    /// modes.
    fn modes_check(config: *const Config, diagnostics: *stdx.Text) bool {
        var leads: [modes_max]u8 = @splat(0);
        var ok = config.modes_leads(&leads, diagnostics);
        // The modes known to lead to main, one bit each. Main is there already.
        var home: u8 = 1;
        var round: u8 = 1;
        while (round < config.modes_count) : (round += 1) {
            for (leads[0..config.modes_count], 0..) |targets, mode| {
                if (targets & home != 0) home |= @as(u8, 1) << @intCast(mode);
            }
        }
        var mode: u8 = 1;
        while (mode < config.modes_count) : (mode += 1) {
            const own = @as(u8, 1) << @intCast(mode);
            if (home & own != 0) continue;
            ok = false;
            const stuck = leads[mode] & ~own == 0;
            const what = if (stuck) "no binding that leaves it" else "no way back to main";
            diagnostics.print("mode \"{s}\" has {s}\n", .{ config.mode_name(mode), what });
        }
        return ok;
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
                // Only the start of a long line: all of it may be more than a report
                // holds, and a line that does not fit would not be reported at all.
                const shown = line[0..@min(line.len, 120)];
                const more = if (shown.len < line.len) "..." else "";
                diagnostics.print("line {d}: {s}: {s}{s}\n", .{
                    line_number, @errorName(err), shown, more,
                });
            };
        }
        if (!config.modes_check(diagnostics)) ok = false;
        assert(config.bindings_count <= bindings_max);
        assert(config.rules_count <= rules_max);
        assert(config.modes_count >= 1 and config.modes_count <= modes_max);
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
        if (std.mem.eql(u8, directive, "border")) return config.load_border(rest);
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

    fn load_border(config: *Config, rest: []const u8) LineError!void {
        const space = std.mem.indexOfAny(u8, rest, " \t") orelse return error.BadBorder;
        const which = rest[0..space];
        const value = command.trim(rest[space..]);
        if (std.mem.eql(u8, which, "color")) {
            config.border_color = color_parse(value) orelse return error.BadBorder;
            return;
        }
        const number = stdx.parse_int(value) orelse return error.BadBorder;
        if (std.mem.eql(u8, which, "width")) {
            if (number < 0 or number > border_width_max) return error.BadBorder;
            config.border_width = number;
        } else if (std.mem.eql(u8, which, "radius")) {
            if (number < 0 or number > border_radius_max) return error.BadBorder;
            config.border_radius = number;
        } else {
            return error.BadBorder;
        }
    }

    fn load_binding(config: *Config, rest: []const u8) LineError!void {
        // The colon of a "mode:<name>" prefix is not the separator.
        const from: usize = if (std.mem.startsWith(u8, rest, "mode:")) "mode:".len else 0;
        const colon =
            std.mem.indexOfScalarPos(u8, rest, from, ':') orelse return error.MissingSeparator;
        var binding: Binding = undefined;
        binding.commands_count = 0;
        binding.mode = 0;
        var chord = command.trim(rest[0..colon]);
        if (std.mem.startsWith(u8, chord, "mode:")) {
            const space = std.mem.indexOfAny(u8, chord, " \t") orelse return error.BadMode;
            binding.mode = try config.mode_intern(chord["mode:".len..space]);
            chord = command.trim(chord[space..]);
        }
        try parse_chord(chord, &binding);
        if (config.binding_find_in(binding.mode, binding.modifiers, binding.keycode) != null) {
            return error.DuplicateBinding;
        }
        var parts = std.mem.splitScalar(u8, rest[colon + 1 ..], ';');
        while (parts.next()) |part| {
            if (binding.commands_count == commands_per_binding_max) return error.TooManyCommands;
            binding.commands[binding.commands_count] = try command.parse(part, &config.strings);
            binding.commands_count += 1;
        }
        assert(binding.commands_count > 0);
        // A reload replaces the configuration that the other commands of the binding,
        // and the mode they switch to, were read from: it is a binding of its own.
        for (binding.commands[0..binding.commands_count]) |cmd| {
            if (cmd == .reload and binding.commands_count > 1) return error.ReloadNotAlone;
        }
        binding.keys = try config.strings.add(chord);
        binding.source = try config.strings.add(command.trim(rest[colon + 1 ..]));
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

    /// One line per mode, or a JSON object. The mode in use, when known, is marked.
    pub fn modes_print(config: *const Config, text: *stdx.Text, json: bool, current: ?u8) void {
        if (json) text.append("{\"modes\":[");
        var mode: u8 = 0;
        while (mode < config.modes_count) : (mode += 1) {
            const active = current != null and current.? == mode;
            if (json) {
                if (mode > 0) text.append(",");
                text.append("{\"name\":");
                text.json_string(config.mode_name(mode));
                text.print(",\"active\":{s}}}", .{if (active) "true" else "false"});
            } else {
                const mark: u8 = if (active) '*' else ' ';
                text.print("{c}{s}\n", .{ mark, config.mode_name(mode) });
            }
        }
        if (json) text.append("]}\n");
    }

    /// One line per key binding, or a JSON object: the mode, the keys and what they run.
    pub fn bindings_print(config: *const Config, text: *stdx.Text, json: bool) void {
        if (json) text.append("{\"bindings\":[");
        for (config.bindings[0..config.bindings_count], 0..) |*binding, index| {
            const mode = config.mode_name(binding.mode);
            const chord = config.strings.get(binding.keys);
            const source = config.strings.get(binding.source);
            if (json) {
                if (index > 0) text.append(",");
                text.append("{\"mode\":");
                text.json_string(mode);
                text.append(",\"keys\":");
                text.json_string(chord);
                text.append(",\"command\":");
                text.json_string(source);
                text.append("}");
            } else {
                text.print("{s}\t{s}\t{s}\n", .{ mode, chord, source });
            }
        }
        if (json) text.append("]}\n");
    }

    /// A binding of the main mode.
    pub fn binding_find(config: *const Config, modifiers: Modifiers, keycode: u16) ?*const Binding {
        return config.binding_find_in(0, modifiers, keycode);
    }

    pub fn binding_find_in(
        config: *const Config,
        mode: u8,
        modifiers: Modifiers,
        keycode: u16,
    ) ?*const Binding {
        for (config.bindings[0..config.bindings_count]) |*binding| {
            const same = @as(u8, @bitCast(binding.modifiers)) == @as(u8, @bitCast(modifiers));
            if (same and binding.mode == mode and binding.keycode == keycode) return binding;
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
            binding.keycode = key_code(part) orelse return error.BadKey;
            key_found = true;
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
    try testing.expectEqual(@as(u32, 91), config.bindings_count);
    try testing.expectEqual(@as(u32, 25), config.rules_count);
    const service = config.mode_find("service").?;
    const enter = config.binding_find(.{ .alt = true, .shift = true }, 41).?;
    try testing.expectEqualStrings("service", config.strings.get(enter.commands[0].mode));
    const others = config.binding_find_in(service, .{}, 51).?;
    try testing.expectEqual(Command.close_others, others.commands[0]);
    try testing.expectEqualStrings("main", config.strings.get(others.commands[1].mode));
    try testing.expect(config.binding_find(.{}, 51) == null);
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

test "the border of the focused window" {
    var config: Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const source =
        \\border width 3
        \\border radius 10
        \\border color #5E81AC
    ;
    try testing.expect(config.load(source, &diagnostics));
    try testing.expectEqual(@as(i32, 3), config.border_width);
    try testing.expectEqual(@as(i32, 10), config.border_radius);
    try testing.expectEqual(@as(u32, 0xff5e81ac), config.border_color);
    try testing.expect(config.load("border color 0x805e81ac", &diagnostics));
    try testing.expectEqual(@as(u32, 0x805e81ac), config.border_color);
    const bad =
        \\border width 33
        \\border radius -1
        \\border color 5e81a
        \\border color 5e81ag
        \\border glow 3
        \\border width
    ;
    diagnostics = stdx.Text.init(&buffer);
    try testing.expect(!config.load(bad, &diagnostics));
    const report = diagnostics.slice();
    var line: u8 = 1;
    while (line <= 6) : (line += 1) {
        var expected_buffer: [32]u8 = undefined;
        var expected = stdx.Text.init(&expected_buffer);
        expected.print("line {d}: BadBorder", .{line});
        try testing.expect(std.mem.indexOf(u8, report, expected.slice()) != null);
    }
}

test "a binding that reloads the configuration does nothing else" {
    var config: Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const source =
        \\bind alt-r : reload
        \\bind alt-s : reload ; exec open -a Ghostty
        \\bind alt-t : mode main ; reload
        \\bind alt-u : quit ; balance
    ;
    try testing.expect(!config.load(source, &diagnostics));
    const report = diagnostics.slice();
    try testing.expect(std.mem.indexOf(u8, report, "line 1:") == null);
    try testing.expect(std.mem.indexOf(u8, report, "line 2: ReloadNotAlone") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 3: ReloadNotAlone") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 4:") == null);
}

test "binding modes: a chord may repeat across modes, and no mode can strand the user" {
    var config: Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const good =
        \\bind alt-r : mode resize
        \\bind mode:resize h : resize left -20
        \\bind mode:resize esc : mode main
        \\bind mode:resize alt-r : mode main
        \\bind esc : balance
    ;
    try testing.expect(config.load(good, &diagnostics));
    const resize = config.mode_find("resize").?;
    try testing.expectEqual(@as(u8, 1), resize);
    try testing.expect(config.binding_find_in(resize, .{}, 53) != null);
    try testing.expectEqual(Command.balance, config.binding_find(.{}, 53).?.commands[0]);

    diagnostics = stdx.Text.init(&buffer);
    const stranded =
        \\bind alt-r : mode resize
        \\bind mode:resize h : resize left -20
        \\bind alt-q : mode nowhere
        \\bind mode:resize h : balance
        \\bind mode: h : balance
    ;
    try testing.expect(!config.load(stranded, &diagnostics));
    const report = diagnostics.slice();
    try testing.expect(std.mem.indexOf(u8, report, "line 4: DuplicateBinding") != null);
    try testing.expect(std.mem.indexOf(u8, report, "line 5: BadMode") != null);
    try testing.expect(std.mem.indexOf(u8, report, "mode \"nowhere\" has no bindings") != null);
    const stuck = "\"resize\" has no binding that leaves";
    try testing.expect(std.mem.indexOf(u8, report, stuck) != null);

    // Two modes that only lead to each other strand the user as well, and so does a
    // binding that leaves a mode and returns to it at once: the last mode command of a
    // binding is the one that counts.
    diagnostics = stdx.Text.init(&buffer);
    const ring =
        \\bind alt-r : mode north
        \\bind mode:north j : mode south
        \\bind mode:south k : mode north
        \\bind alt-s : mode loop
        \\bind mode:loop esc : mode main ; mode loop
        \\bind alt-t : mode far
        \\bind mode:far j : mode near
        \\bind mode:near esc : balance ; mode main
    ;
    try testing.expect(!config.load(ring, &diagnostics));
    const ringed = diagnostics.slice();
    try testing.expect(std.mem.indexOf(u8, ringed, "\"north\" has no way back to main") != null);
    try testing.expect(std.mem.indexOf(u8, ringed, "\"south\" has no way back to main") != null);
    try testing.expect(std.mem.indexOf(u8, ringed, "\"loop\" has no binding that leaves") != null);
    try testing.expect(std.mem.indexOf(u8, ringed, "\"far\"") == null);
    try testing.expect(std.mem.indexOf(u8, ringed, "\"near\"") == null);
}

test "keys have the names people expect, and any key can be named by its code" {
    var binding: Binding = undefined;
    try parse_chord("alt-return", &binding);
    try testing.expectEqual(@as(u16, 36), binding.keycode);
    try parse_chord("cmd-shift-pagedown", &binding);
    try testing.expectEqual(@as(u16, 121), binding.keycode);
    try parse_chord("ctrl-kp5", &binding);
    try testing.expectEqual(@as(u16, 87), binding.keycode);
    try parse_chord("alt-0x32", &binding);
    try testing.expectEqual(@as(u16, 0x32), binding.keycode);
    try testing.expect(binding.modifiers.alt and !binding.modifiers.cmd);
    try testing.expectError(error.BadKey, parse_chord("alt-0x80", &binding));
    try testing.expectError(error.BadKey, parse_chord("alt-0x", &binding));
    try testing.expectError(error.BadKey, parse_chord("alt-0xzz", &binding));
    try testing.expectError(error.BadKey, parse_chord("alt-hyper", &binding));
    // Every name is one key, and a code is printed under its first name.
    for (keys, 0..) |key, index| {
        for (keys[index + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, key.name, other.name));
    }
    try testing.expectEqualStrings("enter", key_name(36));
    try testing.expectEqualStrings("esc", key_name(53));
}

test "a bad line that is very long is still reported, by its start" {
    var config: Config = undefined;
    var buffer: [1024]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const filler: [4000]u8 = @splat('x');
    const source = "gap inner 4\nbind cmd-h : focus " ++ filler ++ "\nbind cmd-h1 : focus west\n";
    try testing.expect(!config.load(source, &diagnostics));
    const report = diagnostics.slice();
    const start = "line 2: BadArgument: bind cmd-h : focus xxx";
    try testing.expect(std.mem.startsWith(u8, report, start));
    try testing.expect(std.mem.indexOf(u8, report, "xxx...\nline 3: BadKey") != null);
    try testing.expect(report.len < 300);
    try testing.expect(!diagnostics.truncated);
}
