const std = @import("std");

var PRNG: std.rand.DefaultPrng = undefined;

pub fn initPRNG() !void {
    PRNG = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
}

pub fn randomWord() []const u8 {
    const wordlist = comptime @embedFile("wordlist/valid-wordle-words.txt");
    const wordCount = comptime wordlist.len / 6;

    const wordIdx: usize = PRNG.next() % wordCount;

    const start = wordIdx * 6;
    const end = start + 5;

    const word = wordlist[start..end];
    return word;
}
