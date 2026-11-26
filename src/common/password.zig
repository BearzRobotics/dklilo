//! The value of `password =`, and checking what is typed against it.
//!
//! Two forms are accepted:
//!
//!   pbkdf2-sha256$ITERATIONS$SALT$HASH
//!       PBKDF2 with HMAC-SHA-256 (RFC 8018): salted, and deliberately slow
//!       to compute, so that guessing from a copy of the configuration is
//!       expensive. SALT (8 to 64 bytes) and HASH (32 bytes) are in
//!       hexadecimal. `dklilo password` makes these.
//!
//!   64 hexadecimal digits
//!       The SHA-256 of the password: the older form, unsalted and quick to
//!       guess. Still accepted so that existing configurations keep working.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const prefix = "pbkdf2-sha256$";
/// What `dklilo password` uses: about as long as someone at the keyboard will
/// wait for a boot loader on a slow machine.
pub const default_iterations = 300_000;
/// More would look like a hang at the prompt.
pub const max_iterations = 5_000_000;
pub const min_salt = 8;
pub const max_salt = 64;
const key_len = 32;
/// Room for the longest value `format` writes.
pub const max_len = prefix.len + 7 + 1 + 2 * max_salt + 1 + 2 * key_len;

const Stored = union(enum) {
    plain: [key_len]u8,
    salted: struct { iterations: u32, salt: [max_salt]u8, salt_len: usize, key: [key_len]u8 },
};

fn parse(text: []const u8) ?Stored {
    if (!std.mem.startsWith(u8, text, prefix)) {
        var digest: [key_len]u8 = undefined;
        if (text.len != 2 * key_len) return null;
        _ = std.fmt.hexToBytes(&digest, text) catch return null;
        return .{ .plain = digest };
    }
    var fields = std.mem.splitScalar(u8, text[prefix.len..], '$');
    const iterations = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const salt_hex = fields.next() orelse return null;
    const key_hex = fields.next() orelse return null;
    if (fields.next() != null or iterations == 0 or iterations > max_iterations) return null;
    if (salt_hex.len % 2 != 0 or salt_hex.len < 2 * min_salt or salt_hex.len > 2 * max_salt) return null;
    if (key_hex.len != 2 * key_len) return null;
    var result: Stored = .{ .salted = .{
        .iterations = iterations,
        .salt = undefined,
        .salt_len = salt_hex.len / 2,
        .key = undefined,
    } };
    _ = std.fmt.hexToBytes(&result.salted.salt, salt_hex) catch return null;
    _ = std.fmt.hexToBytes(&result.salted.key, key_hex) catch return null;
    return result;
}

/// Whether `text` is a value some password could match.
pub fn isUsable(text: []const u8) bool {
    return parse(text) != null;
}

/// Whether `text` is the older, unsalted form.
pub fn isUnsalted(text: []const u8) bool {
    const stored = parse(text) orelse return false;
    return stored == .plain;
}

/// Whether `typed` is the password `text` was made from. A value that isn't
/// usable matches nothing.
pub fn matches(text: []const u8, typed: []const u8) bool {
    const stored = parse(text) orelse return false;
    var got: [key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &got);
    switch (stored) {
        .plain => |want| {
            Sha256.hash(typed, &got, .{});
            return std.crypto.timing_safe.eql([key_len]u8, got, want);
        },
        .salted => |s| {
            std.crypto.pwhash.pbkdf2(&got, typed, s.salt[0..s.salt_len], s.iterations, HmacSha256) catch return false;
            return std.crypto.timing_safe.eql([key_len]u8, got, s.key);
        },
    }
}

/// Writes the salted form of `password` into `out`. `salt` should be random.
pub fn format(
    out: *[max_len]u8,
    password: []const u8,
    salt: []const u8,
    iterations: u32,
) error{BadParameters}![]const u8 {
    if (iterations == 0 or iterations > max_iterations or salt.len < min_salt or salt.len > max_salt)
        return error.BadParameters;
    var key: [key_len]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&key, password, salt, iterations, HmacSha256) catch return error.BadParameters;
    var w = std.Io.Writer.fixed(out);
    w.print("{s}{d}${x}${x}", .{ prefix, iterations, salt, &key }) catch unreachable; // `max_len` fits
    return w.buffered();
}

const testing = std.testing;

test "a salted value matches its password and nothing else" {
    // The hash was computed with Python's
    // hashlib.pbkdf2_hmac("sha256", b"password", b"saltsalt", 2).
    const known = prefix ++ "2$73616c7473616c74$" ++
        "8f45ebd930d419bd84c40a8713d738dc5d5be95b663751de873588f70910a6c4";
    var out: [max_len]u8 = undefined;
    const made = try format(&out, "password", "saltsalt", 2);
    try testing.expectEqualStrings(known, made);
    try testing.expect(isUsable(made));
    try testing.expect(!isUnsalted(made));
    try testing.expect(matches(made, "password"));
    try testing.expect(!matches(made, "passwore"));
    try testing.expect(!matches(made, ""));
}

test "the older unsalted form still works" {
    const sha = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"; // "password"
    try testing.expect(isUnsalted(sha));
    try testing.expect(matches(sha, "password"));
    try testing.expect(!matches(sha, "Password"));
}

test "values no password can match" {
    const salt = "00112233445566778899aabbccddeeff";
    const hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    for ([_][]const u8{
        "",
        "hunter2",
        prefix,
        prefix ++ "0$" ++ salt ++ "$" ++ hash, // no iterations
        prefix ++ "999999999$" ++ salt ++ "$" ++ hash, // would hang
        prefix ++ "1000$0011$" ++ hash, // salt too short
        prefix ++ "1000$" ++ salt ++ "$" ++ hash[2..],
        prefix ++ "1000$" ++ salt ++ "$" ++ hash ++ "$x",
        prefix ++ "x$" ++ salt ++ "$" ++ hash,
    }) |text| {
        try testing.expect(!isUsable(text));
        try testing.expect(!matches(text, "password"));
    }
}
