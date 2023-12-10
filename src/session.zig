const std = @import("std");

const uuid = @import("uuid");

const root = @import("root");
const respond = @import("respond.zig");
const wordlist = @import("wordlist.zig");

const SESSION_TIMEOUT_SECS: i64 = 3600;

pub const Session = struct {
    id: uuid.UUID,
    word: []const u8, // ASCII only for now
    attemptsLeft: u8,
    won: bool,
    creationTime: i64,

    fn new() Session {
        return Session{
            .id = uuid.UUID.init(),
            .word = wordlist.randomWord(),
            .attemptsLeft = 5,
            .won = false,
            .creationTime = std.time.timestamp(),
        };
    }
};

fn pruneSessions(state: *root.State) !void {
    var iter = state.sessions.iterator();

    var rmQueue = std.ArrayList(uuid.UUID).init(state.gpa);
    defer rmQueue.deinit();

    while (iter.next()) |entry| {
        const session = entry.value_ptr;

        const now = std.time.timestamp();
        const then = session.creationTime;

        const over = session.won or session.attemptsLeft == 0;
        const timeout = now - then > SESSION_TIMEOUT_SECS;

        if (over or timeout) {
            (try rmQueue.addOne()).* = session.id;
        }
    }

    for (rmQueue.items) |id| {
        _ = state.sessions.remove(id);
    }
}

pub fn handle(state: *root.State, response: *std.http.Server.Response) !void {
    try pruneSessions(state);

    const session = Session.new();
    try state.sessions.put(session.id, session);

    const needle = "{%%%}";
    const replacement = try std.fmt.allocPrint(state.gpa, "{}", .{session.id});

    var file = try std.fs.cwd().openFile("assets/index.html", .{});
    defer file.close();

    const index = try file.reader().readAllAlloc(state.gpa, 10240);
    defer state.gpa.free(index);

    var buf = try state.gpa.alloc(u8, index.len + 1024);
    defer state.gpa.free(buf);

    const count = std.mem.replace(u8, index, needle, replacement, buf);
    const end = index.len + count * (replacement.len - needle.len);

    try respond.file(response, "text/html", buf[0..end]);
}
