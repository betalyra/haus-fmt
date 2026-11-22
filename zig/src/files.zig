//! Reading the files of a schema build (spec §13.3, "Files read"): every
//! file is a regular file, opened in a directory without following a link
//! at its last name and without blocking, checked on the opened file, and
//! read from it, so that the file checked is the file read.
//!
//! On Unix: `lstat` the name (its type, device and inode), `open` it with
//! `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY`, `fstat` the handle, and
//! require a regular file with the same device and inode; then read at most
//! the limit and one byte. A FIFO or a device is never opened, and one that
//! takes the place of the file between the `lstat` and the `open` is caught
//! by the `fstat` without blocking.
//!
//! On Windows, through `std.Io`: the name's kind without following a link,
//! then an open with `FILE_FLAG_OPEN_REPARSE_POINT` (a link is opened, not
//! followed), and the kind and file index of the handle, which must be a
//! regular file with the same index. The volume serial isn't compared
//! (`std.Io` doesn't give it). Opening a file on a disk doesn't block
//! there: named pipes live in their own namespace.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const native_os = builtin.os.tag;

/// What reading a file gave.
pub const Read = union(enum) {
    /// No such name.
    missing,
    /// A symbolic link (not followed).
    link,
    /// A directory, a FIFO, a device or a socket, or a file that can't be
    /// opened or read: not read.
    not_regular,
    /// Larger than the limit: not read past it.
    too_large,
    bytes: []const u8,
};

const unix = native_os != .windows and native_os != .wasi;

/// Reads the file `name` of the directory `dir`: a regular file, not a
/// link at its last name, of at most `limit` bytes. `name` may have
/// several names (`a/b.schema.haus`); only the last one is not followed.
pub fn readRegular(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8, limit: usize) Allocator.Error!Read {
    if (unix) return readUnix(arena, dir, name, limit);
    return readPortable(io, arena, dir, name, limit);
}

/// What a name is, as `lstat` sees it: a link is a link, not followed.
pub const Kind = enum { file, directory, link, other };

/// What the name `name` of the directory `dir` is, without following a
/// link at its last name (`lstat`); null if it can't be told (no such
/// name, or it can't be looked at). On Windows a reparse point that is a
/// link or a junction is a link, any other one `other`.
pub fn kindAt(io: Io, dir: Io.Dir, name: []const u8) ?Kind {
    if (unix) {
        var path_buf: [posix.PATH_MAX]u8 = undefined;
        const name_z = terminated(&path_buf, name) orelse return null;
        return (identify(dir.handle, name_z, null) orelse return null).kind;
    }
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
    return switch (st.kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .link,
        else => .other,
    };
}

/// `name` with a 0 after it, in `buf`; null if it doesn't fit or has a 0.
fn terminated(buf: *[posix.PATH_MAX]u8, name: []const u8) ?[*:0]const u8 {
    if (name.len >= buf.len or std.mem.indexOfScalar(u8, name, 0) != null) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0];
}

/// What `lstat` and `fstat` say of a file.
const Ident = struct { dev: u64, ino: u64, kind: Kind, size: u64 };

fn kindOfMode(mode: u32) Kind {
    return switch (mode & 0o170000) {
        0o100000 => .file,
        0o040000 => .directory,
        0o120000 => .link,
        else => .other,
    };
}

/// A device or inode number as 64 bits, whatever its C type.
fn widen(x: anytype) u64 {
    return switch (@typeInfo(@TypeOf(x)).int.signedness) {
        .signed => @bitCast(@as(i64, x)),
        .unsigned => @as(u64, x),
    };
}

/// `lstat` of `name` in `dir` (`fd == null`), or `fstat` of `fd`.
fn identify(dir: posix.fd_t, name: [*:0]const u8, fd: ?posix.fd_t) ?Ident {
    if (native_os == .linux) {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true };
        const rc = if (fd) |f|
            linux.statx(f, "", linux.AT.EMPTY_PATH, mask, &st)
        else
            linux.statx(dir, name, linux.AT.SYMLINK_NOFOLLOW, mask, &st);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .dev = (@as(u64, st.dev_major) << 32) | st.dev_minor, .ino = st.ino, .kind = kindOfMode(st.mode), .size = st.size };
    } else {
        var st: std.c.Stat = undefined;
        const rc = if (fd) |f| std.c.fstat(f, &st) else std.c.fstatat(dir, name, &st, std.c.AT.SYMLINK_NOFOLLOW);
        if (rc != 0) return null;
        return .{
            .dev = widen(st.dev),
            .ino = widen(st.ino),
            .kind = kindOfMode(@intCast(st.mode)),
            .size = @intCast(@max(st.size, 0)),
        };
    }
}

