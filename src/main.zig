//! paper — fetch & set desktop wallpapers for Omarchy / Hyprland.
//!
//! A native Zig rewrite of the original bash tool: HTTP (TLS) and JSON are
//! handled in-process via the standard library, so `curl` and `jq` are no
//! longer required. Interactive picking (`fzf`), inline previews (`chafa`),
//! and wallpaper backends (`swaybg`/`omarchy`/`gsettings`) are still delegated
//! to those external tools.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const config = @import("config.zig");

const version = "0.2.1";
const default_model = "black-forest-labs/FLUX.1-schnell";

// ANSI styling (matches the original tool).
const c = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const grn = "\x1b[32m";
    const red = "\x1b[31m";
    const yel = "\x1b[33m";
    const rst = "\x1b[0m";
};

const fzf_style = [_][]const u8{
    "--ansi",             "--layout=reverse",   "--border=rounded",
    "--info=inline-right", "--pointer=▌",        "--marker=",
    "--highlight-line",
    "--color=border:8,header:italic:8,prompt:6,pointer:5,info:8,hl:5,hl+:5",
};

const Result = struct {
    id: []const u8,
    label: []const u8,
    full_url: []const u8,
    thumb_url: []const u8,
    thumb_path: []const u8 = "",
};

const Options = struct {
    source: []const u8 = "wallhaven",
    categories: []const u8 = "111",
    purity: []const u8 = "100",
    sorting: []const u8 = "relevance",
    limit: u32 = 24,
    preview: bool = true,
    atleast: []const u8 = "", // empty => auto-detect
    hf_model: []const u8 = default_model,
};

