//! Installer modules, for the unit-test target.
pub const plan = @import("plan.zig");
test {
    _ = plan;
}
