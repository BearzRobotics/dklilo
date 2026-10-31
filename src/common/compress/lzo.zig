//! LZO1X decompression, as btrfs uses it (the only LZO variant dklilo needs).
//!
//! The format is described in the kernel's Documentation/staging/lzo.rst. A
//! stream is a series of instructions; each may copy a few literal bytes and
//! then copy a run from earlier output ("match"). After every instruction the
//! decoder is in one of five states, which decides how the next instruction
//! byte below 16 is read:
//!
//!   0     no pending literals: a byte < 16 starts a literal run
//!   1..3  that many literals just copied: a byte < 16 is a 2-byte match
//!   4     a long literal run just ended: a byte < 16 is a 3-byte match with a
//!         large distance (0x801 + ...)
//!
//! The decoder checks every read and write against the buffers, so corrupt
//! input produces an error, never an out-of-bounds access.

const std = @import("std");

pub const Error = error{
    /// Input ended in the middle of an instruction.
    InputOverrun,
    /// Output buffer too small for the decompressed data.
    OutputOverrun,
    /// A match pointed before the start of the output.
    LookBehindOverrun,
    /// The stream is malformed (no end marker, bad first byte...).
    Corrupt,
};

/// Decompresses one LZO1X stream from `in` into `out`; returns the number of
/// bytes written. Stops at the end-of-stream marker, or at the end of input
/// when the producer omitted it (btrfs segments have one).
pub fn decompress(in: []const u8, out: []u8) Error!usize {
    var ip: usize = 0;
    var op: usize = 0;
    var state: u32 = 0;

    if (in.len == 0) return error.InputOverrun;
    if (in[0] > 17) {
        const t: usize = in[0] - 17;
        ip = 1;
        try copyLiterals(in, &ip, out, &op, t);
        state = if (t < 4) @intCast(t) else 4;
    }

    while (true) {
        if (ip >= in.len) return error.InputOverrun;
        const t: usize = in[ip];
        ip += 1;

        var match_len: usize = 0;
        var dist: usize = 0;
        var trailing: u32 = 0;

        if (t < 16) {
            if (state == 0) {
                // Literal run: length 3 + (t, or an extended count if t == 0).
                var n: usize = t;
                if (n == 0) {
                    while (true) {
                        if (ip >= in.len) return error.InputOverrun;
                        if (in[ip] != 0) break;
                        n += 255;
                        ip += 1;
                        if (n > out.len + 4096) return error.Corrupt;
                    }
                    n += 15 + @as(usize, in[ip]);
                    ip += 1;
                }
                try copyLiterals(in, &ip, out, &op, n + 3);
                state = 4;
                continue;
            }
            // M1 match: two or three bytes, depending on the state.
            if (ip >= in.len) return error.InputOverrun;
            const b: usize = in[ip];
            ip += 1;
            if (state == 4) {
                match_len = 3;
                dist = 0x801 + (t >> 2) + (b << 2);
            } else {
                match_len = 2;
                dist = 1 + (t >> 2) + (b << 2);
            }
            trailing = @intCast(t & 3);
        } else if (t >= 64) {
            // M2: length 3..8, distance up to 2 KiB.
            if (ip >= in.len) return error.InputOverrun;
            const b: usize = in[ip];
            ip += 1;
            match_len = (t >> 5) + 1;
            dist = 1 + ((t >> 2) & 7) + (b << 3);
            trailing = @intCast(t & 3);
        } else if (t >= 32) {
            // M3: distance up to 16 KiB, long lengths allowed.
            var n: usize = t & 31;
            if (n == 0) {
                while (true) {
                    if (ip >= in.len) return error.InputOverrun;
                    if (in[ip] != 0) break;
                    n += 255;
                    ip += 1;
                    if (n > out.len + 4096) return error.Corrupt;
                }
                n += 31 + @as(usize, in[ip]);
                ip += 1;
            }
            if (ip + 2 > in.len) return error.InputOverrun;
            const v: usize = in[ip] | (@as(usize, in[ip + 1]) << 8);
            ip += 2;
            match_len = n + 2;
            dist = 1 + (v >> 2);
            trailing = @intCast(v & 3);
        } else {
            // M4 (16..31): distance 16..48 KiB; distance 0 is the end marker.
            var n: usize = t & 7;
            if (n == 0) {
                while (true) {
                    if (ip >= in.len) return error.InputOverrun;
                    if (in[ip] != 0) break;
                    n += 255;
                    ip += 1;
                    if (n > out.len + 4096) return error.Corrupt;
                }
                n += 7 + @as(usize, in[ip]);
                ip += 1;
            }
            if (ip + 2 > in.len) return error.InputOverrun;
            const v: usize = in[ip] | (@as(usize, in[ip + 1]) << 8);
            ip += 2;
            dist = ((t & 8) << 11) + (v >> 2);
            if (dist == 0) return op; // end of stream
            dist += 0x4000;
            match_len = n + 2;
            trailing = @intCast(v & 3);
        }

        try copyMatch(out, &op, dist, match_len);
        try copyLiterals(in, &ip, out, &op, trailing);
        state = trailing;
    }
}

fn copyLiterals(in: []const u8, ip: *usize, out: []u8, op: *usize, n: usize) Error!void {
    if (n > in.len - ip.*) return error.InputOverrun;
    if (n > out.len - op.*) return error.OutputOverrun;
    @memcpy(out[op.*..][0..n], in[ip.*..][0..n]);
    ip.* += n;
    op.* += n;
}

/// Copies a match byte by byte: source and destination may overlap (a short
/// distance repeats a pattern).
fn copyMatch(out: []u8, op: *usize, dist: usize, len: usize) Error!void {
    if (dist > op.*) return error.LookBehindOverrun;
    if (len > out.len - op.*) return error.OutputOverrun;
    var i: usize = 0;
    while (i < len) : (i += 1) out[op.* + i] = out[op.* + i - dist];
    op.* += len;
}

test "literals only" {
    // 0x15 = first byte > 17: copy (0x15 - 17) = 4 literals; then end marker.
    const stream = [_]u8{ 0x15, 'a', 'b', 'c', 'd', 0x11, 0x00, 0x00 };
    var out: [16]u8 = undefined;
    const n = try decompress(&stream, &out);
    try std.testing.expectEqualStrings("abcd", out[0..n]);
}

test "an overlapping match repeats a pattern" {
    // 4 literals "abcd", then M2: len 5, dist 4 -> "abcdabcda".
    // M2 byte: 0x40 | (len-1)<<5 ... t>>5 = len-1 = 4 -> t = 0x80, low bits: dist-1 = 3 -> (3&7)<<2 = 0x0C.
    const stream = [_]u8{ 0x15, 'a', 'b', 'c', 'd', 0x8C, 0x00, 0x11, 0x00, 0x00 };
    var out: [32]u8 = undefined;
    const n = try decompress(&stream, &out);
    try std.testing.expectEqualStrings("abcdabcda", out[0..n]);
}

test "corrupt input errors instead of overrunning" {
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.InputOverrun, decompress(&[_]u8{ 0x15, 'a' }, &out));
    // Match before the start of the output.
    try std.testing.expectError(error.LookBehindOverrun, decompress(&[_]u8{ 0x14, 'a', 'b', 'c', 0x50, 0x00, 0x11, 0, 0 }, &out));
    // Output too small.
    try std.testing.expectError(error.OutputOverrun, decompress(&[_]u8{ 0x15, 'a', 'b', 'c', 'd', 0x11, 0, 0 }, out[0..2]));
}