const App = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    cfg: config.Config,
    home: []const u8,
    lib_dir: []const u8,
    opt: Options = .{},

    // -- output helpers -------------------------------------------------------
    fn info(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.err.print(c.grn ++ "==>" ++ c.rst ++ " " ++ fmt ++ "\n", args) catch {};
        self.err.flush() catch {};
    }
    fn warn(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.err.print(c.red ++ "!!" ++ c.rst ++ " " ++ fmt ++ "\n", args) catch {};
        self.err.flush() catch {};
    }
    fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt ++ "\n", args) catch {};
        self.out.flush() catch {};
    }
    fn fatal(self: *App, comptime fmt: []const u8, args: anytype) noreturn {
        self.warn(fmt, args);
        std.process.exit(1);
    }

    // -- config / secrets -----------------------------------------------------
    /// Config file value, falling back to an environment variable.
    fn secret(self: *App, key: []const u8) ?[]const u8 {
        if (self.cfg.get(key)) |v| return v;
        return self.env.get(key);
    }

    // -- external-tool helpers ------------------------------------------------
    fn has(self: *App, name: []const u8) bool {
        return self.whichPath(name) != null;
    }

    /// Absolute path of an executable found on PATH (arena-owned), or null.
    fn whichPath(self: *App, name: []const u8) ?[]const u8 {
        const path = self.env.get("PATH") orelse return null;
        var it = std.mem.tokenizeScalar(u8, path, ':');
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        while (it.next()) |dir| {
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
            Io.Dir.cwd().access(self.io, full, .{ .execute = true }) catch continue;
            return self.arena.dupe(u8, full) catch continue;
        }
        return null;
    }

    fn need(self: *App, name: []const u8) void {
        if (!self.has(name)) self.fatal("missing dependency: {s}", .{name});
    }

    /// Run `argv`, returning stdout on a clean exit (arena-owned), else null.
    fn capture(self: *App, argv: []const []const u8) ?[]u8 {
        const res = std.process.run(self.arena, self.io, .{ .argv = argv }) catch return null;
        switch (res.term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }
        return res.stdout;
    }

    /// Run `argv` inheriting the terminal; returns the exit code (or null).
    fn spawnWait(self: *App, argv: []const []const u8) ?u8 {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch return null;
        const term = child.wait(self.io) catch return null;
        return switch (term) {
            .exited => |code| code,
            else => null,
        };
    }

    /// Fire-and-forget: spawn with stdio suppressed, do not wait.
    fn spawnDetached(self: *App, argv: []const []const u8) void {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = &child;
    }

    fn notify(self: *App, comptime fmt: []const u8, args: anytype) void {
        if (!self.has("notify-send")) return;
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.spawnDetached(&.{ "notify-send", "-t", "2500", "Wallpaper", msg });
    }

    // -- resolution -----------------------------------------------------------
    fn detectRes(self: *App) []const u8 {
        if (self.opt.atleast.len > 0) return self.opt.atleast;
        detect: {
            if (!self.has("hyprctl")) break :detect;
            const out = self.capture(&.{ "hyprctl", "monitors", "-j" }) orelse break :detect;
            const parsed = std.json.parseFromSlice(std.json.Value, self.arena, out, .{}) catch break :detect;
            if (parsed.value != .array) break :detect;
            var best_area: i64 = 0;
            var best: []const u8 = "";
            for (parsed.value.array.items) |m| {
                if (m != .object) continue;
                const wv = m.object.get("width") orelse continue;
                const hv = m.object.get("height") orelse continue;
                const wi = jsonInt(wv) orelse continue;
                const hi = jsonInt(hv) orelse continue;
                if (wi * hi > best_area) {
                    best_area = wi * hi;
                    best = std.fmt.allocPrint(self.arena, "{d}x{d}", .{ wi, hi }) catch continue;
                }
            }
            if (best.len > 0) {
                self.opt.atleast = best;
                return best;
            }
        }
        self.opt.atleast = "1920x1080";
        return self.opt.atleast;
    }

    // -- absolute path resolution --------------------------------------------
    fn absPath(self: *App, path: []const u8) []const u8 {
        if (path.len > 0 and path[0] == '~') {
            return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.home, path[1..] }) catch path;
        }
        if (std.fs.path.isAbsolute(path)) return path;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(self.io, &buf) catch return path;
        return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ buf[0..n], path }) catch path;
    }

    fn isFile(self: *App, path: []const u8) bool {
        Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    // -- apply ----------------------------------------------------------------
    fn apply(self: *App, raw_img: []const u8) void {
        const img = self.absPath(raw_img);
        if (!self.isFile(img)) self.fatal("not a file: {s}", .{raw_img});
        switch (builtin.os.tag) {
            .linux => self.applyLinux(img),
            .macos => {
                const script = std.fmt.allocPrint(self.arena, "tell application \"System Events\" to tell every desktop to set picture to \"{s}\"", .{img}) catch self.fatal("oom", .{});
                if (self.spawnWait(&.{ "osascript", "-e", script }) != @as(u8, 0))
                    self.fatal("failed to set wallpaper via osascript", .{});
            },
            .windows => {
                const ps = std.fmt.allocPrint(self.arena,
                    \\Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class WP {{ [DllImport("user32.dll")] public static extern int SystemParametersInfo(int a, int b, string c, int d); }}';
                    \\[WP]::SystemParametersInfo(20, 0, '{s}', 3)
                , .{img}) catch self.fatal("oom", .{});
                _ = self.spawnWait(&.{ "powershell.exe", "-NoProfile", "-Command", ps });
            },
            else => self.fatal("unsupported platform", .{}),
        }
        self.info("Wallpaper set: " ++ c.dim ++ "{s}" ++ c.rst, .{img});
        self.notify("Set {s}", .{std.fs.path.basename(img)});
    }

    fn applyLinux(self: *App, img: []const u8) void {
        if (self.has("omarchy-theme-bg-set")) {
            _ = self.spawnWait(&.{ "omarchy-theme-bg-set", img });
        } else if (self.has("swaybg")) {
            const link = std.fmt.allocPrint(self.arena, "{s}/.config/omarchy/current/background", .{self.home}) catch self.fatal("oom", .{});
            const dir = std.fs.path.dirname(link) orelse link;
            Io.Dir.cwd().createDirPath(self.io, dir) catch {};
            Io.Dir.cwd().deleteFile(self.io, link) catch {};
            Io.Dir.cwd().symLink(self.io, img, link, .{}) catch {};
            _ = self.capture(&.{ "pkill", "-x", "swaybg" });
            self.spawnDetached(&.{ "swaybg", "-i", img, "-m", "fill" });
        } else if (self.has("gsettings")) {
            const uri = std.fmt.allocPrint(self.arena, "file://{s}", .{img}) catch self.fatal("oom", .{});
            _ = self.spawnWait(&.{ "gsettings", "set", "org.gnome.desktop.background", "picture-uri", uri });
            _ = self.spawnWait(&.{ "gsettings", "set", "org.gnome.desktop.background", "picture-uri-dark", uri });
        } else {
            self.fatal("no supported wallpaper setter found (omarchy, swaybg, or gsettings)", .{});
        }
    }

    // -- providers ------------------------------------------------------------
    fn fetch(self: *App, client: *http.Client, query: []const u8) []Result {
        if (std.mem.eql(u8, self.opt.source, "wallhaven")) return self.fetchWallhaven(client, query);
        if (std.mem.eql(u8, self.opt.source, "unsplash")) return self.fetchUnsplash(client, query);
        if (std.mem.eql(u8, self.opt.source, "pexels")) return self.fetchPexels(client, query);
        self.fatal("unknown source: {s} (wallhaven|unsplash|pexels)", .{self.opt.source});
    }

    fn fetchWallhaven(self: *App, client: *http.Client, query: []const u8) []Result {
        const atleast = self.detectRes();
        var url: Io.Writer.Allocating = .init(self.arena);
        const w = &url.writer;
        w.writeAll("https://wallhaven.cc/api/v1/search?q=") catch {};
        encodeInto(w, query);
        w.print("&categories={s}&purity={s}&sorting={s}&atleast={s}", .{ self.opt.categories, self.opt.purity, self.opt.sorting, atleast }) catch {};

        var headers: []const http.Header = &.{};
        if (self.secret("WALLHAVEN_API_KEY")) |k| {
            headers = &.{.{ .name = "X-API-Key", .value = k }};
        }
        self.info("Searching Wallhaven for '{s}' (\u{2265}{s}, sort={s})\u{2026}", .{ if (query.len > 0) query else "random", atleast, self.opt.sorting });
        const data = self.fetchArray(client, url.written(), headers, null, "data");

        var list: std.ArrayList(Result) = .empty;
        for (data) |item| {
            if (item != .object) continue;
            if (list.items.len >= self.opt.limit) break;
            const o = item.object;
            const id = jsonStr(o, "id") orelse continue;
            const res = jsonStr(o, "resolution") orelse "";
            const cat = jsonStr(o, "category") orelse "";
            const favs = if (o.get("favorites")) |f| jsonInt(f) orelse 0 else 0;
            const full = jsonStr(o, "path") orelse continue;
            var thumb: []const u8 = "";
            if (o.get("thumbs")) |t| if (t == .object) {
                thumb = jsonStr(t.object, "large") orelse jsonStr(t.object, "original") orelse "";
            };
            const label = std.fmt.allocPrint(self.arena, "\x1b[36m{s}\x1b[0m \x1b[2m·\x1b[0m {s} \x1b[2m·\x1b[0m \x1b[35m\u{2665} {d}\x1b[0m", .{ res, cat, favs }) catch continue;
            list.append(self.arena, .{ .id = id, .label = label, .full_url = full, .thumb_url = thumb }) catch break;
        }
        return list.items;
    }

    fn fetchUnsplash(self: *App, client: *http.Client, query: []const u8) []Result {
        const key = self.secret("UNSPLASH_API_KEY") orelse self.fatal("no Unsplash key — run: paper config keys", .{});
        var url: Io.Writer.Allocating = .init(self.arena);
        const w = &url.writer;
        w.writeAll("https://api.unsplash.com/search/photos?orientation=landscape&query=") catch {};
        encodeInto(w, query);
        w.print("&per_page={d}", .{self.opt.limit}) catch {};
        self.info("Searching Unsplash for '{s}'\u{2026}", .{query});
        const auth = std.fmt.allocPrint(self.arena, "Client-ID {s}", .{key}) catch self.fatal("oom", .{});
        const data = self.fetchArray(client, url.written(), &.{.{ .name = "Authorization", .value = auth }}, null, "results");

        var list: std.ArrayList(Result) = .empty;
        for (data) |item| {
            if (item != .object) continue;
            const o = item.object;
            const id = jsonStr(o, "id") orelse continue;
            const wi = if (o.get("width")) |v| jsonInt(v) orelse 0 else 0;
            const hi = if (o.get("height")) |v| jsonInt(v) orelse 0 else 0;
            var user: []const u8 = "";
            if (o.get("user")) |u| if (u == .object) {
                user = jsonStr(u.object, "username") orelse "";
            };
            var full: []const u8 = "";
            var thumb: []const u8 = "";
            if (o.get("urls")) |u| if (u == .object) {
                full = jsonStr(u.object, "full") orelse "";
                thumb = jsonStr(u.object, "small") orelse "";
            };
            if (full.len == 0) continue;
            const label = std.fmt.allocPrint(self.arena, "\x1b[36m{d}x{d}\x1b[0m \x1b[2m·\x1b[0m @{s}", .{ wi, hi, user }) catch continue;
            list.append(self.arena, .{ .id = id, .label = label, .full_url = full, .thumb_url = thumb }) catch break;
        }
        return list.items;
    }

    fn fetchPexels(self: *App, client: *http.Client, query: []const u8) []Result {
        const key = self.secret("PEXELS_API_KEY") orelse self.fatal("no Pexels key — run: paper config keys", .{});
        var url: Io.Writer.Allocating = .init(self.arena);
        const w = &url.writer;
        w.writeAll("https://api.pexels.com/v1/search?orientation=landscape&query=") catch {};
        encodeInto(w, query);
        w.print("&per_page={d}", .{self.opt.limit}) catch {};
        self.info("Searching Pexels for '{s}'\u{2026}", .{query});
        const data = self.fetchArray(client, url.written(), &.{.{ .name = "Authorization", .value = key }}, null, "photos");

        var list: std.ArrayList(Result) = .empty;
        for (data) |item| {
            if (item != .object) continue;
            const o = item.object;
            const id = if (o.get("id")) |v| (std.fmt.allocPrint(self.arena, "{d}", .{jsonInt(v) orelse 0}) catch continue) else continue;
            const wi = if (o.get("width")) |v| jsonInt(v) orelse 0 else 0;
            const hi = if (o.get("height")) |v| jsonInt(v) orelse 0 else 0;
            const photog = jsonStr(o, "photographer") orelse "";
            var full: []const u8 = "";
            var thumb: []const u8 = "";
            if (o.get("src")) |s| if (s == .object) {
                full = jsonStr(s.object, "original") orelse "";
                thumb = jsonStr(s.object, "medium") orelse "";
            };
            if (full.len == 0) continue;
            const label = std.fmt.allocPrint(self.arena, "\x1b[36m{d}x{d}\x1b[0m \x1b[2m·\x1b[0m @{s}", .{ wi, hi, photog }) catch continue;
            list.append(self.arena, .{ .id = id, .label = label, .full_url = full, .thumb_url = thumb }) catch break;
        }
        return list.items;
    }

    /// Fetch `url`, parse the JSON body, and return `root[key]` as an array.
    /// The parse tree is arena-allocated and lives for the process lifetime.
    fn fetchArray(self: *App, client: *http.Client, url: []const u8, headers: []const http.Header, payload: ?[]const u8, key: []const u8) []std.json.Value {
        const res = client.fetchAlloc(self.arena, url, headers, payload) catch |e|
            self.fatal("request failed: {t}", .{e});
        if (res.status != 200) self.fatal("{s} returned HTTP {d}", .{ self.opt.source, res.status });
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena, res.body, .{}) catch
            self.fatal("could not parse {s} response", .{self.opt.source});
        if (root != .object) self.fatal("unexpected {s} response", .{self.opt.source});
        const arr = root.object.get(key) orelse self.fatal("unexpected {s} response", .{self.opt.source});
        if (arr != .array) self.fatal("unexpected {s} response", .{self.opt.source});
        return arr.array.items;
    }

    // -- picker ---------------------------------------------------------------
    fn pick(self: *App, results: []Result) ?*Result {
        if (results.len == 0) self.fatal("no results", .{});
        const have_chafa = self.has("chafa");

        // Download thumbnails concurrently into a temp dir.
        var thumbs_dir: []const u8 = "";
        if (self.opt.preview and have_chafa) {
            thumbs_dir = self.mkTmpDir() catch "";
            if (thumbs_dir.len > 0) {
                self.info("Fetching thumbnails\u{2026}", .{});
                var group: Io.Group = .init;
                for (results) |*r| {
                    if (r.thumb_url.len == 0) continue;
                    r.thumb_path = std.fmt.allocPrint(self.arena, "{s}/{s}.img", .{ thumbs_dir, r.id }) catch continue;
                    group.async(self.io, thumbTask, .{ self.io, self.gpa, r.thumb_url, r.thumb_path });
                }
                group.await(self.io) catch {};
            }
        } else if (self.opt.preview) {
            self.warn("chafa not installed — list only. Inline previews:  sudo pacman -S chafa", .{});
        }

        // Build fzf input: "thumb_path \t id \t label".
        var input: Io.Writer.Allocating = .init(self.arena);
        for (results) |r| {
            input.writer.print("{s}\t{s}\t{s}\n", .{ r.thumb_path, r.id, r.label }) catch {};
        }

        const prevcmd = if (have_chafa)
            "[ -s {1} ] && chafa -f symbols --polite on -s \"${FZF_PREVIEW_COLUMNS:-40}x${FZF_PREVIEW_LINES:-20}\" {1} || echo \"thumbnail unavailable\""
        else
            "echo \"install chafa for previews:  sudo pacman -S chafa\"";

        const chosen = self.runFzf(input.written(), &.{
            "--with-nth=3..",                     "--delimiter=\t",
            "--preview",                          prevcmd,
            "--preview-window=right,60%,border-rounded",
            "--prompt=  paper ❯ ",
            "--header=enter set · ctrl-o open full · esc cancel",
            "--bind=ctrl-o:execute-silent(setsid imv {1} >/dev/null 2>&1 &)",
        }) orelse return null;

        const id = fieldAt(chosen, '\t', 1) orelse return null;
        for (results) |*r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    /// Spawn fzf with our style, feeding `input` on stdin and capturing the
    /// selected line. Returns null if the user cancelled (non-zero exit).
    fn runFzf(self: *App, input: []const u8, extra: []const []const u8) ?[]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(self.arena, "fzf") catch return null;
        for (fzf_style) |a| argv.append(self.arena, a) catch return null;
        for (extra) |a| argv.append(self.arena, a) catch return null;

        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch return null;

        child.stdin.?.writeStreamingAll(self.io, input) catch {};
        child.stdin.?.close(self.io);
        child.stdin = null;

        var rbuf: [4096]u8 = undefined;
        var r = child.stdout.?.reader(self.io, &rbuf);
        const out = r.interface.allocRemaining(self.arena, .unlimited) catch "";
        const term = child.wait(self.io) catch return null;
        switch (term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn mkTmpDir(self: *App) ![]const u8 {
        const base = self.env.get("TMPDIR") orelse "/tmp";
        const ts = Io.Timestamp.now(self.io, .real).toNanoseconds();
        const path = try std.fmt.allocPrint(self.arena, "{s}/paper-{d}", .{ base, ts });
        try Io.Dir.cwd().createDirPath(self.io, path);
        return path;
    }

    fn downloadFull(self: *App, client: *http.Client, url: []const u8, id: []const u8) []const u8 {
        Io.Dir.cwd().createDirPath(self.io, self.lib_dir) catch {};
        const ext = pickExt(url);
        const name = std.fmt.allocPrint(self.arena, "{s}/{s}-{s}.{s}", .{ self.lib_dir, self.opt.source, id, ext }) catch self.fatal("oom", .{});
        self.info("Downloading full resolution\u{2026}", .{});
        const status = client.downloadToFile(Io.Dir.cwd(), url, &.{}, null, name) catch |e|
            self.fatal("download failed: {t}", .{e});
        if (status != 200) self.fatal("download failed (HTTP {d})", .{status});
        return name;
    }

    // -- commands -------------------------------------------------------------
    fn cmdSearch(self: *App, query: []const u8) void {
        self.need("fzf");
        var client = http.Client.init(self.gpa, self.io);
        defer client.deinit();
        const results = self.fetch(&client, query);
        if (results.len == 0) self.fatal("no results (try a broader query, or adjust --categories/--purity)", .{});
        const chosen = self.pick(results) orelse {
            self.info("cancelled", .{});
            return;
        };
        self.apply(self.downloadFull(&client, chosen.full_url, chosen.id));
    }

    fn cmdRandom(self: *App, query: []const u8) void {
        self.opt.sorting = "random";
        self.opt.limit = 1;
        var client = http.Client.init(self.gpa, self.io);
        defer client.deinit();
        const results = self.fetch(&client, query);
        if (results.len == 0) self.fatal("no results", .{});
        self.apply(self.downloadFull(&client, results[0].full_url, results[0].id));
    }

    fn cmdLibrary(self: *App) void {
        self.need("fzf");
        var files: std.ArrayList([]const u8) = .empty;
        var dir = Io.Dir.cwd().openDir(self.io, self.lib_dir, .{ .iterate = true }) catch
            self.fatal("library empty: {s}", .{self.lib_dir});
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!hasImageExt(entry.name)) continue;
            const full = std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.lib_dir, entry.name }) catch continue;
            files.append(self.arena, full) catch break;
        }
        if (files.items.len == 0) self.fatal("no images in {s}", .{self.lib_dir});
        std.mem.sort([]const u8, files.items, {}, lessThanStr);

        var input: Io.Writer.Allocating = .init(self.arena);
        for (files.items) |f| input.writer.print("{s}\n", .{f}) catch {};

        const prev = if (self.has("chafa"))
            "chafa -f symbols --polite on -s \"${FZF_PREVIEW_COLUMNS:-40}x${FZF_PREVIEW_LINES:-20}\" {}"
        else
            "echo \"install chafa for previews:  sudo pacman -S chafa\"";

        const sel = self.runFzf(input.written(), &.{
            "--prompt=  library ❯ ", "--with-nth=-1",  "--delimiter=/",
            "--preview",              prev,
            "--preview-window=right,60%,border-rounded",
            "--header=enter set · ctrl-o open full · esc cancel",
            "--bind=ctrl-o:execute-silent(setsid imv {} >/dev/null 2>&1 &)",
        }) orelse {
            self.info("cancelled", .{});
            return;
        };
        self.apply(sel);
    }

    fn cmdCurrent(self: *App) void {
        const link = std.fmt.allocPrint(self.arena, "{s}/.config/omarchy/current/background", .{self.home}) catch return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(self.io, link, &buf) catch {
            self.warn("no current background set", .{});
            return;
        };
        self.say("{s}", .{buf[0..n]});
    }

    fn cmdPreview(self: *App, path: []const u8) void {
        if (path.len == 0 or !self.isFile(path)) self.fatal("usage: paper preview <path-to-image>", .{});
        if (self.has("chafa")) {
            _ = self.spawnWait(&.{ "chafa", "-f", "symbols", "--polite", "on", path });
        } else if (self.has("imv")) {
            self.warn("chafa not installed — opening in imv instead (install chafa for inline previews)", .{});
            self.spawnDetached(&.{ "imv", path });
        } else {
            self.fatal("install chafa (inline) or imv (window) to preview images", .{});
        }
    }

    fn cmdGenerate(self: *App, prompt: []const u8) void {
        if (prompt.len == 0) self.fatal("usage: paper generate <prompt...>   (e.g. paper generate misty pine forest at dawn)", .{});
        const token = self.secret("HF_API_KEY") orelse
            self.fatal("no Hugging Face token — grab a free one at https://huggingface.co/settings/tokens then run: paper config keys", .{});

        const atleast = self.detectRes();
        const xi = std.mem.indexOfScalar(u8, atleast, 'x') orelse self.fatal("bad resolution", .{});
        const w = (std.fmt.parseInt(u32, atleast[0..xi], 10) catch 1920) / 16 * 16;
        const h = (std.fmt.parseInt(u32, atleast[xi + 1 ..], 10) catch 1080) / 16 * 16;

        Io.Dir.cwd().createDirPath(self.io, self.lib_dir) catch {};
        const slug = self.slugify(prompt);
        const ts = Io.Timestamp.now(self.io, .real).toSeconds();
        const out = std.fmt.allocPrint(self.arena, "{s}/ai-{s}-{d}.png", .{ self.lib_dir, slug, ts }) catch self.fatal("oom", .{});

        self.info("Generating {d}x{d} with " ++ c.bold ++ "{s}" ++ c.rst ++ " — this can take 10-60s\u{2026}", .{ w, h, self.opt.hf_model });
        const body = std.fmt.allocPrint(self.arena, "{{\"inputs\":\"{f}\",\"parameters\":{{\"width\":{d},\"height\":{d}}}}}", .{ jsonEscape(prompt), w, h }) catch self.fatal("oom", .{});
        const url = std.fmt.allocPrint(self.arena, "https://router.huggingface.co/hf-inference/models/{s}", .{self.opt.hf_model}) catch self.fatal("oom", .{});
        const auth = std.fmt.allocPrint(self.arena, "Bearer {s}", .{token}) catch self.fatal("oom", .{});

        var client = http.Client.init(self.gpa, self.io);
        defer client.deinit();
        const status = client.downloadToFile(Io.Dir.cwd(), url, &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Content-Type", .value = "application/json" },
        }, body, out) catch |e| self.fatal("request failed: {t}", .{e});

        if (status != 200) {
            Io.Dir.cwd().deleteFile(self.io, out) catch {};
            if (status == 503) self.fatal("model is cold-loading on Hugging Face (HTTP 503) — retry in ~30s", .{});
            self.fatal("generation failed (HTTP {d})", .{status});
        }
        if (!self.looksLikeImage(out)) {
            Io.Dir.cwd().deleteFile(self.io, out) catch {};
            self.fatal("response was not an image", .{});
        }
        self.info("Saved: " ++ c.dim ++ "{s}" ++ c.rst, .{out});
        self.apply(out);
    }

    fn looksLikeImage(self: *App, path: []const u8) bool {
        var file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        defer file.close(self.io);
        var buf: [16]u8 = undefined;
        const n = file.readPositionalAll(self.io, &buf, 0) catch return false;
        const b = buf[0..n];
        if (b.len >= 8 and std.mem.eql(u8, b[0..8], "\x89PNG\r\n\x1a\n")) return true; // PNG
        if (b.len >= 2 and b[0] == 0xFF and b[1] == 0xD8) return true; // JPEG
        if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) return true; // WebP
        return false;
    }

    fn slugify(self: *App, prompt: []const u8) []const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var prev_dash = false;
        for (prompt) |ch| {
            if (buf.items.len >= 40) break;
            if (std.ascii.isAlphanumeric(ch)) {
                buf.append(self.arena, ch) catch break;
                prev_dash = false;
            } else if (!prev_dash) {
                buf.append(self.arena, '-') catch break;
                prev_dash = true;
            }
        }
        var s = buf.items;
        while (s.len > 0 and s[s.len - 1] == '-') s = s[0 .. s.len - 1];
        return if (s.len == 0) "wallpaper" else s;
    }

    // -- config command -------------------------------------------------------
    fn cmdConfig(self: *App, args: []const []const u8) void {
        const sub = if (args.len > 0) args[0] else "show";
        const rest = if (args.len > 0) args[1..] else args;

        if (std.mem.eql(u8, sub, "path")) {
            self.say("{s}", .{self.cfg.file_path});
        } else if (std.mem.eql(u8, sub, "show")) {
            self.say(c.bold ++ "Config:" ++ c.rst ++ " {s}", .{self.cfg.file_path});
            self.showKey("wallhaven key", self.secret("WALLHAVEN_API_KEY"));
            self.showKey("unsplash key", self.secret("UNSPLASH_API_KEY"));
            self.showKey("pexels key", self.secret("PEXELS_API_KEY"));
            self.showKey("huggingface", self.secret("HF_API_KEY"));
            self.say("  {s:<16} {s}", .{ "ai model", self.opt.hf_model });
            self.say("  " ++ c.dim ++ "auto-change:" ++ c.rst, .{});
            self.say("  {s:<16} {s}", .{ "source", self.cfg.get("AUTO_SOURCE") orelse "wallhaven" });
            self.say("  {s:<16} {s}", .{ "query", self.cfg.get("AUTO_QUERY") orelse "<random>" });
            self.say("  {s:<16} {s}", .{ "categories", self.cfg.get("AUTO_CATEGORIES") orelse "111" });
        } else if (std.mem.eql(u8, sub, "set-key")) {
            if (rest.len < 2) self.fatal("usage: paper config set-key <wallhaven|unsplash|pexels|huggingface> <key>", .{});
            const provider = rest[0];
            const key = rest[1];
            const cfg_key = if (std.mem.eql(u8, provider, "wallhaven")) "WALLHAVEN_API_KEY" else if (std.mem.eql(u8, provider, "unsplash")) "UNSPLASH_API_KEY" else if (std.mem.eql(u8, provider, "pexels")) "PEXELS_API_KEY" else if (std.mem.eql(u8, provider, "huggingface") or std.mem.eql(u8, provider, "hf")) "HF_API_KEY" else self.fatal("unknown provider: {s} (wallhaven|unsplash|pexels|huggingface)", .{provider});
            self.cfg.set(cfg_key, key) catch |e| self.fatal("could not save config: {t}", .{e});
            self.info("Saved {s} API key to {s}", .{ provider, self.cfg.file_path });
        } else if (std.mem.eql(u8, sub, "set-model")) {
            if (rest.len < 1) self.fatal("usage: paper config set-model <hf-model-id>", .{});
            self.cfg.set("HF_MODEL", rest[0]) catch |e| self.fatal("could not save config: {t}", .{e});
            self.info("AI model set to {s}", .{rest[0]});
        } else if (std.mem.eql(u8, sub, "keys")) {
            if (!self.has("gum")) self.fatal("gum not installed (needed for interactive key entry)", .{});
            self.say("Leave blank to keep the current value. Keys are stored in {s} (chmod 600).", .{self.cfg.file_path});
            self.gumKey("WALLHAVEN_API_KEY", "Wallhaven API key (optional, for NSFW/favorites)");
            self.gumKey("UNSPLASH_API_KEY", "Unsplash Access Key");
            self.gumKey("PEXELS_API_KEY", "Pexels API key");
            self.gumKey("HF_API_KEY", "Hugging Face token (for AI generation)");
            self.info("API keys updated.", .{});
        } else {
            self.fatal("usage: paper config {{show|keys|set-key <provider> <key>|set-model <model>|path}}", .{});
        }
    }

    fn gumKey(self: *App, cfg_key: []const u8, placeholder: []const u8) void {
        const res = std.process.run(self.arena, self.io, .{
            .argv = &.{ "gum", "input", "--password", "--placeholder", placeholder },
        }) catch return;
        const val = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (val.len == 0) return;
        self.cfg.set(cfg_key, val) catch {};
    }

    fn showKey(self: *App, name: []const u8, value: ?[]const u8) void {
        if (value) |v| {
            const shown = v[0..@min(4, v.len)];
            self.say("  {s:<16} " ++ c.grn ++ "set" ++ c.rst ++ " ({s}\u{2026})", .{ name, shown });
        } else {
            self.say("  {s:<16} " ++ c.dim ++ "—" ++ c.rst, .{name});
        }
    }

    // -- auto (systemd timer) -------------------------------------------------
    fn cmdAuto(self: *App, args: []const []const u8) void {
        if (!self.has("systemctl")) self.fatal("auto-change needs systemd (Linux). On macOS/Windows use launchd/Task Scheduler to run: paper random", .{});
        const sub = if (args.len > 0) args[0] else "status";
        const rest = if (args.len > 0) args[1..] else args;

        if (std.mem.eql(u8, sub, "hourly") or std.mem.eql(u8, sub, "daily") or std.mem.eql(u8, sub, "weekly")) {
            self.autoEnable(sub, sub, joinArgs(self.arena, rest));
        } else if (std.mem.eql(u8, sub, "custom")) {
            if (rest.len == 0) self.fatal("usage: paper auto custom \"<OnCalendar expr>\" [query]", .{});
            self.autoEnable("custom", rest[0], joinArgs(self.arena, rest[1..]));
        } else if (std.mem.eql(u8, sub, "off") or std.mem.eql(u8, sub, "disable") or std.mem.eql(u8, sub, "stop")) {
            _ = self.capture(&.{ "systemctl", "--user", "disable", "--now", "paper-auto.timer" });
            self.info("Auto-change disabled.", .{});
        } else if (std.mem.eql(u8, sub, "status")) {
            self.autoStatus();
        } else {
            self.fatal("usage: paper auto {{hourly|daily|weekly|custom <expr>|status|off}} [query]", .{});
        }
    }

    fn autoEnable(self: *App, label: []const u8, oncal: []const u8, query: []const u8) void {
        if (self.capture(&.{ "systemd-analyze", "calendar", oncal }) == null)
            self.fatal("invalid schedule '{s}' (see: man systemd.time — e.g. 'daily', '*-*-* 08:00:00')", .{oncal});

        self.cfg.set("AUTO_SOURCE", self.opt.source) catch {};
        self.cfg.set("AUTO_QUERY", query) catch {};
        self.cfg.set("AUTO_CATEGORIES", self.opt.categories) catch {};

        const self_path = self.selfPath();
        const unit_dir = std.fmt.allocPrint(self.arena, "{s}/systemd/user", .{self.xdgConfig()}) catch self.fatal("oom", .{});
        Io.Dir.cwd().createDirPath(self.io, unit_dir) catch {};

        const svc = std.fmt.allocPrint(self.arena,
            \\[Unit]
            \\Description=Change desktop wallpaper (paper)
            \\After=graphical-session.target
            \\PartOf=graphical-session.target
            \\
            \\[Service]
            \\Type=oneshot
            \\Environment=PATH=%h/.local/bin:%h/.local/share/omarchy/bin:/usr/local/bin:/usr/bin:/bin
            \\ExecStart={s} _auto_run
            \\
        , .{self_path}) catch self.fatal("oom", .{});
        writeText(self.io, self.arena, unit_dir, "paper-auto.service", svc) catch |e| self.fatal("could not write unit: {t}", .{e});

        const tmr = std.fmt.allocPrint(self.arena,
            \\[Unit]
            \\Description=Schedule automatic wallpaper changes (paper)
            \\
            \\[Timer]
            \\OnCalendar={s}
            \\Persistent=true
            \\
            \\[Install]
            \\WantedBy=timers.target
            \\
        , .{oncal}) catch self.fatal("oom", .{});
        writeText(self.io, self.arena, unit_dir, "paper-auto.timer", tmr) catch |e| self.fatal("could not write unit: {t}", .{e});

        _ = self.capture(&.{ "systemctl", "--user", "daemon-reload" });
        _ = self.capture(&.{ "systemctl", "--user", "enable", "--now", "paper-auto.timer" });
        self.info("Auto-change enabled: " ++ c.bold ++ "{s}" ++ c.rst ++ " ({s})", .{ label, oncal });
        if (query.len > 0) {
            self.info("Query: '{s}'  ·  categories: {s}  ·  source: {s}", .{ query, self.opt.categories, self.opt.source });
        } else {
            self.info("Fully random  ·  categories: {s}  ·  source: {s}", .{ self.opt.categories, self.opt.source });
        }
        self.autoStatus();
    }

    fn autoStatus(self: *App) void {
        if (self.capture(&.{ "systemctl", "--user", "is-enabled", "paper-auto.timer" })) |_| {
            self.say(c.bold ++ "Auto-change: " ++ c.grn ++ "on" ++ c.rst, .{});
            if (self.capture(&.{ "systemctl", "--user", "list-timers", "paper-auto.timer", "--no-pager" })) |out| {
                var lines = std.mem.splitScalar(u8, out, '\n');
                var i: usize = 0;
                while (lines.next()) |ln| : (i += 1) {
                    if (i >= 2) break;
                    self.say("{s}", .{ln});
                }
            }
        } else {
            self.say(c.bold ++ "Auto-change: " ++ c.yel ++ "off" ++ c.rst ++ "   (enable with: paper auto daily)", .{});
        }
    }

    fn autoRun(self: *App) void {
        self.opt.source = self.cfg.get("AUTO_SOURCE") orelse "wallhaven";
        self.opt.categories = self.cfg.get("AUTO_CATEGORIES") orelse "111";
        self.opt.preview = false;
        self.cmdRandom(self.cfg.get("AUTO_QUERY") orelse "");
    }

    /// Absolute path to this executable — systemd's ExecStart requires it.
    fn selfPath(self: *App) []const u8 {
        if (self.whichPath("paper")) |p| return p;
        return std.process.executablePathAlloc(self.io, self.arena) catch "paper";
    }

    fn xdgConfig(self: *App) []const u8 {
        if (self.env.get("XDG_CONFIG_HOME")) |x| return x;
        return std.fmt.allocPrint(self.arena, "{s}/.config", .{self.home}) catch "/tmp";
    }

    // -- usage ----------------------------------------------------------------
    fn usage(self: *App) void {
        self.err.writeAll(usage_text) catch {};
        self.err.flush() catch {};
    }
};

