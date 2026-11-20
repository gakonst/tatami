//! The border of the focused window, as i3 draws one. macOS has no way to draw on another
//! application's window, so the border is a window of tatami's own: borderless,
//! transparent but for a ring just inside the focused window's frame, deaf to the mouse,
//! and one level above the focused window. At the window's own level any raise of it, as
//! every click in it makes, would cover the border until it was ordered back, which shows
//! as a flicker. None of this needs SIP disabled.
//!
//! The ring is a shape rather than a layer border because it follows the part of the
//! window the display shows: where the window reaches a rounded corner of the display, the
//! panel has no pixels past its curve, so the ring takes the panel's own curve there.
//!
//! The window server draws nothing for an application whose activation policy is
//! prohibited, which is what a binary outside an app bundle gets, so tatami becomes an
//! accessory application (no Dock icon, no menu bar) the first time it shows a border.
//! A window made with SkyLight directly, as JankyBorders makes one, stays empty the same
//! way.
const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const geometry = @import("../geometry.zig");

const Ref = c.Ref;
const Rect = geometry.Rect;

const style_mask_borderless: usize = 0;
const backing_buffered: usize = 2;
const order_above: isize = 1;
/// Can join all spaces, stationary in Mission Control, left out of window cycling.
const collection_behavior: usize = (1 << 0) | (1 << 4) | (1 << 6);
const animation_behavior_none: isize = 2;
const activation_policy_accessory: isize = 1;

pub const Style = struct {
    width: i32,
    radius: i32,
    /// 0xAARRGGBB.
    color: u32,

    fn eql(a: Style, b: Style) bool {
        return a.width == b.width and a.radius == b.radius and a.color == b.color;
    }
};

/// The display a border shows on: its frame, in the coordinates of window frames, and the
/// outline of its panel's pixels as a CGPath in points up from its bottom left, null when
/// macOS reports none, which counts as square.
pub const Display = struct {
    frame: Rect,
    bezel: Ref,
};

const Shown = struct {
    target: u32 = 0,
    frame: Rect = Rect.zero,
    level: isize = 0,
};

/// What the ring's path was last made for. The border holds a reference to display.bezel,
/// so a path at the same address is the same path.
const Outline = struct {
    frame: Rect = Rect.zero,
    radius: i32 = 0,
    display: Display = .{ .frame = Rect.zero, .bezel = null },
};

var window: Ref = null;
/// The CAShapeLayer that draws the ring, and the one that masks it to the window's shape.
var layer: Ref = null;
var mask: Ref = null;
var outlined: Outline = .{};
/// What the border shows now. target 0: it is ordered out.
var shown: Shown = .{};
/// The style the layer was last given, which outlives the border being hidden.
var styled: Style = .{ .width = 0, .radius = 0, .color = 0 };

fn sel(name: [*:0]const u8) Ref {
    return c.sel_registerName(name);
}

fn send_bool(object: Ref, selector: [*:0]const u8, value: bool) void {
    const function: *const fn (Ref, Ref, bool) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    function(object, sel(selector), value);
}

fn send_ref(object: Ref, selector: [*:0]const u8, value: Ref) void {
    const function: *const fn (Ref, Ref, Ref) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    function(object, sel(selector), value);
}

fn send_int(object: Ref, selector: [*:0]const u8, value: isize) void {
    const function: *const fn (Ref, Ref, isize) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    function(object, sel(selector), value);
}

fn send_float(object: Ref, selector: [*:0]const u8, value: f64) void {
    const function: *const fn (Ref, Ref, f64) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    function(object, sel(selector), value);
}

fn send_order(object: Ref, place: isize, relative_to: isize) void {
    const function: *const fn (Ref, Ref, isize, isize) callconv(.c) void =
        @ptrCast(&c.objc_msgSend);
    function(object, sel("orderWindow:relativeTo:"), place, relative_to);
}

fn send_rect(object: Ref, selector: [*:0]const u8, rect: c.CGRect) void {
    const function: *const fn (Ref, Ref, c.CGRect) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    function(object, sel(selector), rect);
}

fn send_frame(object: Ref, frame: c.CGRect) void {
    const function: *const fn (Ref, Ref, c.CGRect, bool) callconv(.c) void =
        @ptrCast(&c.objc_msgSend);
    function(object, sel("setFrame:display:"), frame, true);
}

