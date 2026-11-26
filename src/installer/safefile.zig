//! Writing a file without ever leaving a broken one in its place, and without
//! reporting success before it is on disk.

const std = @import("std");
const Io = std.Io;

/// The suffix of the file written before it takes the target's name.
const new_suffix = ".dklilo-new";

/// Puts `data` in `dir`/`path`. With `replace`, an existing file keeps its
/// contents until the new one is complete and on disk, and keeps its
/// permissions; without, an existing file is `error.PathAlreadyExists`.
/// A `path` that is a symlink is not followed: resolve it first.
pub fn write(io: Io, dir: Io.Dir, path: []const u8, data: []const u8, replace: bool) !void {
    if (!replace) return create(io, dir, path, data, null);

    const old: ?Io.File.Permissions = if (dir.statFile(io, path, .{})) |st| st.permissions else |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const new = std.fmt.bufPrint(&buf, "{s}" ++ new_suffix, .{path}) catch return error.NameTooLong;
    // Left over from a run that was interrupted.
    dir.deleteFile(io, new) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try create(io, dir, new, data, old);
    errdefer dir.deleteFile(io, new) catch {};
    try Io.Dir.rename(dir, new, dir, path, io);
}

/// Creates a file that must not exist, and syncs it. On failure it is removed.
fn create(io: Io, dir: Io.Dir, path: []const u8, data: []const u8, permissions: ?Io.File.Permissions) !void {
    const file = try dir.createFile(io, path, .{ .exclusive = true, .permissions = permissions orelse .default_file });
    errdefer dir.deleteFile(io, path) catch {};
    defer file.close(io);
    // The mode given to `createFile` is narrowed by the umask. (FAT, as on an
    // ESP, has no permissions to set.)
    if (permissions) |p| file.setPermissions(io, p) catch {};
    try file.writeStreamingAll(io, data);
    try file.sync(io);
}

test "replacing keeps the permissions; not replacing refuses" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, "f", "one", false);
    try std.testing.expectError(error.PathAlreadyExists, write(io, tmp.dir, "f", "two", false));
    try write(io, tmp.dir, "f", "three", true);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("three", try tmp.dir.readFile(io, "f", &buf));
    // A stale temporary file does not get in the way.
    try tmp.dir.writeFile(io, .{ .sub_path = "f" ++ new_suffix, .data = "junk" });
    try write(io, tmp.dir, "f", "four", true);
    try std.testing.expectEqualStrings("four", try tmp.dir.readFile(io, "f", &buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "f" ++ new_suffix, .{}));
}