fn thumbTask(io: Io, gpa: Allocator, url: []const u8, path: []const u8) void {
    var client = http.Client.init(gpa, io);
    defer client.deinit();
    _ = client.downloadToFile(Io.Dir.cwd(), url, &.{}, null, path) catch return;
}

// -- free helpers -------------------------------------------------------------
fn jsonStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn encodeInto(w: *Io.Writer, s: []const u8) void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            w.writeByte(ch) catch {};
        } else {
            w.print("%{X:0>2}", .{ch}) catch {};
        }
    }
}

const JsonEscaped = struct {
    s: []const u8,
    pub fn format(self: JsonEscaped, w: *Io.Writer) Io.Writer.Error!void {
        for (self.s) |ch| switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        };
    }
};
fn jsonEscape(s: []const u8) JsonEscaped {
    return .{ .s = s };
}

fn fieldAt(line: []const u8, delim: u8, index: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, line, delim);
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == index) return f;
    }
    return null;
}

fn pickExt(url: []const u8) []const u8 {
    var end = url.len;
    if (std.mem.indexOfScalar(u8, url, '?')) |q| end = q;
    const path = url[0..end];
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "jpg";
    const ext = path[dot + 1 ..];
    if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg") or
        std.mem.eql(u8, ext, "png") or std.mem.eql(u8, ext, "webp")) return ext;
    return "jpg";
}

