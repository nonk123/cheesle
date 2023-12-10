const std = @import("std");
const uuid = @import("uuid");

const CheesleError = error{
    ArgsMismatch,
};

const Args = [][:0]u8;

const State = struct {
    gpa: std.mem.Allocator,
    sessions: std.AutoHashMap(uuid.UUID, Session),
    server: std.http.Server,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var state = State{
        .gpa = gpa.allocator(),
        .sessions = undefined,
        .server = undefined,
    };

    state.sessions = std.AutoHashMap(uuid.UUID, Session).init(state.gpa);
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

fn sendFile(response: *std.http.Server.Response, mimeType: []const u8, contents: []const u8) !void {
    response.status = .ok;
    response.transfer_encoding = .chunked;

    try response.headers.append("content-type", mimeType);

    try response.do();
    try response.writeAll(contents);
    try response.finish();
}

const Session = struct {
    id: uuid.UUID,
    word: []const u8, // ASCII only for now
    attemptsLeft: u8,
    won: bool,
    creationTime: i64,

    fn new() Session {
        return Session{
            .id = uuid.UUID.init(),
            .word = "CHEEZ",
            .attemptsLeft = 5,
            .won = false,
            .creationTime = std.time.timestamp(),
        };
    }
};

const Guess = struct {
    sessionId: uuid.UUID,
    word: []const u8,
};

const GuessRaw = struct {
    sessionId: []const u8,
    word: []const u8,

    const Error = error{
        WordLengthMismatch,
    };

    fn convert(self: *const GuessRaw) !Guess {
        if (self.word.len != 5) {
            return Error.WordLengthMismatch;
        }

        const sessionId = try uuid.UUID.parse(self.sessionId);

        return Guess{
            .sessionId = sessionId,
            .word = self.word[0..5],
        };
    }
};

const GuessResponse = struct {
    lettersCorrect: [5]bool,
    attemptsLeft: u8,
};

fn createSession(state: *State, response: *std.http.Server.Response) !void {
    try pruneSessions(state);

    const session = Session.new();
    try state.sessions.put(session.id, session);

    const needle = "{%%%}";
    const replacement = try std.fmt.allocPrint(state.gpa, "{}", .{session.id});

    const index = @embedFile("index.html");

    var buf = try state.gpa.alloc(u8, index.len + 1024);
    defer state.gpa.free(buf);

    const count = std.mem.replace(u8, index, needle, replacement, buf);

    const end = index.len + count * (replacement.len - needle.len);

    try sendFile(response, "text/html", buf[0..end]);
}

fn makeAGuess(state: *State, response: *std.http.Server.Response) !void {
    const body = try response.reader().readAllAlloc(state.gpa, 1024);
    defer state.gpa.free(body);

    const parsed = try std.json.parseFromSlice(GuessRaw, state.gpa, body, .{});
    defer parsed.deinit();

    const guess = try parsed.value.convert();

    var session = state.sessions.getPtr(guess.sessionId) orelse {
        response.status = .not_found;
        try response.do();
        return;
    };

    if (session.won or session.attemptsLeft == 0) {
        response.status = .not_found;
        try response.do();
        return;
    }

    session.attemptsLeft -= 1;

    var resp = GuessResponse{
        .lettersCorrect = undefined,
        .attemptsLeft = session.attemptsLeft,
    };

    var allCorrect = true;

    for (0..5) |idx| {
        const correct = guess.word[idx] == session.word[idx];
        resp.lettersCorrect[idx] = correct;

        if (!correct) {
            allCorrect = false;
        }
    }

    session.won = allCorrect;

    var json = std.ArrayList(u8).init(state.gpa);
    defer json.deinit();

    try std.json.stringify(resp, .{}, json.writer());

    response.status = .ok;
    response.transfer_encoding = .chunked;

    try response.headers.append("content-type", "application/json");

    try response.do();
    try response.writeAll(json.items);
    try response.finish();
}

fn handleRequest(state: *State, response: *std.http.Server.Response) !void {
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    const method = response.request.method;
    const target = response.request.target;

    if (method == .GET and std.mem.eql(u8, target, "/")) {
        try createSession(state, response);
        return;
    }

    if (method == .POST and std.mem.eql(u8, target, "/guess")) {
        try makeAGuess(state, response);
        return;
    }

    if (method != .GET) {
        response.status = .not_found;
        try response.do();
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
}

const SESSION_TIMEOUT_SECS: i64 = 3600;

fn pruneSessions(state: *State) !void {
    var iter = state.sessions.iterator();

    var rmQueue = std.ArrayList(uuid.UUID).init(state.gpa);
    defer rmQueue.deinit();

    while (iter.next()) |entry| {
        const session = entry.value_ptr;

        const now = std.time.timestamp();
        const then = session.creationTime;

        if (session.won or now - then > SESSION_TIMEOUT_SECS) {
            (try rmQueue.addOne()).* = session.id;
        }
    }

    for (rmQueue.items) |id| {
        _ = state.sessions.remove(id);
    }
}
