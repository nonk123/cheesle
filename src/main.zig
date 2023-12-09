const std = @import("std");

const CheesleError = error{
    ArgsMismatch,
};

const Args = [][:0]u8;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

    try server.listen(address);

    {
        const out = std.io.getStdOut().writer();
        out.print("Listening on {}\n", .{address}) catch {};
    }

    try runServer(&server, allocator);
}

fn printUsage(args: Args) void {
    const out = std.io.getStdOut().writer();
    out.print("Usage: {s} <host> <port>\n", .{args[0]}) catch {};
}

fn runServer(server: *std.http.Server, allocator: std.mem.Allocator) !void {
    const log = std.io.getStdErr().writer();

    while (true) {
        var response = try server.accept(.{
            .allocator = allocator,
        });

        defer response.deinit();

        if (response.reset() != .closing) {
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue,
                error.EndOfStream => continue,
                else => return err,
            };

            handleRequest(&response, allocator) catch |err| {
                log.print("Server error: {}\n", .{err}) catch {};
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

        return .{
            .target = target,
            .mimeType = mimeType,
            .contents = contents,
        };
    }
};

fn sendFile(response: *std.http.Server.Response, mimeType: []const u8, contents: []const u8) !void {
    response.status = .ok;
    response.transfer_encoding = .chunked;

    try response.headers.append("content-type", mimeType);

    try response.do();
    try response.writeAll(contents);
    try response.finish();
}

fn handleRequest(response: *std.http.Server.Response, allocator: std.mem.Allocator) !void {
    _ = allocator; // TODO: use

    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    if (response.request.method != .GET) {
        response.status = .not_found;
        try response.do();

        return;
    }

    const target = response.request.target;

    if (std.mem.eql(u8, target, "/")) {
        const index = @embedFile("index.html");
        try sendFile(response, "text/html", index);
        return;
    }

    const routes = comptime [_]FileRoute{
        FileRoute.new("/favicon.ico", "image/vnd.microsoft.icon"),
        FileRoute.new("/index.css", "text/css"),
        FileRoute.new("/index.js", "text/javascript"),
    };

    inline for (routes) |route| {
        if (std.mem.eql(u8, route.target, target)) {
            try sendFile(response, route.mimeType, route.contents);
            return;
        }
    }

    response.status = .not_found;
    try response.do();
    try response.finish();
}
