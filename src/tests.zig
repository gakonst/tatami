//! Root of the test build: pulls in every module that has tests.
test {
    _ = @import("stdx.zig");
    _ = @import("geometry.zig");
    _ = @import("tree.zig");
    _ = @import("command.zig");
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("sim.zig");
    _ = @import("scenarios.zig");
    _ = @import("scenarios_yabai.zig");
    _ = @import("scenarios_macapps.zig");
    _ = @import("state.zig");
    _ = @import("scenarios_aerospace.zig");
    _ = @import("scenarios_i3.zig");
    _ = @import("scenarios_fuzz.zig");
    _ = @import("scenarios_review.zig");
    _ = @import("scenarios_hostile.zig");
    _ = @import("scenarios_restart.zig");
}
