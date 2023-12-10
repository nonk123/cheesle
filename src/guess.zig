const std = @import("std");

const uuid = @import("uuid");

const root = @import("root");
const respond = @import("respond.zig");

const Response = std.http.Server.Response;

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

pub fn handle(state: *root.State, response: *Response) !void {
    const body = try response.reader().readAllAlloc(state.gpa, 1024);
    defer state.gpa.free(body);

    const parsed = try std.json.parseFromSlice(GuessRaw, state.gpa, body, .{});
    defer parsed.deinit();

    const guess = try parsed.value.convert();

    var session = state.sessions.getPtr(guess.sessionId) orelse {
        try respond.notFound(response);
        return;
    };

    if (session.won or session.attemptsLeft == 0) {
        try respond.notFound(response);
        return;
    }

    session.attemptsLeft -= 1;

    var resp = GuessResponse{
        .lettersCorrect = undefined,
        .attemptsLeft = session.attemptsLeft,
    };

    var allCorrect = true;

    for (0..5) |idx| {
        const guessedLetter = std.ascii.toUpper(guess.word[idx]);
        const correctLetter = std.ascii.toUpper(session.word[idx]);

        const correct = guessedLetter == correctLetter;
        resp.lettersCorrect[idx] = correct;

        if (!correct) {
            allCorrect = false;
        }
    }

    session.won = allCorrect;

    var json = std.ArrayList(u8).init(state.gpa);
    defer json.deinit();

    try std.json.stringify(resp, .{}, json.writer());
    try respond.json(response, json.items);
}
