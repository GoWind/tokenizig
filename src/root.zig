const std = @import("std");
const testing = std.testing;

pub fn getStats(ids: []u8) []u32 {
    const counts = [_]u32{0} ** 16384;
    var i: usize = 0;
    while (i < counts.len - 1) : (i += 1) {
        const idx = (ids[i] << 8) | (ids[i + 1]);
        counts[idx] += 1;
    }
    return counts;
}

pub fn merge(ids: []const u8, outs: []u8, p1: u8, p2: u8, replacement: u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < ids.len - 1) {
        if (ids[i] == p1 and ids[i + 1] == p2) {
            outs[j] = replacement;
            j += 1;
            i += 2;
        } else {
            outs[j] = ids[i];
            j += 1;
            i += 1;
        }
    }
    return j;
}

test "basic add functionality" {
    const og = [_]u8{ 1, 2, 3, 1, 2, 8, 11, 1, 2 };
    var replacement = [_]u8{0} ** og.len;
    const expected = [_]u8{ 4, 3, 4, 8, 11, 4 };
    const mergedSize = merge(&og, &replacement, 1, 2, 4);
    try testing.expectEqualSlices(u8, &expected, replacement[0..mergedSize]);
}

const Tokenizer = struct {
    const SpecialTokens = std.HashMap([]const u8, u32);
    const Vocab = std.HashMap(u32, u8);
    const Self = @This();

    allocator: std.mem.Allocator,
    pattern: []const u8,
    merges: []u32,
    special_token: SpecialTokens,
    vocab: Vocab,
    pub fn init(alloc: std.mem.Allocator) Self {
        var vocab = Vocab.init(alloc);
        Self.buildInitVocab(&vocab);
        return Self{
            .allocator = alloc,
            .special_tokens = SpecialTokens.init(alloc),
            .vocab = vocab,
        };
    }

    fn buildInitVocab(vocab: *Vocab) !void {
        var i: u8 = 0;
        while (i < @as(u16, 256)) : (i += 1) {
            try vocab.put(@as(u32, i), i);
        }
    }
};
