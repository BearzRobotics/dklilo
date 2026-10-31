//! Installer modules, for the unit-test target.
pub const plan = @import("plan.zig");
pub const fat12 = @import("fat12.zig");
test {
    _ = plan;
    _ = fat12;
}