fn hasImageExt(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    var buf: [8]u8 = undefined;
    const ext = name[dot + 1 ..];
    if (ext.len >= buf.len) return false;
    const low = std.ascii.lowerString(buf[0..ext.len], ext);
    return std.mem.eql(u8, low, "jpg") or std.mem.eql(u8, low, "jpeg") or
        std.mem.eql(u8, low, "png") or std.mem.eql(u8, low, "webp");
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn joinArgs(arena: Allocator, args: []const []const u8) []const u8 {
    if (args.len == 0) return "";
    return std.mem.join(arena, " ", args) catch "";
}

fn writeText(io: Io, arena: Allocator, dir: []const u8, name: []const u8, text: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

// -- entry point --------------------------------------------------------------
pub fn main(init: std.process.Init) void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [8192]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_fw = Io.File.stdout().writer(io, &out_buf);
    var err_fw = Io.File.stderr().writer(io, &err_buf);

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/root";
    const cfg = config.Config.load(arena, io, home, init.environ_map.get("XDG_CONFIG_HOME")) catch {
        _ = err_fw.interface.writeAll("!! failed to load config\n") catch {};
        std.process.exit(1);
    };

    const lib_dir = init.environ_map.get("PAPER_DIR") orelse
        init.environ_map.get("WALLPAPER_DIR") orelse
        (std.fmt.allocPrint(arena, "{s}/Pictures/Wallpapers", .{home}) catch "/tmp");

    var app: App = .{
        .io = io,
        .gpa = gpa,
        .arena = arena,
        .env = init.environ_map,
        .out = &out_fw.interface,
        .err = &err_fw.interface,
        .cfg = cfg,
        .home = home,
        .lib_dir = lib_dir,
    };
    // Resolve the AI model default (config/env > built-in).
    app.opt.hf_model = app.secret("HF_MODEL") orelse default_model;

    const argv = init.minimal.args.toSlice(arena) catch app.fatal("out of memory", .{});
    run(&app, argv) catch |e| app.fatal("error: {t}", .{e});
}

fn run(self: *App, argv: []const [:0]const u8) !void {
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eqOpt(a, "-s", "--source")) {
            i += 1;
            self.opt.source = takeVal(self, argv, i, "--source");
        } else if (eqOpt(a, "-c", "--categories")) {
            i += 1;
            self.opt.categories = takeVal(self, argv, i, "--categories");
        } else if (eqOpt(a, "-p", "--purity")) {
            i += 1;
            self.opt.purity = takeVal(self, argv, i, "--purity");
        } else if (std.mem.eql(u8, a, "--sort")) {
            i += 1;
            self.opt.sorting = takeVal(self, argv, i, "--sort");
        } else if (eqOpt(a, "-n", "--limit")) {
            i += 1;
            const v = takeVal(self, argv, i, "--limit");
            self.opt.limit = std.fmt.parseInt(u32, v, 10) catch self.fatal("--limit expects a number", .{});
        } else if (std.mem.eql(u8, a, "--atleast")) {
            i += 1;
            self.opt.atleast = takeVal(self, argv, i, "--atleast");
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            self.opt.hf_model = takeVal(self, argv, i, "--model");
        } else if (std.mem.eql(u8, a, "--no-preview")) {
            self.opt.preview = false;
        } else if (eqOpt(a, "-v", "--version")) {
            self.say("paper {s}", .{version});
            return;
        } else if (eqOpt(a, "-h", "--help") or std.mem.eql(u8, a, "help")) {
            self.usage();
            return;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < argv.len) : (i += 1) try positional.append(self.arena, argv[i]);
            break;
        } else if (a.len > 0 and a[0] == '-') {
            self.fatal("unknown option: {s}", .{a});
        } else {
            try positional.append(self.arena, a);
        }
    }

    const cmd = if (positional.items.len > 0) positional.items[0] else "";
    const rest = if (positional.items.len > 0) positional.items[1..] else positional.items;

    if (cmd.len == 0 or std.mem.eql(u8, cmd, "search")) {
        const query = if (rest.len > 0) joinArgs(self.arena, rest) else promptQuery(self);
        if (query.len == 0) return;
        self.cmdSearch(query);
    } else if (std.mem.eql(u8, cmd, "random")) {
        self.cmdRandom(joinArgs(self.arena, rest));
    } else if (std.mem.eql(u8, cmd, "library") or std.mem.eql(u8, cmd, "lib")) {
        self.cmdLibrary();
    } else if (std.mem.eql(u8, cmd, "set")) {
        if (rest.len == 0) self.fatal("usage: paper set <path>", .{});
        self.apply(rest[0]);
    } else if (std.mem.eql(u8, cmd, "next")) {
        if (self.has("omarchy-theme-bg-next")) {
            _ = self.spawnWait(&.{"omarchy-theme-bg-next"});
        } else self.fatal("omarchy not found", .{});
    } else if (std.mem.eql(u8, cmd, "current")) {
        self.cmdCurrent();
    } else if (std.mem.eql(u8, cmd, "preview")) {
        self.cmdPreview(if (rest.len > 0) rest[0] else "");
    } else if (std.mem.eql(u8, cmd, "generate") or std.mem.eql(u8, cmd, "gen")) {
        self.cmdGenerate(joinArgs(self.arena, rest));
    } else if (std.mem.eql(u8, cmd, "config")) {
        self.cmdConfig(rest);
    } else if (std.mem.eql(u8, cmd, "version")) {
        self.say("paper {s}", .{version});
    } else if (std.mem.eql(u8, cmd, "auto")) {
        self.cmdAuto(rest);
    } else if (std.mem.eql(u8, cmd, "_auto_run")) {
        self.autoRun();
    } else {
        // `paper mountains` → search
        self.cmdSearch(joinArgs(self.arena, positional.items));
    }
}

