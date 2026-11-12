//! The control socket: tatami <command> sends one line and reads one reply. Neither side
//! can hang: the client gives up after reply_timeout_ms, the server reads with a short
//! timeout and never blocks on a slow client.
//!
//! 'tatami events' is the one request that is not answered and closed: its connection
//! stays open and gets a line for everything that changes, until either side closes it.
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

pub const followers_max: u32 = 8;
const Follower = struct { fd: c_int, json: bool };
var followers: [followers_max]Follower = undefined;
var followers_count: u32 = 0;

fn address() c.SockaddrUn {
    var result: c.SockaddrUn =
        .{ .len = @sizeOf(c.SockaddrUn), .family = @intCast(c.af_unix), .path = undefined };
    @memset(&result.path, 0);
    var text = stdx.Text.init(result.path[0 .. result.path.len - 1]);
    text.print("/tmp/tatami-{d}.sock", .{c.getuid()});
    assert(!text.truncated);
    return result;
}

/// 0 waits without limit.
pub fn timeout_set(fd: c_int, ms: i32) void {
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
    // A client that left before its answer must not take the manager with it.
    _ = c.signal(13, c.sig_ign); // SIGPIPE
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
    for (followers[0..followers_count]) |follower| _ = c.close(follower.fd);
    followers_count = 0;
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
        if (!serve(peer)) _ = c.close(peer);
    }
    c.CFFileDescriptorEnableCallBacks(descriptor, 1);
}

/// Answers one request. True when the connection stays open, as a follower.
fn serve(peer: c_int) bool {
    timeout_set(peer, 100);
    var request: [request_max]u8 = undefined;
    const got = c.read(peer, &request, request.len);
    if (got <= 0) return false;
    const text = request[0..@intCast(got)];
    if (follow_request(text)) |json| {
        if (follower_add(peer, json)) return true;
        const refusal = "error: conflict: too many followers\n";
        _ = c.write(peer, refusal, refusal.len);
        return false;
    }
    var reply = stdx.Text.init(&reply_buffer);
    handler(text, &reply);
    var sent: usize = 0;
    while (sent < reply.len) {
        const wrote = c.write(peer, reply.buffer[sent..].ptr, reply.len - sent);
        if (wrote <= 0) return false;
        sent += @intCast(wrote);
    }
    return false;
}

/// Whether the request is 'events', and if so whether it asks for JSON.
fn follow_request(text: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "events")) return false;
    if (std.mem.eql(u8, trimmed, "events --json")) return true;
    return null;
}

fn follower_add(peer: c_int, json: bool) bool {
    if (followers_count == followers_max) return false;
    _ = c.fcntl(peer, c.f_setfl, c.o_nonblock);
    followers[followers_count] = .{ .fd = peer, .json = json };
    followers_count += 1;
    return true;
}

pub fn followed() bool {
    return followers_count > 0;
}

/// Sends one event to everyone who follows. A follower that has gone, or that reads too
/// slowly to take the line whole, is dropped: the manager never waits for one.
pub fn publish(line: []const u8, json: []const u8) void {
    assert(line.len > 0 and json.len > 0);
    var index: u32 = 0;
    while (index < followers_count) {
        const follower = followers[index];
        const bytes = if (follower.json) json else line;
        const wrote = c.write(follower.fd, bytes.ptr, bytes.len);
        if (wrote == @as(isize, @intCast(bytes.len))) {
            index += 1;
            continue;
        }
        _ = c.close(follower.fd);
        followers_count -= 1;
        followers[index] = followers[followers_count];
    }
}

pub const ClientError = error{ NotRunning, Timeout };

/// Connects and sends one request. The caller reads the answer, each read bounded by
/// timeout_ms, and closes the connection.
pub fn open(request: []const u8, timeout_ms: i32) ClientError!c_int {
    assert(request.len > 0 and request.len <= request_max);
    const fd = c.socket(c.af_unix, c.sock_stream, 0);
    assert(fd >= 0);
    errdefer _ = c.close(fd);
    timeout_set(fd, reply_timeout_ms);
    const where = address();
    if (c.connect(fd, &where, @sizeOf(c.SockaddrUn)) != 0) return error.NotRunning;
    if (c.write(fd, request.ptr, request.len) != @as(isize, @intCast(request.len))) {
        return error.Timeout;
    }
    timeout_set(fd, timeout_ms);
    return fd;
}

/// Sends one request and returns the reply, which stays valid until the next call.
/// Bounded by reply_timeout_ms.
pub fn ask(request: []const u8) ClientError![]const u8 {
    const fd = try open(request, reply_timeout_ms);
    defer _ = c.close(fd);
    var total: usize = 0;
    while (total < reply_buffer.len) {
        const got = c.read(fd, reply_buffer[total..].ptr, reply_buffer.len - total);
        if (got < 0) return error.Timeout;
        if (got == 0) break;
        total += @intCast(got);
    }
    if (total == 0) return error.Timeout;
    return reply_buffer[0..total];
}
