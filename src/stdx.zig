//! Small helpers shared by every module. No allocation, no I/O.
const std = @import("std");
const assert = std.debug.assert;

/// Deterministic PRNG (xoshiro256++ seeded by splitmix64).
/// Written out here so that simulation seeds stay reproducible across Zig releases.
pub const Prng = struct {
    s: [4]u64,

    pub fn init(seed: u64) Prng {
        var z = seed;
        var prng: Prng = .{ .s = undefined };
        for (&prng.s) |*word| {
            z +%= 0x9e3779b97f4a7c15;
            var x = z;
            x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
            x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
            word.* = x ^ (x >> 31);
        }
        assert(prng.s[0] | prng.s[1] | prng.s[2] | prng.s[3] != 0);
        return prng;
    }

    pub fn next(prng: *Prng) u64 {
        const s = &prng.s;
        const result = std.math.rotl(u64, s[0] +% s[3], 23) +% s[0];
        const t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = std.math.rotl(u64, s[3], 45);
        return result;
    }

    /// Uniform in [0, bound). Bound must be positive.
    pub fn below(prng: *Prng, bound: u32) u32 {
        assert(bound > 0);
        const wide = (prng.next() >> 32) * @as(u64, bound);
        const result: u32 = @intCast(wide >> 32);
        assert(result < bound);
        return result;
    }

    /// Uniform in [min, max], inclusive.
    pub fn range(prng: *Prng, min: i32, max: i32) i32 {
        assert(min <= max);
        const span: u32 = @intCast(@as(i64, max) - @as(i64, min) + 1);
        return @intCast(@as(i64, min) + prng.below(span));
    }

    /// True with probability numerator / denominator.
    pub fn chance(prng: *Prng, numerator: u32, denominator: u32) bool {
        assert(denominator > 0);
        assert(numerator <= denominator);
        return prng.below(denominator) < numerator;
    }
};

/// Copies as much of source as fits and returns the number of bytes copied.
pub fn copy_truncate(target: []u8, source: []const u8) u32 {
    const len = @min(target.len, source.len);
    @memcpy(target[0..len], source[0..len]);
    return @intCast(len);
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

/// ASCII case-insensitive substring search. An empty needle matches everything.
pub fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched: usize = 0;
        while (matched < needle.len) : (matched += 1) {
            if (lower(haystack[start + matched]) != lower(needle[matched])) break;
        }
        if (matched == needle.len) return true;
    }
    return false;
}

pub fn eql_ignore_case(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

/// Parses a decimal integer with an optional sign. Returns null on any malformed input.
pub fn parse_int(text: []const u8) ?i32 {
    if (text.len == 0 or text.len > 11) return null;
    var index: usize = 0;
    var negative = false;
    if (text[0] == '+' or text[0] == '-') {
        negative = text[0] == '-';
        index = 1;
    }
    if (index == text.len) return null;
    var value: i64 = 0;
    while (index < text.len) : (index += 1) {
        const digit = text[index];
        if (digit < '0' or digit > '9') return null;
        value = value * 10 + (digit - '0');
        if (value > std.math.maxInt(i32)) return null;
    }
    return @intCast(if (negative) -value else value);
}

/// Fixed-capacity text sink. Output that does not fit is dropped and flagged, never a crash.
pub const Text = struct {
    buffer: []u8,
    len: u32 = 0,
    truncated: bool = false,

    pub fn init(buffer: []u8) Text {
        assert(buffer.len > 0);
        return .{ .buffer = buffer };
    }

    pub fn print(text: *Text, comptime format: []const u8, args: anytype) void {
        assert(text.len <= text.buffer.len);
        const written = std.fmt.bufPrint(text.buffer[text.len..], format, args) catch {
            text.truncated = true;
            return;
        };
        text.len += @intCast(written.len);
    }

    pub fn append(text: *Text, bytes: []const u8) void {
        assert(text.len <= text.buffer.len);
        if (bytes.len > text.buffer.len - text.len) {
            text.truncated = true;
            return;
        }
        @memcpy(text.buffer[text.len..][0..bytes.len], bytes);
        text.len += @intCast(bytes.len);
    }

    /// Writes value as a JSON string. Bytes that are not UTF-8, as at the end of a title
    /// that was cut to fit, become question marks.
    pub fn json_string(text: *Text, value: []const u8) void {
        text.append("\"");
        var index: usize = 0;
        while (index < value.len) {
            const len = utf8_len(value[index..]);
            if (len == 0) {
                text.append("?");
                index += 1;
            } else if (len > 1) {
                text.append(value[index..][0..len]);
                index += len;
            } else {
                text.json_byte(value[index]);
                index += 1;
            }
        }
        text.append("\"");
    }

    fn json_byte(text: *Text, byte: u8) void {
        assert(byte < 0x80);
        switch (byte) {
            '"' => text.append("\\\""),
            '\\' => text.append("\\\\"),
            '\n' => text.append("\\n"),
            '\t' => text.append("\\t"),
            else => {
                if (byte < 0x20 or byte == 0x7f) {
                    text.print("\\u{x:0>4}", .{byte});
                } else {
                    text.append(&[1]u8{byte});
                }
            },
        }
    }

    pub fn slice(text: *const Text) []const u8 {
        assert(text.len <= text.buffer.len);
        return text.buffer[0..text.len];
    }
};

/// The length of the UTF-8 sequence that starts the bytes, or 0 when they start with none.
fn utf8_len(bytes: []const u8) usize {
    assert(bytes.len > 0);
    const lead = bytes[0];
    if (lead < 0x80) return 1;
    var len: usize = 0;
    if (lead >= 0xc2 and lead <= 0xdf) len = 2;
    if (lead >= 0xe0 and lead <= 0xef) len = 3;
    if (lead >= 0xf0 and lead <= 0xf4) len = 4;
    if (len == 0 or bytes.len < len) return 0;
    for (bytes[1..len]) |byte| {
        if (byte & 0xc0 != 0x80) return 0;
    }
    return len;
}

test "prng is deterministic and bounded" {
    var a = Prng.init(42);
    var b = Prng.init(42);
    var index: u32 = 0;
    while (index < 1000) : (index += 1) {
        try std.testing.expectEqual(a.next(), b.next());
        try std.testing.expect(a.below(7) < 7);
        const value = b.range(-3, 3);
        try std.testing.expect(value >= -3 and value <= 3);
        _ = b.below(7);
        _ = a.range(-3, 3);
    }
}

test "text helpers" {
    try std.testing.expect(contains_ignore_case("Brave Browser", "brave"));
    try std.testing.expect(!contains_ignore_case("Brave", "brave browser"));
    try std.testing.expect(eql_ignore_case("ESC", "esc"));
    try std.testing.expectEqual(@as(?i32, -50), parse_int("-50"));
    try std.testing.expectEqual(@as(?i32, 50), parse_int("+50"));
    try std.testing.expectEqual(@as(?i32, null), parse_int("5x"));
    try std.testing.expectEqual(@as(?i32, null), parse_int("-"));
    var buffer: [8]u8 = undefined;
    var text = Text.init(&buffer);
    text.print("{d}", .{1234});
    text.print("{d}", .{123456789});
    try std.testing.expectEqualStrings("1234", text.slice());
    try std.testing.expect(text.truncated);
    var wide: [64]u8 = undefined;
    var json = Text.init(&wide);
    json.json_string("a\"b\\c\td\x01 \xc3\xa9 \xe2\x82");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\td\\u0001 \xc3\xa9 ??\"", json.slice());
    try std.testing.expect(!json.truncated);
}