fn window_create() bool {
    assert(window == null);
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const application = c.send(c.objc_getClass("NSApplication"), "sharedApplication");
    send_int(application, "setActivationPolicy:", activation_policy_accessory);
    const init: *const fn (Ref, Ref, c.CGRect, usize, usize, bool) callconv(.c) Ref =
        @ptrCast(&c.objc_msgSend);
    const allocated = c.send(c.objc_getClass("NSWindow"), "alloc");
    const rect = c.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 1 } };
    const created = init(
        allocated,
        sel("initWithContentRect:styleMask:backing:defer:"),
        rect,
        style_mask_borderless,
        backing_buffered,
        false,
    );
    if (created == null) {
        std.debug.print("tatami: no border: NSWindow refused\n", .{});
        return false;
    }
    send_bool(created, "setReleasedWhenClosed:", false);
    send_bool(created, "setOpaque:", false);
    send_ref(created, "setBackgroundColor:", c.send(c.objc_getClass("NSColor"), "clearColor"));
    send_bool(created, "setIgnoresMouseEvents:", true);
    send_bool(created, "setHasShadow:", false);
    send_int(created, "setAnimationBehavior:", animation_behavior_none);
    send_int(created, "setCollectionBehavior:", @intCast(collection_behavior));
    const view = c.send(created, "contentView");
    send_bool(view, "setWantsLayer:", true);
    const view_layer = c.send(view, "layer");
    const shape = c.send(c.objc_getClass("CAShapeLayer"), "layer");
    const shape_mask = c.send(c.objc_getClass("CAShapeLayer"), "layer");
    if (view_layer == null or shape == null or shape_mask == null) {
        std.debug.print("tatami: no border: no layer\n", .{});
        return false;
    }
    send_ref(shape, "setFillColor:", null);
    // A mask shows where it is opaque; its fill color is the default opaque black.
    send_ref(shape, "setMask:", shape_mask);
    // The sublayer keeps it once the pool lets it go.
    send_ref(view_layer, "addSublayer:", shape);
    window = created;
    layer = shape;
    mask = shape_mask;
    return true;
}

fn channel(color: u32, shift: u5) f64 {
    return @as(f64, @floatFromInt((color >> shift) & 0xff)) / 255.0;
}

fn layer_style(style: Style) void {
    const color = style.color;
    const cg_color = c.CGColorCreateSRGB(
        channel(color, 16),
        channel(color, 8),
        channel(color, 0),
        channel(color, 24),
    );
    defer c.CGColorRelease(cg_color);
    // Changes to a layer animate unless told otherwise.
    const transaction = c.objc_getClass("CATransaction");
    _ = c.send(transaction, "begin");
    send_bool(transaction, "setDisableActions:", true);
    // The stroke straddles the window's edge and the mask keeps its inner half.
    send_float(layer, "setLineWidth:", @floatFromInt(2 * style.width));
    send_ref(layer, "setStrokeColor:", cg_color);
    _ = c.send(transaction, "commit");
    styled = style;
}

/// Makes the ring's path: the edge of the part of the window the display shows.
fn outline_set(outline: Outline) void {
    const w: f64 = @floatFromInt(outline.frame.w);
    const h: f64 = @floatFromInt(outline.frame.h);
    const bounds = c.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } };
    const radius = @min(@as(f64, @floatFromInt(outline.radius)), @min(w, h) / 2.0);
    const rounded = c.CGPathCreateWithRoundedRect(bounds, radius, radius, null);
    defer c.CGPathRelease(rounded);
    const shown_path = part_shown(rounded, outline.frame, outline.display);
    defer c.CGPathRelease(shown_path);
    const path = if (shown_path != null) shown_path else rounded;
    const transaction = c.objc_getClass("CATransaction");
    _ = c.send(transaction, "begin");
    send_bool(transaction, "setDisableActions:", true);
    send_rect(layer, "setFrame:", bounds);
    send_ref(layer, "setPath:", path);
    send_rect(mask, "setFrame:", bounds);
    send_ref(mask, "setPath:", path);
    _ = c.send(transaction, "commit");
    _ = c.CGPathRetain(outline.display.bezel);
    c.CGPathRelease(outlined.display.bezel);
    outlined = outline;
}

