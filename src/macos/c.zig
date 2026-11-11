//! Hand-written bindings for the macOS C interfaces tatami uses: CoreFoundation, the
//! Accessibility API, CoreGraphics, Carbon events and hot keys, the Objective-C runtime and
//! a little libc. No headers and no cImport; every declaration here was checked against
//! the SDK by hand, and there are few enough to keep it that way.
const std = @import("std");

/// Any CoreFoundation, Accessibility, Carbon or Objective-C object reference.
pub const Ref = ?*anyopaque;
pub const Boolean = u8;
pub const CFIndex = isize;
pub const CFOptionFlags = usize;
pub const AXError = i32;
pub const CGWindowID = u32;
pub const CGDirectDisplayID = u32;

pub const CGPoint = extern struct { x: f64, y: f64 };
pub const CGSize = extern struct { width: f64, height: f64 };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

pub fn fourcc(comptime code: *const [4]u8) u32 {
    return @as(u32, code[0]) << 24 | @as(u32, code[1]) << 16 | @as(u32, code[2]) << 8 | code[3];
}

// CoreFoundation.

pub const string_encoding_utf8: u32 = 0x08000100;
pub const number_type_sint32: CFIndex = 3;

pub extern "c" fn CFRelease(object: Ref) void;
pub extern "c" fn CFRetain(object: Ref) Ref;
pub extern "c" fn CFEqual(a: Ref, b: Ref) Boolean;
pub extern "c" fn CFGetTypeID(object: Ref) usize;
pub extern "c" fn CFStringGetTypeID() usize;
pub extern "c" fn CFArrayGetTypeID() usize;
pub extern "c" fn CFBooleanGetTypeID() usize;
pub extern "c" fn CFStringCreateWithCString(allocator: Ref, text: [*:0]const u8, encoding: u32) Ref;
pub extern "c" fn CFStringGetCString(
    string: Ref,
    buffer: [*]u8,
    size: CFIndex,
    encoding: u32,
) Boolean;
pub extern "c" fn CFArrayGetCount(array: Ref) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(array: Ref, index: CFIndex) Ref;
pub extern "c" fn CFBooleanGetValue(boolean: Ref) Boolean;
pub extern "c" fn CFNumberGetValue(number: Ref, number_type: CFIndex, out: *anyopaque) Boolean;
pub extern "c" fn CFDictionaryGetValue(dictionary: Ref, key: Ref) Ref;
pub extern "c" fn CGSessionCopyCurrentDictionary() Ref;
pub extern "c" fn IORegistryGetRootEntry(main_port: u32) u32;
pub extern "c" fn IORegistryEntryCreateCFProperty(
    entry: u32,
    key: Ref,
    allocator: Ref,
    options: u32,
) Ref;
pub extern "c" fn IOObjectRelease(object: u32) c_int;
pub extern "c" fn IsSecureEventInputEnabled() Boolean;
pub extern "c" fn proc_name(pid: c_int, buffer: [*]u8, size: u32) c_int;
pub extern "c" fn CFAbsoluteTimeGetCurrent() f64;
pub extern "c" fn CFRunLoopGetMain() Ref;
pub extern "c" fn CFRunLoopAddSource(run_loop: Ref, source: Ref, mode: Ref) void;
pub extern "c" fn CFRunLoopAddTimer(run_loop: Ref, timer: Ref, mode: Ref) void;
pub extern "c" fn CFRunLoopTimerCreate(
    allocator: Ref,
    fire_date: f64,
    interval: f64,
    flags: CFOptionFlags,
    order: CFIndex,
    callout: *const fn (timer: Ref, info: ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) Ref;
pub extern "c" fn CFRunLoopTimerSetNextFireDate(timer: Ref, fire_date: f64) void;
pub extern "c" fn CFFileDescriptorCreate(
    allocator: Ref,
    fd: c_int,
    close_on_invalidate: Boolean,
    callout: *const fn (descriptor: Ref, types: CFOptionFlags, info: ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) Ref;
pub extern "c" fn CFFileDescriptorEnableCallBacks(descriptor: Ref, types: CFOptionFlags) void;
pub extern "c" fn CFFileDescriptorCreateRunLoopSource(
    allocator: Ref,
    descriptor: Ref,
    order: CFIndex,
) Ref;

pub extern "c" const kCFBooleanTrue: Ref;
pub extern "c" const kCFBooleanFalse: Ref;
pub extern "c" const kCFRunLoopCommonModes: Ref;

// Accessibility (HIServices).

pub const ax_success: AXError = 0;
pub const ax_invalid_element: AXError = -25202;
pub const ax_cannot_complete: AXError = -25204;
pub const ax_value_point: u32 = 1;
pub const ax_value_size: u32 = 2;

pub const AXObserverCallback = *const fn (
    observer: Ref,
    element: Ref,
    notification: Ref,
    context: ?*anyopaque,
) callconv(.c) void;

pub extern "c" fn AXIsProcessTrusted() Boolean;
pub extern "c" fn AXUIElementCreateApplication(pid: i32) Ref;
pub extern "c" fn AXUIElementCreateSystemWide() Ref;
pub extern "c" fn AXUIElementCopyAttributeValue(element: Ref, attribute: Ref, value: *Ref) AXError;
pub extern "c" fn AXUIElementSetAttributeValue(element: Ref, attribute: Ref, value: Ref) AXError;
pub extern "c" fn AXUIElementIsAttributeSettable(
    element: Ref,
    attribute: Ref,
    settable: *Boolean,
) AXError;
pub extern "c" fn AXUIElementPerformAction(element: Ref, action: Ref) AXError;
pub extern "c" fn AXUIElementSetMessagingTimeout(element: Ref, seconds: f32) AXError;
pub extern "c" fn AXValueCreate(value_type: u32, value: *const anyopaque) Ref;
pub extern "c" fn AXValueGetValue(value: Ref, value_type: u32, out: *anyopaque) Boolean;
pub extern "c" fn AXObserverCreate(pid: i32, callback: AXObserverCallback, observer: *Ref) AXError;
pub extern "c" fn AXObserverAddNotification(
    observer: Ref,
    element: Ref,
    notification: Ref,
    context: ?*anyopaque,
) AXError;
pub extern "c" fn AXObserverGetRunLoopSource(observer: Ref) Ref;
/// Private, but the only way from an Accessibility element to a window id, and stable
/// since 10.5. Every macOS window manager relies on it.
pub extern "c" fn _AXUIElementGetWindow(element: Ref, window: *CGWindowID) AXError;

// CoreGraphics.

pub const window_list_on_screen_only: u32 = 1;
pub const window_list_exclude_desktop: u32 = 16;

pub extern "c" fn CGGetActiveDisplayList(max: u32, displays: [*]CGDirectDisplayID, count: *u32) i32;
pub extern "c" fn CGDisplayBounds(display: CGDirectDisplayID) CGRect;
pub extern "c" fn CGMainDisplayID() CGDirectDisplayID;
pub extern "c" fn CGDisplayRegisterReconfigurationCallback(
    callback: *const fn (
        display: CGDirectDisplayID,
        flags: u32,
        info: ?*anyopaque,
    ) callconv(.c) void,
    info: ?*anyopaque,
) i32;
pub extern "c" fn CGEventSourceButtonState(state: i32, button: u32) bool;
pub extern "c" fn CGEventCreate(source: Ref) Ref;
pub extern "c" fn CGEventGetLocation(event: Ref) CGPoint;
pub extern "c" fn CGWarpMouseCursorPosition(point: CGPoint) i32;
pub extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: CGWindowID) Ref;
pub extern "c" const kCGWindowNumber: Ref;

// Carbon (HIToolbox): global hot keys and application launch and termination events.

pub const EventHotKeyID = extern struct { signature: u32, id: u32 };
pub const EventTypeSpec = extern struct { class: u32, kind: u32 };
pub const ProcessSerialNumber = extern struct { high: u32, low: u32 };
pub const EventHandlerProc =
    *const fn (call: Ref, event: Ref, context: ?*anyopaque) callconv(.c) i32;

pub const event_class_keyboard = fourcc("keyb");
pub const event_hot_key_pressed: u32 = 5;
pub const event_class_application = fourcc("appl");
pub const event_app_launched: u32 = 5;
pub const event_app_terminated: u32 = 6;
pub const event_app_front_switched: u32 = 7;
pub const event_param_direct_object = fourcc("----");
pub const event_param_process_id = fourcc("psn ");
pub const type_event_hot_key_id = fourcc("hkid");
pub const type_process_serial_number = fourcc("psn ");
pub const modifier_cmd: u32 = 0x0100;
pub const modifier_shift: u32 = 0x0200;
pub const modifier_option: u32 = 0x0800;
pub const modifier_control: u32 = 0x1000;

pub extern "c" fn RegisterEventHotKey(
    key_code: u32,
    modifiers: u32,
    id: EventHotKeyID,
    target: Ref,
    options: u32,
    hot_key: *Ref,
) i32;
pub extern "c" fn UnregisterEventHotKey(hot_key: Ref) i32;
pub extern "c" fn GetApplicationEventTarget() Ref;
pub extern "c" fn GetEventDispatcherTarget() Ref;
pub extern "c" fn InstallEventHandler(
    target: Ref,
    handler: EventHandlerProc,
    types_count: usize,
    types: [*]const EventTypeSpec,
    context: ?*anyopaque,
    handler_ref: ?*Ref,
) i32;
pub extern "c" fn GetEventParameter(
    event: Ref,
    name: u32,
    desired_type: u32,
    actual_type: ?*u32,
    size: usize,
    actual_size: ?*usize,
    data: *anyopaque,
) i32;
pub extern "c" fn GetEventKind(event: Ref) u32;
pub extern "c" fn GetProcessPID(psn: *const ProcessSerialNumber, pid: *i32) i32;

// Objective-C runtime, for the three AppKit classes we need: NSApplication (the event
// loop), NSScreen (the usable area of each display) and NSWorkspace (running apps).

pub extern "c" fn objc_getClass(name: [*:0]const u8) Ref;
pub extern "c" fn sel_registerName(name: [*:0]const u8) Ref;
pub extern "c" fn objc_msgSend() void;
pub extern "c" fn objc_autoreleasePoolPush() Ref;
pub extern "c" fn objc_autoreleasePoolPop(pool: Ref) void;
pub extern "c" fn NSApplicationLoad() Boolean;

/// Sends a message with no arguments that returns an object.
pub fn send(object: Ref, selector: [*:0]const u8) Ref {
    const function: *const fn (Ref, Ref) callconv(.c) Ref = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(selector));
}

