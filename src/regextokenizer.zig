const jstring = @import("jstring");
const std = @import("std");
const allocator = std.mem.allocator;
const rootModule = @import("./root.zig");
const unicode = std.unicode;
const StringChunks = std.ArrayList([]32);
const gpt2Pattern = "'(?:[sdmt]|ll|ve|re)| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+";
const gpt4Pattern = "'(?i:[sdmt]|ll|ve|re)|[^\r\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\r\n]*|\\s*[\r\n]|\\s+(?!\\S)|\\s+";

const RegexTokenizer = struct {
    pattern: []const u8,
    alloc: allocator,
    // pattern: []const u8,
    merges: rootModule.PairReplacement,
    special_tokens: rootModule.SpecialTokens,
    vocab: rootModule.Vocab,
    const Self = @This();
    pub fn init(alloc: std.mem.Allocator, maybe_pattern: ?[]const u8) !Self {
        var vocab = rootModule.Vocab.init(alloc);
        try Self.buildInitVocab(alloc, &vocab);
        const pat = if (maybe_pattern) |pattern| pattern else gpt4Pattern;
        const copy = try alloc.alloc(u8, pat.len);
        std.mem.copyForwards(u8, copy, pat);

        return Self{
            .allocator = alloc,
            .special_tokens = rootModule.SpecialTokens.init(alloc),
            .merges = rootModule.PairReplacement.init(alloc),
            .vocab = vocab,
        };
    }

    fn buildInitVocab(alloc: std.mem.Allocator, vocab: *rootModule.Vocab) !void {
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const val = try alloc.alloc(u8, 1);
            val[0] = @as(u8, @truncate(i));
            try vocab.put(@as(u32, i), val);
        }
    }

    pub fn train(self: *Self, unicodeStr: jstring.JString, vocab: usize) !void {
        if (vocab < 256) {
            @panic("vocab must be atleast 256 in size");
        }
        var pairCount = rootModule.PairCount.init(self.allocator);
        const chunks = StringChunks.init(allocator);
        var matches = unicodeStr.matchAll(self.pattern, 0, 0, 0);
        std.debug.assert(matches.matchSucceed() == true);
        const results = matches.getResults().?;
        for (results) |result| {
            var chunk = std.ArrayList(u32).init(allocator);
            const start = result.start;
            var i: usize = 0;

            while (i < result.len) : (i += 1) {
                try chunk.append(unicodeStr.charAt(@as(isize, @intCast(start + i))));
                try chunks.append(try chunk.toOwnedSlice());
            }
        }

        const numMerges = vocab - 256;
        var i: usize = 0;
        while (i < numMerges) : (i += 1) {
            for (chunks.items) |chunk| {
                rootModule.countConsecutivePairs(chunk.items, &pairCount);
            }
            const pair = rootModule.maxFrequency(pairCount);
            const replacementIdx = 256 + @as(u32, @truncate(i));
            for (chunks.items) |*chunk| {
                const reducedSize = rootModule.merge(chunk.items, chunk.items, pair.p0, pair.p1, replacementIdx);
                chunk = chunk[0..reducedSize];
            }
            std.debug.print("iter {}, merging {} {} -> {}\n", .{ i, pair.p0, pair.p1, replacementIdx });
            const concatenatedValue = try std.mem.concat(self.allocator, u8, &[_][]const u8{ self.vocab.get(pair.p0).?, self.vocab.get(pair.p1).? });
            // the characters represented by this new token
            try self.vocab.put(replacementIdx, concatenatedValue);
            _ = pairCount.swapRemove(pair);
        }

        //TODO: How do I dealloc the chunks?
    }

    pub fn printMerge(self: Self) void {
        var iterator = self.merges.iterator();
        while (iterator.next()) |iter| {
            const key = iter.key_ptr.*;
            const value = iter.value_ptr.*;
            std.debug.print("({d}, {d}) -> {d}\n", .{ key.p0, key.p1, value });
        }
    }
};

test "test stuff" {
    _ = RegexTokenizer;
}
