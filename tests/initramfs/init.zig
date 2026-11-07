//! PID 1 for boot tests. Prints the kernel command line and any marker files
//! found in the initramfs, then powers off. Static, no libc.

const std = @import("std");
const linux = std.os.linux;

fn write(fd: usize, s: []const u8) void {
    _ = linux.write(@intCast(fd), s.ptr, s.len);
}

fn readFile(path: [*:0]const u8, buf: []u8) []const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return buf[0..0];
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (@as(isize, @bitCast(n)) < 0) return buf[0..0];
    return buf[0..n];
}

pub fn main() void {
    _ = linux.mount("proc", "/proc", "proc", 0, 0);
    var buf: [4096]u8 = undefined;
    write(1, "DKLILO-INITRAMFS-OK\n");
    write(1, "cmdline: ");
    write(1, std.mem.trimEnd(u8, readFile("/proc/cmdline", &buf), "\n"));
    write(1, "\n");
    // Files placed by extra (concatenated) initrds prove they all arrived.
    for ([_][*:0]const u8{ "/marker1", "/marker2" }) |p| {
        const c = readFile(p, &buf);
        if (c.len > 0) {
            write(1, "file ");
            write(1, std.mem.span(p));
            write(1, ": ");
            write(1, std.mem.trimEnd(u8, c, "\n"));
            write(1, "\n");
        }
    }
    write(1, "DKLILO-DONE\n");
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    while (true) {}
}
