//! Where a filesystem reader gets its bytes.
//!
//! A `Region` is a byte range of a `std.Io.File` read through a caller-supplied
//! `std.Io`. The readers never learn what is behind the file: it can be a
//! regular file on a hosted OS, or a handle that a custom `std.Io`
//! implementation maps to a disk, partition or memory buffer. That is what
//! lets the same code run in a bootloader with no operating system.
//!
//! Only `File.readPositional` is used, so an `Io` implementation needs to
//! provide `fileReadPositional` and nothing else (`std.Io.failing` supplies the
//! rest). See docs/std-io-freestanding.md in the dklilo repository for the
//! rough edges of doing that today.

const std = @import("std");

pub const Error = error{
    /// The read failed, or ended before the requested length.
    IoError,
    /// The request went past the end of the region.
    OutOfRange,
};

pub const Region = struct {
    io: std.Io,
    file: std.Io.File,
    /// Offset of the region within `file`.
    start: u64,
    len: u64,

    /// Fills `buf` from `offset` bytes into the region.
    pub fn readAt(self: Region, offset: u64, buf: []u8) Error!void {
        if (offset > self.len or buf.len > self.len - offset) return error.OutOfRange;
        const n = self.file.readPositionalAll(self.io, buf, self.start + offset) catch return error.IoError;
        if (n != buf.len) return error.IoError;
    }

    /// A sub-range of this region.
    pub fn slice(self: Region, offset: u64, len: u64) Error!Region {
        if (offset > self.len or len > self.len - offset) return error.OutOfRange;
        var r = self;
        r.start += offset;
        r.len = len;
        return r;
    }
};