pub fn send_index(object: Ref, selector: [*:0]const u8, index: usize) Ref {
    const function: *const fn (Ref, Ref, usize) callconv(.c) Ref = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(selector), index);
}

pub fn send_pid(object: Ref, selector: [*:0]const u8, pid: i32) Ref {
    const function: *const fn (Ref, Ref, i32) callconv(.c) Ref = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(selector), pid);
}

pub fn send_integer(object: Ref, selector: [*:0]const u8) isize {
    const function: *const fn (Ref, Ref) callconv(.c) isize = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(selector));
}

pub fn send_rect(object: Ref, selector: [*:0]const u8) CGRect {
    // On arm64 a CGRect comes back in d0-d3 through plain objc_msgSend.
    const function: *const fn (Ref, Ref) callconv(.c) CGRect = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(selector));
}

// libc.

pub const Timespec = extern struct { sec: i64, nsec: i64 };
pub const Timeval = extern struct { sec: i64, usec: i32 };
pub const SockaddrUn = extern struct { len: u8, family: u8, path: [104]u8 };

pub const af_unix: c_int = 1;
pub const sock_stream: c_int = 1;
pub const sol_socket: c_int = 0xffff;
pub const so_sndtimeo: c_int = 0x1005;
pub const so_rcvtimeo: c_int = 0x1006;
pub const o_nonblock: c_int = 0x0004;
pub const f_setfl: c_int = 4;
pub const clock_monotonic: c_int = 6;
pub const sig_ign: usize = 1;