fn promptQuery(self: *App) []const u8 {
    self.err.writeAll("Search wallpapers: ") catch {};
    self.err.flush() catch {};
    var buf: [1024]u8 = undefined;
    var r = Io.File.stdin().reader(self.io, &buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return "";
    return self.arena.dupe(u8, std.mem.trim(u8, line, " \t\r")) catch "";
}

fn eqOpt(a: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, a, short) or std.mem.eql(u8, a, long);
}

fn takeVal(self: *App, argv: []const [:0]const u8, i: usize, name: []const u8) []const u8 {
    if (i >= argv.len) self.fatal("{s} expects a value", .{name});
    return argv[i];
}

const usage_text =
    c.bold ++ "paper" ++ c.rst ++ " — fetch & set wallpapers for Omarchy from the best providers\n\n" ++
    c.bold ++ "BROWSE & SET" ++ c.rst ++ "\n" ++
    "  paper [search] <query...>     search a provider, pick with preview, set\n" ++
    "  paper                         prompt for a search term\n" ++
    "  paper random [query...]       grab one random match and set it now\n" ++
    "  paper library                 re-pick from wallpapers you've downloaded\n" ++
    "  paper set <path>              set a local image file\n" ++
    "  paper next                    cycle bg (wraps 'omarchy theme bg next')\n" ++
    "  paper current                 show the current wallpaper path\n" ++
    "  paper preview <path>          render an image in the terminal (chafa/imv)\n\n" ++
    c.bold ++ "AI GENERATION (Hugging Face open models)" ++ c.rst ++ "\n" ++
    "  paper generate <prompt...>    generate a wallpaper with an open model\n\n" ++
    c.bold ++ "API KEYS / CONFIG" ++ c.rst ++ "\n" ++
    "  paper config                  show current config (keys masked)\n" ++
    "  paper config keys             interactively enter API keys\n" ++
    "  paper config set-key <provider> <key>   wallhaven|unsplash|pexels|huggingface\n" ++
    "  paper config set-model <id>   set the AI generation model\n" ++
    "  paper config path             print the config file path\n\n" ++
    c.bold ++ "AUTO-CHANGE (systemd timer)" ++ c.rst ++ "\n" ++
    "  paper auto hourly|daily|weekly [query]\n" ++
    "  paper auto custom \"<expr>\" [query]   custom schedule (systemd OnCalendar)\n" ++
    "  paper auto status | off\n\n" ++
    c.bold ++ "OPTIONS" ++ c.rst ++ "\n" ++
    "  -s, --source <name>    wallhaven (default) | unsplash | pexels\n" ++
    "  -c, --categories <b>   wallhaven bitmask general/anime/people (default 111)\n" ++
    "  -p, --purity <b>       wallhaven bitmask sfw/sketchy/nsfw    (default 100)\n" ++
    "      --sort <mode>      relevance|random|toplist|views|favorites|date_added\n" ++
    "  -n, --limit <N>        number of results to fetch (default 24)\n" ++
    "      --atleast <WxH>    minimum resolution (default: your screen)\n" ++
    "      --model <id>       Hugging Face model for 'generate'\n" ++
    "      --no-preview       list without thumbnail previews\n" ++
    "  -v, --version          print version\n" ++
    "  -h, --help             this help\n";
