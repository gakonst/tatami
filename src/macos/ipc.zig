//! The control socket: tatami <command> sends one line and reads one reply. Neither side
//! can hang: the client gives up after reply_timeout_ms, the server reads with a short
//! timeout and never blocks on a slow client.
const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const stdx = @import("../stdx.zig");

pub const request_max: usize = 1024;
pub const reply_max: usize = 40 * 1024;
pub const reply_timeout_ms: i32 = 2000;

const Handler = *const fn (request: []const u8, reply: *stdx.Text) void;
const QuitHandler = *const fn () void;

var listen_fd: c_int = -1;
var listen_descriptor: c.Ref = null;
var wake_fds: [2]c_int = .{ -1, -1 };
var wake_descriptor: c.Ref = null;
var handler: Handler = undefined;
var quit_handler: QuitHandler = undefined;
var socket_path: [104]u8 = undefined;
var reply_buffer: [reply_max]u8 = undefined;

fn address() c.SockaddrUn {
    var result: c.SockaddrUn =
        .{ .len = @sizeOf(c.SockaddrUn), .family = @intCast(c.af_unix), .path = undefined };
    @memset(&result.path, 0);
    var text = stdx.Text.init(result.path[0 .. result.path.len - 1]);
    text.print("/tmp/tatami-{d}.sock", .{c.getuid()});
    assert(!text.truncated);
    return result;
}

fn timeout_set(fd: c_int, ms: i32) void {
    const value: c.Timeval = .{ .sec = @divTrunc(ms, 1000), .usec = @rem(ms, 1000) * 1000 };
    _ = c.setsockopt(fd, c.sol_socket, c.so_rcvtimeo, &value, @sizeOf(c.Timeval));
    _ = c.setsockopt(fd, c.sol_socket, c.so_sndtimeo, &value, @sizeOf(c.Timeval));
}

pub fn server_open(on_request: Handler, on_quit: QuitHandler) void {
    handler = on_request;
    quit_handler = on_quit;
    const where = address();
    socket_path = where.path;
    _ = c.unlink(@ptrCast(&socket_path));
    listen_fd = c.socket(c.af_unix, c.sock_stream, 0);
    assert(listen_fd >= 0);
    if (c.bind(listen_fd, &where, @sizeOf(c.SockaddrUn)) != 0 or c.listen(listen_fd, 16) != 0) {
        std.debug.print("tatami: cannot listen on {s}\n", .{std.mem.sliceTo(&socket_path, 0)});
        c.exit(1);
    }
    _ = c.fcntl(listen_fd, c.f_setfl, c.o_nonblock);
    listen_descriptor = watch(listen_fd, listen_ready);
    // Signals are turned into a byte on a pipe, so quitting runs on the run loop.
    const piped = c.pipe(&wake_fds);
    assert(piped == 0);
    wake_descriptor = watch(wake_fds[0], wake_ready);
}

const Callout = *const fn (c.Ref, c.CFOptionFlags, ?*anyopaque) callconv(.c) void;

fn watch(fd: c_int, callout: Callout) c.Ref {
    const descriptor = c.CFFileDescriptorCreate(null, fd, 0, callout, null);
    assert(descriptor != null);
    c.CFFileDescriptorEnableCallBacks(descriptor, 1);
    const source = c.CFFileDescriptorCreateRunLoopSource(null, descriptor, 0);
    assert(source != null);
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
    return descriptor;
}

pub fn server_close() void {
    if (listen_fd < 0) return;
    _ = c.close(listen_fd);
    _ = c.unlink(@ptrCast(&socket_path));
    listen_fd = -1;
}

/// Async-signal-safe: only write(2).
pub fn wake_for_quit() void {
    const byte = [1]u8{'q'};
    _ = c.write(wake_fds[1], &byte, 1);
}

fn wake_ready(descriptor: c.Ref, types: c.CFOptionFlags, info: ?*anyopaque) callconv(.c) void {
    _ = descriptor;
    _ = types;
    _ = info;
    quit_handler();
}

fn listen_ready(descriptor: c.Ref, types: c.CFOptionFlags, info: ?*anyopaque) callconv(.c) void {
    _ = types;
    _ = info;
    var served: u32 = 0;
    while (served < 16) : (served += 1) {
        const peer = c.accept(listen_fd, null, null);
        if (peer < 0) break;
        serve(peer);
        _ = c.close(peer);
    }
    c.CFFileDescriptorEnableCallBacks(descriptor, 1);
}

fn serve(peer: c_int) void {
    timeout_set(peer, 100);
    var request: [request_max]u8 = undefined;
    const got = c.read(peer, &request, request.len);
    if (got <= 0) return;
    var reply = stdx.Text.init(&reply_buffer);
    handler(request[0..@intCast(got)], &reply);
    var sent: usize = 0;
    while (sent < reply.len) {
        const wrote = c.write(peer, reply.buffer[sent..].ptr, reply.len - sent);
        if (wrote <= 0) return;
        sent += @intCast(wrote);
    }
}

pub const ClientError = error{ NotRunning, Timeout };

/// Sends one request and copies the reply to stdout. Bounded by reply_timeout_ms.
pub fn client(request: []const u8) ClientError!bool {
    assert(request.len > 0 and request.len <= request_max);
    const fd = c.socket(c.af_unix, c.sock_stream, 0);
    assert(fd >= 0);
    defer _ = c.close(fd);
    timeout_set(fd, reply_timeout_ms);
    const where = address();
    if (c.connect(fd, &where, @sizeOf(c.SockaddrUn)) != 0) return error.NotRunning;
    if (c.write(fd, request.ptr, request.len) != @as(isize, @intCast(request.len))) {
        return error.Timeout;
    }
    var total: usize = 0;
    while (total < reply_buffer.len) {
        const got = c.read(fd, reply_buffer[total..].ptr, reply_buffer.len - total);
        if (got < 0) return error.Timeout;
        if (got == 0) break;
        total += @intCast(got);
    }
    if (total == 0) return error.Timeout;
    _ = c.write(1, &reply_buffer, total);
    return !std.mem.startsWith(u8, reply_buffer[0..total], "error");
}
