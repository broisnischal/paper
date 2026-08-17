//! Live (video) wallpapers — backend selection, argv construction, state file.
//!
//! Per platform:
//!   Wayland   `mpvpaper` paints mpv onto a layer-shell surface below everything
//!   X11       `xwinwrap` hosts an override-redirect window that mpv draws into
//!   Windows   `mpv` is reparented into the desktop's WorkerW window
//!   macOS     no desktop-level window API from a CLI, so a still frame is used
//!
//! Everything in here is pure — building argv and encoding state — so it can be
//! tested without a compositor.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Container formats worth treating as a live wallpaper. GIF is included: mpv
/// plays it like any other video and the still-frame fallback works too.
pub const video_exts = [_][]const u8{ "mp4", "webm", "mkv", "mov", "m4v", "avi", "gif" };

pub fn isVideo(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    var buf: [8]u8 = undefined;
    if (ext.len == 0 or ext.len >= buf.len) return false;
    const low = std.ascii.lowerString(buf[0..ext.len], ext);
    for (video_exts) |e| {
        if (std.mem.eql(u8, low, e)) return true;
    }
    return false;
}

pub const Backend = enum {
    mpvpaper,
    xwinwrap,
    windows_mpv,
    none,

    /// The executable that must be on PATH for this backend.
    pub fn binary(self: Backend) []const u8 {
        return switch (self) {
            .mpvpaper => "mpvpaper",
            .xwinwrap => "xwinwrap",
            .windows_mpv => "mpv",
            .none => "",
        };
    }

    pub fn name(self: Backend) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) Backend {
        inline for (@typeInfo(Backend).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return .none;
    }
};

/// How the video fills the screen when its aspect ratio differs.
pub const Fit = enum {
    fill, // crop the overflow (default — no letterboxing)
    fit, // letterbox, show the whole frame
    stretch, // distort to the exact screen shape

    pub fn parse(s: []const u8) ?Fit {
        inline for (@typeInfo(Fit).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const Playback = struct {
    fit: Fit = .fill,
    sound: bool = false,
    /// Wayland output selector: `*` is every monitor, or a name like `HDMI-A-1`.
    output: []const u8 = "*",
    /// `WxH`, used by the X11 and Windows backends to size the window.
    geometry: []const u8 = "1920x1080",
};

/// mpv options without their leading `--`. mpvpaper wants them bare in one
/// string; the other backends want them as separate `--flag` arguments.
pub fn mpvOptions(arena: Allocator, p: Playback) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, "loop-file=inf");
    try list.append(arena, "hwdec=auto-safe");
    try list.append(arena, "no-osc");
    try list.append(arena, "no-osd-bar");
    try list.append(arena, "no-input-default-bindings");
    try list.append(arena, "really-quiet");
    if (!p.sound) try list.append(arena, "no-audio") else try list.append(arena, "volume=40");
    switch (p.fit) {
        .fill => try list.append(arena, "panscan=1.0"),
        .fit => try list.append(arena, "panscan=0.0"),
        .stretch => {
            try list.append(arena, "keepaspect=no");
            try list.append(arena, "panscan=0.0");
        },
    }
    return list.items;
}

/// Full command line for `backend` playing `file`.
pub fn argv(arena: Allocator, backend: Backend, file: []const u8, p: Playback) ![]const []const u8 {
    const opts = try mpvOptions(arena, p);
    var a: std.ArrayList([]const u8) = .empty;
    switch (backend) {
        .mpvpaper => {
            // `mpvpaper [options] <output> <file>`; -p pauses mpv while the
            // wallpaper is hidden, which is most of the time on a tiling WM.
            try a.appendSlice(arena, &.{ "mpvpaper", "-p", "-o", try std.mem.join(arena, " ", opts) });
            try a.append(arena, p.output);
            try a.append(arena, file);
        },
        .xwinwrap => {
            const geom = try std.fmt.allocPrint(arena, "{s}+0+0", .{p.geometry});
            // -ov override-redirect, -ni no input, -s shaped, -nf no focus,
            // -b below everything, -un skip the taskbar/pager.
            try a.appendSlice(arena, &.{ "xwinwrap", "-ov", "-ni", "-s", "-nf", "-b", "-un", "-g", geom, "--", "mpv", "-wid", "WID" });
            for (opts) |o| try a.append(arena, try std.fmt.allocPrint(arena, "--{s}", .{o}));
            try a.append(arena, file);
        },
        .windows_mpv => {
            // A plain borderless window; `paper` then reparents it into the
            // desktop so it renders behind the icons.
            try a.appendSlice(arena, &.{ "mpv", "--title=" ++ win_title, "--no-border", "--ontop=no", "--force-window=yes" });
            try a.append(arena, try std.fmt.allocPrint(arena, "--geometry={s}+0+0", .{p.geometry}));
            for (opts) |o| try a.append(arena, try std.fmt.allocPrint(arena, "--{s}", .{o}));
            try a.append(arena, file);
        },
        .none => return error.NoBackend,
    }
    return a.items;
}

/// Window title used to find the mpv window from PowerShell on Windows.
pub const win_title = "paper-live-wallpaper";

/// What is (or was last) playing. Written to `~/.config/paper/live.state` so
/// `paper live off`, `status` and `restore` work across invocations.
pub const State = struct {
    path: []const u8 = "",
    backend: Backend = .none,
    pid: i32 = 0,
    fit: Fit = .fill,
    sound: bool = false,
    output: []const u8 = "*",

    /// Slices point into `text`, which must outlive the returned state.
    pub fn parse(text: []const u8) State {
        var s: State = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "PATH")) s.path = v;
            if (std.mem.eql(u8, k, "BACKEND")) s.backend = Backend.parse(v);
            if (std.mem.eql(u8, k, "PID")) s.pid = std.fmt.parseInt(i32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "FIT")) s.fit = Fit.parse(v) orelse .fill;
            if (std.mem.eql(u8, k, "SOUND")) s.sound = std.mem.eql(u8, v, "1");
            if (std.mem.eql(u8, k, "OUTPUT")) s.output = v;
        }
        return s;
    }

    pub fn render(self: State, arena: Allocator) ![]u8 {
        return std.fmt.allocPrint(arena, "PATH={s}\nBACKEND={s}\nPID={d}\nFIT={s}\nSOUND={d}\nOUTPUT={s}\n", .{
            self.path,
            self.backend.name(),
            self.pid,
            @tagName(self.fit),
            @intFromBool(self.sound),
            self.output,
        });
    }

    pub fn playback(self: State, geometry: []const u8) Playback {
        return .{ .fit = self.fit, .sound = self.sound, .output = self.output, .geometry = geometry };
    }
};

