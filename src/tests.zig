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
}
