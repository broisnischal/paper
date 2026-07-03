//! Thin wrapper over std.http.Client — native HTTPS (TLS) with no `curl`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Header = std.http.Header;

pub const Response = struct {
    status: u16,
    body: []u8, // owned by caller's allocator
};

pub const Client = struct {
    inner: std.http.Client,
    io: Io,

    pub fn init(gpa: Allocator, io: Io) Client {
        return .{ .inner = .{ .allocator = gpa, .io = io }, .io = io };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// GET (or POST if `payload` given), collecting the response body into a
    /// freshly-allocated slice owned by `gpa`.
    pub fn fetchAlloc(
        self: *Client,
        gpa: Allocator,
        url: []const u8,
        headers: []const Header,
        payload: ?[]const u8,
    ) !Response {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const res = try self.inner.fetch(.{
            .location = .{ .url = url },
            .extra_headers = headers,
            .payload = payload,
            .response_writer = &aw.writer,
        });
        const body = try aw.toOwnedSlice();
        return .{ .status = @intFromEnum(res.status), .body = body };
    }

    /// GET `url`, streaming the response straight into `dir/sub_path`.
    /// Returns the HTTP status code.
    pub fn downloadToFile(
        self: *Client,
        dir: Io.Dir,
        url: []const u8,
        headers: []const Header,
        payload: ?[]const u8,
        sub_path: []const u8,
    ) !u16 {
        const io = self.io;
        var file = try dir.createFile(io, sub_path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(io, &buf);
        const res = try self.inner.fetch(.{
            .location = .{ .url = url },
            .extra_headers = headers,
            .payload = payload,
            .method = if (payload != null) .POST else .GET,
            .response_writer = &fw.interface,
        });
        try fw.interface.flush();
        return @intFromEnum(res.status);
    }
};
