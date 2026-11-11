//! Simulation runner: tatami-sim [seed] [steps] [--seeds n] [--no-faults] [--trace]
//!
//! Runs the engine against the simulated OS. A failing run aborts with a stack trace;
//! rerun the printed seed with --trace to see every event and effect leading up to it.
const std = @import("std");
const stdx = @import("stdx.zig");
const sim = @import("sim.zig");
const engine_module = @import("engine.zig");

var engine: engine_module.Engine = undefined;
var simulator: sim.Simulator = undefined;

extern "c" fn clock_gettime(clock: c_int, time: *Timespec) c_int;
const Timespec = extern struct { sec: i64, nsec: i64 };

fn now_ns() u64 {
    var time: Timespec = undefined;
    _ = clock_gettime(6, &time); // CLOCK_MONOTONIC on Darwin.
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    var seed: u64 = 1;
    var steps: u32 = 2000;
    var seeds: u32 = 1;
    var faults = true;
    var positional: u32 = 0;
    var index: usize = 1;
    while (index < @as(usize, @intCast(argc))) : (index += 1) {
        const arg = std.mem.span(argv[index]);
        if (std.mem.eql(u8, arg, "--no-faults")) {
            faults = false;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            sim.trace = true;
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            index += 1;
            if (index == @as(usize, @intCast(argc))) return usage();
            seeds = @intCast(stdx.parse_int(std.mem.span(argv[index])) orelse return usage());
        } else {
            const value = stdx.parse_int(arg) orelse return usage();
            if (value < 0) return usage();
            if (positional == 0) seed = @intCast(value) else steps = @intCast(value);
            positional += 1;
        }
    }
    const started = now_ns();
    var events: u64 = 0;
    var frames: u64 = 0;
    var run: u32 = 0;
    while (run < seeds) : (run += 1) {
        const current = seed + run;
        if (seeds > 1 and run % 100 == 0) std.debug.print("seed {d}...\n", .{current});
        sim.seed_running = current;
        events += sim.run_seed(&engine, &simulator, current, steps, faults);
        frames += simulator.frames_set;
    }
    const elapsed_ms = (now_ns() - started) / std.time.ns_per_ms;
    std.debug.print(
        "ok: {d} seed(s) from {d}, {d} steps each, faults={}: {d} events, {d} frames set, {d} ms\n",
        .{ seeds, seed, steps, faults, events, frames, elapsed_ms },
    );
    return 0;
}

fn usage() c_int {
    std.debug.print("usage: tatami-sim [seed] [steps] [--seeds n] [--no-faults] [--trace]\n", .{});
    return 2;
}
