//! Config file (~/.config/paper/config) — API keys + auto-change settings.
//! Format is `KEY=value` lines (shell-compatible, no quoting on read).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// -rw------- on POSIX; default on Windows (which has no unix modes).
const perm_600: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);

pub const keys = [_][]const u8{
    "WALLHAVEN_API_KEY",
    "UNSPLASH_API_KEY",
    "PEXELS_API_KEY",
    "HF_API_KEY",
    "HF_MODEL",
    "AUTO_SOURCE",
    "AUTO_QUERY",
    "AUTO_CATEGORIES",
};

pub const Config = struct {
    arena: Allocator,
    io: Io,
    dir_path: []const u8, // ~/.config/paper
    file_path: []const u8, // ~/.config/paper/config
    map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn load(arena: Allocator, io: Io, home: []const u8, xdg_config: ?[]const u8) !Config {
        const base = if (xdg_config) |x| x else try std.fmt.allocPrint(arena, "{s}/.config", .{home});
        const dir_path = try std.fmt.allocPrint(arena, "{s}/paper", .{base});
        const file_path = try std.fmt.allocPrint(arena, "{s}/config", .{dir_path});

        var cfg: Config = .{
            .arena = arena,
            .io = io,
            .dir_path = dir_path,
            .file_path = file_path,
        };

        // Read the config file if present; ignore if absent.
        const contents = readFile(arena, io, file_path) catch null;
        if (contents) |text| try cfg.parse(text);
        return cfg;
    }

    fn parse(self: *Config, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            var v = line[eq + 1 ..];
            // Tolerate shell-style quoting written by the old bash tool.
            v = unquote(v);
            try self.map.put(self.arena, try self.arena.dupe(u8, k), try self.arena.dupe(u8, v));
        }
    }

    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        const v = self.map.get(key) orelse return null;
        if (v.len == 0) return null;
        return v;
    }

    /// Set a key and rewrite the config file (chmod 600).
    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        try self.map.put(self.arena, try self.arena.dupe(u8, key), try self.arena.dupe(u8, value));
        try self.save();
    }

    fn save(self: *Config) !void {
        const io = self.io;
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.dir_path);

        var aw: std.Io.Writer.Allocating = .init(self.arena);
        defer aw.deinit();
        const w = &aw.writer;
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.len == 0) continue;
            try w.print("{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        var file = try cwd.createFile(io, self.file_path, .{ .permissions = perm_600 });
        defer file.close(io);
        try file.writeStreamingAll(io, aw.written());
    }
};

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '\'' or v[0] == '"') and v[v.len - 1] == v[0])
        return v[1 .. v.len - 1];
    return v;
}

fn readFile(arena: Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return try r.interface.allocRemaining(arena, .unlimited);
}