/// The window's shape, rounded, less what lies on its display but outside the panel, in
/// the layer's points up from the window's bottom left; null when the display has no
/// outline or Core Graphics cannot say. Only the display's dead corners are cut, so the
/// part of a window off its display keeps its edge.
fn part_shown(rounded: Ref, frame: Rect, display: Display) Ref {
    if (display.bezel == null) return null;
    const to_layer = c.CGAffineTransform{
        .a = 1,
        .b = 0,
        .c = 0,
        .d = 1,
        .tx = @floatFromInt(display.frame.x - frame.x),
        .ty = @floatFromInt(frame.bottom() - display.frame.bottom()),
    };
    const size = c.CGSize{
        .width = @floatFromInt(display.frame.w),
        .height = @floatFromInt(display.frame.h),
    };
    const display_rect = c.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = size };
    const whole = c.CGPathCreateWithRect(display_rect, &to_layer);
    defer c.CGPathRelease(whole);
    const bezel = c.CGPathCreateCopyByTransformingPath(display.bezel, &to_layer);
    defer c.CGPathRelease(bezel);
    if (whole == null or bezel == null) return null;
    const dead = c.CGPathCreateCopyBySubtractingPath(whole, bezel, false);
    defer c.CGPathRelease(dead);
    if (dead == null) return null;
    return c.CGPathCreateCopyBySubtractingPath(rounded, dead, false);
}

/// The level macOS keeps the window at: 0 for an ordinary one, more for one that floats.
fn window_level(id: u32) isize {
    const window_list_including_window: u32 = 8;
    const list = c.CGWindowListCopyWindowInfo(window_list_including_window, id);
    if (list == null) return 0;
    defer c.CFRelease(list);
    if (c.CFArrayGetCount(list) < 1) return 0;
    const info = c.CFArrayGetValueAtIndex(list, 0);
    const number = c.CFDictionaryGetValue(info, c.kCGWindowLayer);
    if (number == null) return 0;
    var level: i32 = 0;
    if (c.CFNumberGetValue(number, c.number_type_sint32, &level) == 0) return 0;
    return level;
}

fn frame_set(frame: Rect) void {
    // AppKit counts y up from the bottom of the main display.
    const primary = c.CGDisplayBounds(c.CGMainDisplayID());
    const h: f64 = @floatFromInt(frame.h);
    send_frame(window, .{
        .origin = .{
            .x = @floatFromInt(frame.x),
            .y = primary.size.height - @as(f64, @floatFromInt(frame.y)) - h,
        },
        .size = .{ .width = @floatFromInt(frame.w), .height = h },
    });
}

/// Shows the border around the window target, whose frame is frame on display, or moves it
/// there. reorder: order it above the target again, which a raise of the target undoes.
pub fn show(target: u32, frame: Rect, display: Display, style: Style, reorder: bool) void {
    assert(target != 0);
    if (style.width <= 0 or frame.w <= 2 * style.width or frame.h <= 2 * style.width) {
        return hide();
    }
    if (window == null and !window_create()) return;
    if (!style.eql(styled)) layer_style(style);
    const outline = Outline{ .frame = frame, .radius = style.radius, .display = display };
    if (!std.meta.eql(outline, outlined)) outline_set(outline);
    const was_shown = shown.target != 0;
    if (!was_shown or !std.meta.eql(frame, shown.frame)) frame_set(frame);
    const level = if (target != shown.target) window_level(target) else shown.level;
    if (reorder or target != shown.target or !was_shown) {
        if (level != shown.level or !was_shown) send_int(window, "setLevel:", level + 1);
        send_order(window, order_above, target);
    }
    shown = .{ .target = target, .frame = frame, .level = level };
    flush();
}

/// Commits what changed to the window server now. tatami's work happens in run loop
/// callbacks that Core Animation does not commit after by itself.
fn flush() void {
    _ = c.send(c.objc_getClass("CATransaction"), "flush");
}

pub fn hide() void {
    if (shown.target == 0) return;
    assert(window != null);
    send_ref(window, "orderOut:", null);
    shown.target = 0;
}

/// The window the border is around, 0 when it shows none.
pub fn target_shown() u32 {
    return shown.target;
}
