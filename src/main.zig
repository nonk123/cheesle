const std = @import("std");

const uuid = @import("uuid");

const session = @import("session.zig");
const respond = @import("respond.zig");
const guess = @import("guess.zig");

pub const State = struct {
    gpa: std.mem.Allocator,
    sessions: std.AutoHashMap(uuid.UUID, session.Session),
    server: std.http.Server,
};

const CheesleError = error{
    ArgsMismatch,
};

const Args = [][:0]u8;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var state = State{
        .gpa = gpa.allocator(),
        .sessions = undefined,
        .server = undefined,
    };

    state.sessions = std.AutoHashMap(uuid.UUID, session.Session).init(state.gpa);
    defer state.sessions.deinit();

    state.server = std.http.Server.init(state.gpa, .{ .reuse_address = true });
    defer state.server.deinit();

    const args = try std.process.argsAlloc(state.gpa);
    defer std.process.argsFree(state.gpa, args);

    if (args.len != 3) {
        printUsage(args);
        return CheesleError.ArgsMismatch;
    }

    const serverAddress = args[1];

    const serverPort = std.fmt.parseUnsigned(u16, args[2], 10) catch |err| {
        printUsage(args);
        return err;
    };

    const address = std.net.Address.parseIp(serverAddress, serverPort) catch |err| {
        printUsage(args);
        return err;
    };

    try state.server.listen(address);

    {
        const out = std.io.getStdOut().writer();
        out.print("Listening on {}\n", .{address}) catch {};
    }

    try runServer(&state);
}

fn printUsage(args: Args) void {
    const out = std.io.getStdOut().writer();
    out.print("Usage: {s} <host> <port>\n", .{args[0]}) catch {};
}

fn runServer(state: *State) !void {
    const log = std.io.getStdErr().writer();

    while (true) {
        var response = try state.server.accept(.{
            .allocator = state.gpa,
        });

        defer response.deinit();

        if (response.reset() != .closing) {
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue,
                error.EndOfStream => continue,
                else => return err,
            };

            handleRequest(state, &response) catch |err| {
                log.print("Server error: {}\n", .{err}) catch {};

                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }

                // One-of-a-kind response; no need to move into `respond`.
                response.status = .internal_server_error;
                response.do() catch {};
            };
        }

        _ = response.reset();
    }
}

const FileRoute = struct {
    target: []const u8,
    mimeType: []const u8,
    contents: []const u8,

    fn new(comptime target: []const u8, mimeType: []const u8) FileRoute {
        // Strip the leading slash to avoid looking into the filesystem root.
        const contents = @embedFile(target[1..]);

        return FileRoute{
            .target = target,
            .mimeType = mimeType,
            .contents = contents,
        };
    }
};

fn handleRequest(state: *State, response: *std.http.Server.Response) !void {
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    const method = response.request.method;
    const target = response.request.target;

    if (method == .GET and std.mem.eql(u8, target, "/")) {
        try session.handle(state, response);
        return;
    }

    if (method == .POST and std.mem.eql(u8, target, "/guess")) {
        try guess.handle(state, response);
        return;
    }

    const routes = comptime [_]FileRoute{
        FileRoute.new("/favicon.ico", "image/vnd.microsoft.icon"),
        FileRoute.new("/index.css", "text/css"),
        FileRoute.new("/index.js", "text/javascript"),
    };

    inline for (routes) |route| {
        if (method == .GET and std.mem.eql(u8, route.target, target)) {
            try respond.file(response, route.mimeType, route.contents);
            return;
        }
    }

    try respond.notFound(response);
}
