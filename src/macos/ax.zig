//! Thin, typed helpers over the Accessibility API. Every call here is a synchronous round
//! trip to another process; the global messaging timeout set in init() bounds each one.
const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const geometry = @import("../geometry.zig");
const engine_module = @import("../engine.zig");

const Rect = geometry.Rect;
const Ref = c.Ref;

/// How long any single Accessibility call may take before the application counts as hung.
/// The system default is six seconds, which is how a window manager freezes with one app.
pub const timeout_seconds: f32 = 0.25;

pub const Error = error{ Unresponsive, Invalid, Failed };

pub const Names = struct {
    windows: Ref,
    focused_window: Ref,
    main_window: Ref,
    position: Ref,
    size: Ref,
    title: Ref,
    role: Ref,
    subrole: Ref,
    minimized: Ref,
    fullscreen: Ref,
    main: Ref,
    frontmost: Ref,
    enhanced_user_interface: Ref,
    close_button: Ref,
    raise: Ref,
    press: Ref,
    role_window: Ref,
    subrole_standard: Ref,
    subrole_dialog: Ref,
    subrole_system_dialog: Ref,
    subrole_floating: Ref,
    window_created: Ref,
    focused_window_changed: Ref,
    main_window_changed: Ref,
    destroyed: Ref,
    moved: Ref,
    resized: Ref,
    title_changed: Ref,
    miniaturized: Ref,
    deminiaturized: Ref,
};

pub var names: Names = undefined;

fn name(text: [*:0]const u8) Ref {
    const string = c.CFStringCreateWithCString(null, text, c.string_encoding_utf8);
    assert(string != null);
    return string;
}

/// The process that holds Secure Input, 0 when nobody does, -1 when it cannot be told.
/// While it is held, macOS delivers no hot key whose only modifiers are option and shift:
/// the key types its character instead. A loginwindow that never lets go after the screen
/// was unlocked is the usual culprit.
pub fn secure_input_pid() i32 {
    if (c.IsSecureEventInputEnabled() == 0) return 0;
    const session = c.CGSessionCopyCurrentDictionary();
    if (session == null) return -1;
    defer c.CFRelease(session);
    const key = name("kCGSSessionSecureInputPID");
    defer c.CFRelease(key);
    const number = c.CFDictionaryGetValue(session, key);
    var pid: i32 = 0;
    if (number == null or c.CFNumberGetValue(number, c.number_type_sint32, &pid) == 0) {
        return -1;
    }
    return if (pid > 0) pid else -1;
}

pub const secure_input_advice =
    "Until it is released, keys bound with only option or option-shift type their\n" ++
    "character instead of reaching tatami. The process macOS names is not always the\n" ++
    "one at fault: the name was seen to follow the frontmost application. Locking and\n" ++
    "unlocking the screen usually releases a Secure Input that is stuck.\n";

/// The name of the process that holds Secure Input, null when nobody does.
pub fn secure_input_holder(buffer: []u8, pid: *i32) ?[]const u8 {
    pid.* = secure_input_pid();
    if (pid.* == 0) return null;
    const length = if (pid.* > 0) c.proc_name(pid.*, buffer.ptr, @intCast(buffer.len)) else 0;
    return if (length > 0) buffer[0..@intCast(length)] else "unknown";
}

pub fn init() void {
    names = .{
        .windows = name("AXWindows"),
        .focused_window = name("AXFocusedWindow"),
        .main_window = name("AXMainWindow"),
        .position = name("AXPosition"),
        .size = name("AXSize"),
        .title = name("AXTitle"),
        .role = name("AXRole"),
        .subrole = name("AXSubrole"),
        .minimized = name("AXMinimized"),
        .fullscreen = name("AXFullScreen"),
        .main = name("AXMain"),
        .frontmost = name("AXFrontmost"),
        .enhanced_user_interface = name("AXEnhancedUserInterface"),
        .close_button = name("AXCloseButton"),
        .raise = name("AXRaise"),
        .press = name("AXPress"),
        .role_window = name("AXWindow"),
        .subrole_standard = name("AXStandardWindow"),
        .subrole_dialog = name("AXDialog"),
        .subrole_system_dialog = name("AXSystemDialog"),
        .subrole_floating = name("AXFloatingWindow"),
        .window_created = name("AXWindowCreated"),
        .focused_window_changed = name("AXFocusedWindowChanged"),
        .main_window_changed = name("AXMainWindowChanged"),
        .destroyed = name("AXUIElementDestroyed"),
        .moved = name("AXWindowMoved"),
        .resized = name("AXWindowResized"),
        .title_changed = name("AXTitleChanged"),
        .miniaturized = name("AXWindowMiniaturized"),
        .deminiaturized = name("AXWindowDeminiaturized"),
    };
    const system_wide = c.AXUIElementCreateSystemWide();
    assert(system_wide != null);
    // On the system-wide element this sets the timeout for every call of this process.
    _ = c.AXUIElementSetMessagingTimeout(system_wide, timeout_seconds);
    c.CFRelease(system_wide);
}

fn check(code: c.AXError) Error!void {
    return switch (code) {
        c.ax_success => {},
        c.ax_cannot_complete => error.Unresponsive,
        c.ax_invalid_element => error.Invalid,
        else => error.Failed,
    };
}

/// Copies an attribute value. The caller releases it.
pub fn copy(element: Ref, attribute: Ref) Error!Ref {
    assert(element != null);
    var value: Ref = null;
    try check(c.AXUIElementCopyAttributeValue(element, attribute, &value));
    if (value == null) return error.Failed;
    return value;
}

