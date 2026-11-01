//! Installer modules, for the unit-test target.
pub const plan = @import("plan.zig");
pub const fat12 = @import("fat12.zig");
pub const genconfig = @import("genconfig.zig");
test {
    _ = plan;
    _ = fat12;
    _ = genconfig;
}