fn readUnix(arena: Allocator, dir: Io.Dir, name: []const u8, limit: usize) Allocator.Error!Read {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = terminated(&path_buf, name) orelse return .missing;

    const before = identify(dir.handle, name_z, null) orelse return .missing;
    switch (before.kind) {
        .file => {},
        .link => return .link,
        .directory, .other => return .not_regular,
    }
    var flags: posix.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    const fd = posix.openatZ(dir.handle, name_z, flags, 0) catch |e| return switch (e) {
        error.SymLinkLoop => .link,
        error.FileNotFound => .missing,
        else => .not_regular,
    };
    defer _ = posix.system.close(fd);
    const after = identify(fd, "", fd) orelse return .not_regular;
    if (after.kind != .file or after.dev != before.dev or after.ino != before.ino) return .not_regular;
    if (after.size > limit) return .too_large;
    // At most the limit and one byte, whatever the size said.
    const buf = try arena.alloc(u8, @as(usize, @intCast(after.size)) + 1);
    var n: usize = 0;
    while (n < buf.len) {
        const got = posix.read(fd, buf[n..]) catch return .not_regular;
        if (got == 0) break;
        n += got;
    }
    if (n > limit) return .too_large;
    if (n == buf.len) {
        // The file grew after the `fstat`: read on up to the limit.
        var more: std.ArrayList(u8) = .fromOwnedSlice(buf);
        while (more.items.len <= limit) {
            try more.ensureUnusedCapacity(arena, 4096);
            const got = posix.read(fd, more.unusedCapacitySlice()) catch return .not_regular;
            if (got == 0) break;
            more.items.len += got;
        }
        if (more.items.len > limit) return .too_large;
        return .{ .bytes = more.items };
    }
    return .{ .bytes = buf[0..n] };
}

fn readPortable(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8, limit: usize) Allocator.Error!Read {
    const before = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |e| return switch (e) {
        error.FileNotFound => .missing,
        else => .not_regular,
    };
    switch (before.kind) {
        .file => {},
        .sym_link => return .link,
        else => return .not_regular,
    }
    const file = dir.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch |e| return switch (e) {
        error.FileNotFound => .missing,
        error.SymLinkLoop => .link,
        else => .not_regular,
    };
    defer file.close(io);
    const after = file.stat(io) catch return .not_regular;
    if (after.kind != .file or after.inode != before.inode) return .not_regular;
    if (after.size > limit) return .too_large;
    const buf = try arena.alloc(u8, @as(usize, @intCast(after.size)) + 1);
    const n = file.readPositionalAll(io, buf, 0) catch return .not_regular;
    if (n > limit or n == buf.len) return .too_large;
    return .{ .bytes = buf[0..n] };
}

/// The names `dir` lists, or null when it can't be listed (spec §13.3,
/// "Spelling": a name is not found in a directory that can't be listed).
pub fn list(io: Io, arena: Allocator, dir: Io.Dir, sub_path: []const u8) Allocator.Error!?std.StringHashMapUnmanaged(void) {
    var d = dir.openDir(io, sub_path, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var it = d.iterate();
    while (it.next(io) catch return null) |entry| {
        try names.put(arena, try arena.dupe(u8, entry.name), {});
    }
    return names;
}

test "a regular file is read, a link and a directory are not" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Left in place under .zig-cache/tmp: nothing is deleted.
    var tmp = testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "sub");
    const read = try readRegular(io, arena, tmp.dir, "a.txt", 100);
    try testing.expectEqualStrings("hello", read.bytes);
    try testing.expect(try readRegular(io, arena, tmp.dir, "a.txt", 4) == .too_large);
    try testing.expect(try readRegular(io, arena, tmp.dir, "a.txt", 5) == .bytes);
    try testing.expect(try readRegular(io, arena, tmp.dir, "sub", 100) == .not_regular);
    try testing.expect(try readRegular(io, arena, tmp.dir, "nothing", 100) == .missing);
    try testing.expect(kindAt(io, tmp.dir, "a.txt") == .file);
    try testing.expect(kindAt(io, tmp.dir, "sub") == .directory);
    try testing.expect(kindAt(io, tmp.dir, "nothing") == null);
    if (tmp.dir.symLink(io, "a.txt", "link", .{})) {
        try testing.expect(try readRegular(io, arena, tmp.dir, "link", 100) == .link);
        try testing.expect(kindAt(io, tmp.dir, "link") == .link);
    } else |_| {} // Windows without the right to make links
    if (tmp.dir.symLink(io, "sub", "dirlink", .{ .is_directory = true })) {
        try testing.expect(kindAt(io, tmp.dir, "dirlink") == .link);
    } else |_| {}
    const names = (try list(io, arena, tmp.dir, ".")).?;
    try testing.expect(names.contains("a.txt") and names.contains("sub") and !names.contains("A.txt"));
}

test "a directory that can't be listed lists nothing" {
    if (!unix) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/x", .data = "x" });
    // Searchable, not readable, by its owner too.
    try tmp.dir.setFilePermissions(io, "sub", @fromBackingInt(@intCast(0o311)), .{});
    defer tmp.dir.setFilePermissions(io, "sub", @fromBackingInt(@intCast(0o755)), .{}) catch {};
    const st = try tmp.dir.statFile(io, "sub", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o311), @backingInt(st.permissions) & 0o777);
    const euid = if (native_os == .linux) std.os.linux.geteuid() else std.c.geteuid();
    if (euid == 0) return error.SkipZigTest; // permissions don't stop root
    try testing.expect(try list(io, arena, tmp.dir, "sub") == null);
    // Its files can still be read by name.
    try testing.expect(try readRegular(io, arena, tmp.dir, "sub/x", 10) == .bytes);
}