pub fn window_id(element: Ref) u32 {
    var id: c.CGWindowID = 0;
    if (c._AXUIElementGetWindow(element, &id) != c.ax_success) return 0;
    return id;
}

fn pixels(value: f64) i32 {
    if (!(value > -1_000_000 and value < 1_000_000)) return 0;
    return @intFromFloat(@round(value));
}

pub fn frame_get(element: Ref) Error!Rect {
    const position = try copy(element, names.position);
    defer c.CFRelease(position);
    const size = try copy(element, names.size);
    defer c.CFRelease(size);
    var point: c.CGPoint = undefined;
    var extent: c.CGSize = undefined;
    if (c.AXValueGetValue(position, c.ax_value_point, &point) == 0) return error.Failed;
    if (c.AXValueGetValue(size, c.ax_value_size, &extent) == 0) return error.Failed;
    return .{
        .x = pixels(point.x),
        .y = pixels(point.y),
        .w = @max(0, pixels(extent.width)),
        .h = @max(0, pixels(extent.height)),
    };
}

pub fn position_set(element: Ref, x: i32, y: i32) Error!void {
    const point: c.CGPoint = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    const value = c.AXValueCreate(c.ax_value_point, &point);
    assert(value != null);
    defer c.CFRelease(value);
    try check(c.AXUIElementSetAttributeValue(element, names.position, value));
}

pub fn size_set(element: Ref, w: i32, h: i32) Error!void {
    const extent: c.CGSize = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
    const value = c.AXValueCreate(c.ax_value_size, &extent);
    assert(value != null);
    defer c.CFRelease(value);
    try check(c.AXUIElementSetAttributeValue(element, names.size, value));
}

/// Moves and resizes a window, then reads back where it actually ended up. When the size
/// is believed to be right already, only the position is set: a move is much cheaper for
/// an application than a resize, and switching workspaces is nothing but moves.
pub fn frame_set(element: Ref, frame: Rect, move_only: bool) Error!Rect {
    try position_set(element, frame.x, frame.y);
    if (move_only) {
        const moved = try frame_get(element);
        if (moved.w == frame.w and moved.h == frame.h) return moved;
    }
    try size_set(element, frame.w, frame.h);
    return frame_get(element);
}

pub fn bool_get(element: Ref, attribute: Ref) bool {
    const value = copy(element, attribute) catch return false;
    defer c.CFRelease(value);
    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return false;
    return c.CFBooleanGetValue(value) != 0;
}

pub fn bool_set(element: Ref, attribute: Ref, value: bool) void {
    _ = c.AXUIElementSetAttributeValue(
        element,
        attribute,
        if (value) c.kCFBooleanTrue else c.kCFBooleanFalse,
    );
}

pub fn settable(element: Ref, attribute: Ref) bool {
    var result: c.Boolean = 0;
    if (c.AXUIElementIsAttributeSettable(element, attribute, &result) != c.ax_success) return false;
    return result != 0;
}

/// Converts a CFString into UTF-8 in the buffer. Empty when it does not fit or is not one.
pub fn string_utf8(string: Ref, buffer: []u8) []const u8 {
    if (string == null or buffer.len == 0) return "";
    if (c.CFGetTypeID(string) != c.CFStringGetTypeID()) return "";
    const ok =
        c.CFStringGetCString(string, buffer.ptr, @intCast(buffer.len), c.string_encoding_utf8);
    if (ok == 0) return "";
    return std.mem.sliceTo(buffer, 0);
}

pub fn string_get(element: Ref, attribute: Ref, buffer: []u8) []const u8 {
    const value = copy(element, attribute) catch return "";
    defer c.CFRelease(value);
    return string_utf8(value, buffer);
}

pub fn attribute_is(element: Ref, attribute: Ref, expected: Ref) bool {
    const value = copy(element, attribute) catch return false;
    defer c.CFRelease(value);
    return c.CFEqual(value, expected) != 0;
}

/// What the engine should make of an Accessibility window. Only real, standard windows
/// tile; dialogs float; everything else (popovers, tooltips, helper windows with no or an
/// unknown subrole) is left alone, which is what keeps stray windows out of the layout.
pub fn window_kind(element: Ref) ?engine_module.WindowKind {
    if (!attribute_is(element, names.role, names.role_window)) return null;
    const subrole = copy(element, names.subrole) catch return .popup;
    defer c.CFRelease(subrole);
    if (c.CFEqual(subrole, names.subrole_standard) != 0) return .standard;
    if (c.CFEqual(subrole, names.subrole_dialog) != 0) return .dialog;
    if (c.CFEqual(subrole, names.subrole_system_dialog) != 0) return .dialog;
    if (c.CFEqual(subrole, names.subrole_floating) != 0) return .dialog;
    return .popup;
}

/// True when the window server has the window ordered in. A background tab of a native
/// tab group is a live Accessibility window that is not on screen.
pub fn on_screen(id: u32) bool {
    const options = c.window_list_on_screen_only | c.window_list_exclude_desktop;
    const list = c.CGWindowListCopyWindowInfo(options, 0);
    if (list == null) return true;
    defer c.CFRelease(list);
    const count = c.CFArrayGetCount(list);
    var index: c.CFIndex = 0;
    while (index < count) : (index += 1) {
        const entry = c.CFArrayGetValueAtIndex(list, index);
        const number = c.CFDictionaryGetValue(entry, c.kCGWindowNumber);
        var value: i32 = 0;
        if (number == null or c.CFNumberGetValue(number, c.number_type_sint32, &value) == 0) {
            continue;
        }
        if (value == @as(i32, @intCast(id))) return true;
    }
    return false;
}