test "isVideo covers the formats mpv plays" {
    try std.testing.expect(isVideo("clip.mp4"));
    try std.testing.expect(isVideo("CLIP.WEBM"));
    try std.testing.expect(isVideo("loop.gif"));
    try std.testing.expect(!isVideo("photo.jpg"));
    try std.testing.expect(!isVideo("noext"));
}

test "state round-trips" {
    const a = std.testing.allocator;
    const in: State = .{ .path = "/tmp/a.mp4", .backend = .mpvpaper, .pid = 4242, .fit = .fit, .sound = true, .output = "HDMI-A-1" };
    const text = try in.render(a);
    defer a.free(text);
    const out = State.parse(text);
    try std.testing.expectEqualStrings(in.path, out.path);
    try std.testing.expectEqual(in.backend, out.backend);
    try std.testing.expectEqual(in.pid, out.pid);
    try std.testing.expectEqual(in.fit, out.fit);
    try std.testing.expectEqual(in.sound, out.sound);
    try std.testing.expectEqualStrings(in.output, out.output);
}

test "argv puts the file last and mutes by default" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wl = try argv(arena, .mpvpaper, "/tmp/a.mp4", .{ .output = "DP-1" });
    try std.testing.expectEqualStrings("mpvpaper", wl[0]);
    try std.testing.expectEqualStrings("DP-1", wl[wl.len - 2]);
    try std.testing.expectEqualStrings("/tmp/a.mp4", wl[wl.len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, wl[3], "no-audio") != null);

    const x11 = try argv(arena, .xwinwrap, "/tmp/a.mp4", .{ .geometry = "2560x1440", .sound = true });
    try std.testing.expectEqualStrings("/tmp/a.mp4", x11[x11.len - 1]);
    var saw_geom = false;
    var saw_audio = false;
    for (x11) |s| {
        if (std.mem.eql(u8, s, "2560x1440+0+0")) saw_geom = true;
        if (std.mem.eql(u8, s, "--no-audio")) saw_audio = true;
    }
    try std.testing.expect(saw_geom);
    try std.testing.expect(!saw_audio);
}
