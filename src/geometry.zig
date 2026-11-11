//! Integer geometry in the Accessibility coordinate space: origin top-left, y grows down.
const std = @import("std");
const assert = std.debug.assert;

pub const Axis = enum(u1) { x, y };

pub const Direction = enum(u2) {
    west,
    south,
    north,
    east,

    pub fn axis(direction: Direction) Axis {
        return switch (direction) {
            .west, .east => .x,
            .north, .south => .y,
        };
    }

    pub fn opposite(direction: Direction) Direction {
        return switch (direction) {
            .west => .east,
            .east => .west,
            .north => .south,
            .south => .north,
        };
    }

    /// True for the directions that point towards the origin.
    pub fn is_leading(direction: Direction) bool {
        return direction == .west or direction == .north;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub const zero: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn init(x: i32, y: i32, w: i32, h: i32) Rect {
        assert(w >= 0);
        assert(h >= 0);
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn right(rect: Rect) i32 {
        return rect.x + rect.w;
    }

    pub fn bottom(rect: Rect) i32 {
        return rect.y + rect.h;
    }

    pub fn center_x(rect: Rect) i32 {
        return rect.x + @divTrunc(rect.w, 2);
    }

    pub fn center_y(rect: Rect) i32 {
        return rect.y + @divTrunc(rect.h, 2);
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    pub fn same_size(a: Rect, b: Rect) bool {
        return a.w == b.w and a.h == b.h;
    }

    pub fn area(rect: Rect) i64 {
        assert(rect.w >= 0 and rect.h >= 0);
        return @as(i64, rect.w) * @as(i64, rect.h);
    }

    pub fn contains_point(rect: Rect, x: i32, y: i32) bool {
        return x >= rect.x and x < rect.right() and y >= rect.y and y < rect.bottom();
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
    }

    /// Shrinks the rect by amount on every side, never below zero size.
    pub fn inset(rect: Rect, amount: i32) Rect {
        assert(amount >= 0);
        const dx = @min(amount, @divTrunc(rect.w, 2));
        const dy = @min(amount, @divTrunc(rect.h, 2));
        return .{ .x = rect.x + dx, .y = rect.y + dy, .w = rect.w - 2 * dx, .h = rect.h - 2 * dy };
    }

    /// Length of the overlap of two rects when projected on the given axis; may be negative.
    pub fn overlap(a: Rect, b: Rect, on: Axis) i32 {
        return switch (on) {
            .x => @min(a.right(), b.right()) - @max(a.x, b.x),
            .y => @min(a.bottom(), b.bottom()) - @max(a.y, b.y),
        };
    }

    /// A cell of a rows x cols grid laid over the rect, as in yabai's --grid.
    pub fn grid(rect: Rect, rows: u32, cols: u32, x: u32, y: u32, w: u32, h: u32) Rect {
        assert(rows > 0 and cols > 0);
        assert(w > 0 and h > 0);
        assert(x + w <= cols);
        assert(y + h <= rows);
        const cell_w = @divTrunc(rect.w, @as(i32, @intCast(cols)));
        const cell_h = @divTrunc(rect.h, @as(i32, @intCast(rows)));
        return .{
            .x = rect.x + cell_w * @as(i32, @intCast(x)),
            .y = rect.y + cell_h * @as(i32, @intCast(y)),
            .w = cell_w * @as(i32, @intCast(w)),
            .h = cell_h * @as(i32, @intCast(h)),
        };
    }
};

test "rect basics" {
    const a = Rect.init(0, 0, 100, 50);
    const b = Rect.init(100, 0, 100, 50);
    try std.testing.expect(!a.intersects(b));
    try std.testing.expect(a.intersects(Rect.init(99, 49, 5, 5)));
    try std.testing.expectEqual(@as(i32, 50), a.overlap(b, .y));
    try std.testing.expectEqual(@as(i32, 0), a.overlap(b, .x));
    try std.testing.expect(a.contains_point(0, 0));
    try std.testing.expect(!a.contains_point(100, 0));
    try std.testing.expect(Rect.init(10, 10, 80, 30).eql(a.inset(10)));
    const half = Rect.init(0, 0, 1000, 800).grid(1, 2, 1, 0, 1, 1);
    try std.testing.expect(half.eql(Rect.init(500, 0, 500, 800)));
    const centered = Rect.init(0, 0, 1000, 800).grid(4, 4, 1, 1, 2, 2);
    try std.testing.expect(centered.eql(Rect.init(250, 200, 500, 400)));
    try std.testing.expectEqual(Direction.east, Direction.west.opposite());
    try std.testing.expectEqual(Axis.y, Direction.north.axis());
}
