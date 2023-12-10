const std = @import("std");

const root = @import("root");
const respond = @import("respond.zig");

const State = root.State;
const Response = std.http.Server.Response;

pub fn Route(comptime Self: type, comptime matchFn: *const fn (*const Self, *const State, *const Response) anyerror!bool, comptime handleFn: *const fn (*const Self, *State, *Response) anyerror!void) type {
    return struct {
        const Pointer = *const Self;
        const RouteSelf = @This();

        ptr: Pointer,

        pub fn init(p: Pointer) RouteSelf {
            return RouteSelf{ .ptr = p };
        }

        pub fn match(self: RouteSelf, state: *const State, response: *const Response) anyerror!bool {
            return matchFn(self.ptr, state, response);
        }

        pub fn handle(self: RouteSelf, state: *State, response: *Response) anyerror!void {
            return handleFn(self.ptr, state, response);
        }
    };
}

pub const FileRoute = struct {
    target: []const u8,
    mimeType: []const u8,
    path: []const u8,

    const Self = @This();
    const RouteType = Route(FileRoute, Self.match, Self.handle);

    fn route(self: *const Self) RouteType {
        return RouteType.init(self);
    }

    fn match(self: *const Self, state: *const State, response: *const Response) anyerror!bool {
        _ = state;

        const targetMatch = std.mem.eql(u8, response.request.target, self.target);
        const methodMatch = response.request.method == .GET;

        return targetMatch and methodMatch;
    }

    fn handle(self: *const Self, state: *State, response: *Response) anyerror!void {
        _ = state;

        var file = try std.fs.cwd().openFile(self.path, .{});
        defer file.close();

        response.status = .ok;
        response.transfer_encoding = .chunked;

        try response.headers.append("content-type", self.mimeType);

        try response.do();

        var buf: [4096]u8 = undefined;

        while (true) {
            const read = try file.reader().read(&buf);

            if (read == 0) {
                break;
            }

            _ = try response.write(buf[0..read]);
        }

        try response.finish();
    }
};

pub const StaticRoute = struct {
    target: []const u8,
    method: std.http.Method,
    handler: *const fn (*State, *Response) anyerror!void,

    const Self = @This();
    const RouteType = Route(StaticRoute, Self.match, Self.handle);

    fn route(self: *const Self) RouteType {
        return RouteType.init(self);
    }

    fn match(self: *const Self, state: *const State, response: *const Response) anyerror!bool {
        _ = state;

        const targetMatch = std.mem.eql(u8, response.request.target, self.target);
        const methodMatch = response.request.method == self.method;

        return targetMatch and methodMatch;
    }

    fn handle(self: *const Self, state: *State, response: *Response) anyerror!void {
        return self.handler(state, response);
    }
};

pub fn handleRoutes(state: *State, response: *Response, comptime tup: anytype) !void {
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    inline for (tup) |router| {
        var route = router.route();

        if (try route.match(state, response)) {
            try route.handle(state, response);
            return;
        }
    }

    try respond.notFound(response);
}