pub extern "c" fn clock_gettime(clock: c_int, time: *Timespec) c_int;
pub extern "c" fn getuid() u32;
pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
pub extern "c" fn bind(fd: c_int, address: *const SockaddrUn, len: u32) c_int;
pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
pub extern "c" fn accept(fd: c_int, address: ?*anyopaque, len: ?*u32) c_int;
pub extern "c" fn connect(fd: c_int, address: *const SockaddrUn, len: u32) c_int;
pub extern "c" fn setsockopt(
    fd: c_int,
    level: c_int,
    name: c_int,
    value: *const anyopaque,
    len: u32,
) c_int;
pub extern "c" fn fcntl(fd: c_int, command: c_int, ...) c_int;
pub extern "c" fn read(fd: c_int, buffer: [*]u8, count: usize) isize;
pub extern "c" fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn unlink(path: [*:0]const u8) c_int;
pub extern "c" fn pipe(fds: *[2]c_int) c_int;
pub extern "c" fn fork() c_int;
pub extern "c" fn setsid() c_int;
pub extern "c" fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
pub extern "c" fn _exit(code: c_int) noreturn;
pub extern "c" fn exit(code: c_int) noreturn;
pub extern "c" fn signal(number: c_int, handler: usize) usize;
pub extern "c" fn _NSGetExecutablePath(buffer: [*]u8, size: *u32) c_int;

pub fn now_ms() u64 {
    var time: Timespec = undefined;
    const result = clock_gettime(clock_monotonic, &time);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1_000_000;
}

pub fn now_us() u64 {
    var time: Timespec = undefined;
    const result = clock_gettime(clock_monotonic, &time);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(time.sec)) * 1_000_000 + @as(u64, @intCast(time.nsec)) / 1000;
}
