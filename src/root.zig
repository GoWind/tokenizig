const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;
const Pair = struct {
    p0: u32,
    p1: u32,
};
// assigns a token ID to a bunch of bytes
// starting with id 0..25 for the first 8bit of values
// that is id 0 => null byte
// id 1 => 1
// id 2 => 2....
// when we find common pairs, such as 'ab' or ' x'
// we create a new token ID for this pair
// in the next run we merge these pairs together 'ab x' and then
// assigne a new token for this pair
const Vocab = std.AutoArrayHashMap(u32, []const u8);

// const PairCount = std.AutoArrayHashMap(Pair, usize);
const PairReplacement = std.AutoArrayHashMap(Pair, u32);
const PairCount = std.ArrayHashMap(Pair, u32, struct {
    pub fn eql(_: @This(), a: Pair, b: Pair, _: usize) bool {
        return a.p0 == b.p0 and a.p1 == b.p1;
    }
    pub fn hash(_: @This(), a: Pair) u32 {
        return @as(u32, @truncate(a.p0 * a.p1));
    }
}, false);
// get_stats in minbpe
fn maxFrequency(p: PairCount) Pair {
    var count: usize = std.math.minInt(usize);
    var pairPtr: *Pair = undefined;
    var iterator = p.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* > count) {
            count = entry.value_ptr.*;
            pairPtr = entry.key_ptr;
        }
    }
    return Pair{ .p0 = pairPtr.p0, .p1 = pairPtr.p1 };
}

fn minFrequency(p: PairCount) Pair {
    var count = std.math.maxInt(usize);
    var pairPtr: *Pair = undefined;
    var iterator = p.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* < count) {
            count = entry.value_ptr.*;
            pairPtr = entry.key_ptr;
        }
    }
    return Pair{ .p0 = pairPtr.p0, .p1 = pairPtr.p1 };
}

pub fn countConsecutivePairs(ids: []const u32, counts: *PairCount) !void {
    var i: usize = 0;
    while (i < ids.len - 1) : (i += 1) {
        const p = Pair{ .p0 = ids[i], .p1 = ids[i + 1] };
        if (counts.get(p)) |v| {
            try counts.put(p, v + 1);
        } else {
            try counts.put(p, 1);
        }
    }
}

pub fn merge(ids: []u32, outs: []u32, p1: u32, p2: u32, replacement: u32) usize {
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
    var og = [_]u8{ 1, 2, 3, 1, 2, 8, 11, 1, 2 };
    const expected = [_]u8{ 4, 3, 4, 8, 11, 4 };
    const mergedSize = merge(&og, &og, 1, 2, 4);
    try testing.expectEqualSlices(u8, &expected, og[0..mergedSize]);
}

pub const Tokenizer = struct {
    const SpecialTokens = std.StringArrayHashMap(u32);
    const Self = @This();

    allocator: std.mem.Allocator,
    // pattern: []const u8,
    merges: PairReplacement,
    special_tokens: SpecialTokens,
    vocab: Vocab,
    pub fn init(alloc: std.mem.Allocator) !Self {
        var vocab = Vocab.init(alloc);
        try Self.buildInitVocab(alloc, &vocab);
        return Self{
            .allocator = alloc,
            .special_tokens = SpecialTokens.init(alloc),
            .merges = PairReplacement.init(alloc),
            .vocab = vocab,
        };
    }

    fn buildInitVocab(allocator: std.mem.Allocator, vocab: *Vocab) !void {
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const val = try allocator.alloc(u8, 1);
            val[0] = @as(u8, @truncate(i));
            try vocab.put(@as(u32, i), val);
        }
    }

    pub fn train(self: *Self, unicodeStr: unicode.Utf8View, vocab: usize) !void {
        if (vocab < 256) {
            @panic("vocab must be atleast 256 in size");
        }
        // The type of copy depends on vocab size (eg, for a vocab of 32768, it could just be []u16)
        // keeping it []u32 and then optimizing later
        var copy = try self.allocator.alloc(u32, unicodeStr.bytes.len);
        for (unicodeStr.bytes, 0..) |byte, idx| {
            copy[idx] = byte;
        }
        const numMerges = vocab - 256;
        var pairCount = PairCount.init(self.allocator);
        var i: usize = 0;
        while (i < numMerges) : (i += 1) {
            try countConsecutivePairs(copy, &pairCount);
            // Find pair with max frequency
            const pair = maxFrequency(pairCount);
            const replacementIdx = 256 + @as(u32, @truncate(i));
            const afterCopy = merge(copy, copy, pair.p0, pair.p1, replacementIdx);
            try self.merges.put(pair, replacementIdx);
            std.debug.print("iter {}, merging {} {} -> {}\n", .{ i, pair.p0, pair.p1, replacementIdx });
            const concatenatedValue = try std.mem.concat(self.allocator, u8, &[_][]const u8{ self.vocab.get(pair.p0).?, self.vocab.get(pair.p1).? });
            try self.vocab.put(replacementIdx, concatenatedValue);
            _ = pairCount.swapRemove(pair);
            copy = copy[0..afterCopy];
        }
    }

    pub fn encode(self: Self, text: unicode.Utf8View) ![]u32 {
        const copy = try self.allocator.alloc(u32, text.bytes.len);
        @memcpy(copy, text.bytes);
        const pairCount = PairCount.init(self.allocator);
        while (copy.len >= 2) {
            countConsecutivePairs(copy, &pairCount);
            // of all pairs (p0, p1) in pairCount, we try to find
            // min(merge.get(p0, p1)) if it exists

            var iter = pairCount.iterator();
            var minMergedValue = std.math.maxInt(u32);
            var minPair: *Pair = undefined;
            while (iter.next()) |entry| {
                const maybeMergedIdx = self.merges.get(entry.key_ptr.*);
                if (maybeMergedIdx) |mergedIdx| {
                    if (mergedIdx < minMergedValue) {
                        minMergedValue = mergedIdx;
                        minPair = entry.key_ptr;
                    }
                }
            }
            if (minPair == undefined) {
                break;
            }
            //minMergedValue points to the smallest merge
            merge(copy, copy, minPair.p0, minPair.p1, minMergedValue);
            pairCount.clearRetainingCapacity();
        }
        return copy;
    }

    pub fn printMerge(self: Self) void {
        var iterator = self.merges.iterator();
        while (iterator.next()) |iter| {
            const key = iter.key_ptr.*;
            const value = iter.value_ptr.*;
            std.debug.print("({d}, {d}) -> {d}\n", .{ key.p0, key.p1, value });
        }
    }

    pub fn printVocab(self: Self) void {
        var iterator = self.vocab.iterator();
        while (iterator.next()) |iter| {
            const key = iter.key_ptr.*;
            const value = iter.value_ptr.*;
            std.debug.print("({d}) -> {d}\n", .{ key, value });
        }
    }
    pub fn decode(self: Self, tokens: []u32) !unicode.Utf8View {
        const BytesArray = std.ArrayList(u8);
        const stringBytes = BytesArray.init(self.allocator);
        for (tokens) |t| {
            const codePoints: []const u8 = self.vocab.get(t).?;
            try stringBytes.appendSlice(codePoints);
        }
        return unicode.Utf8View.init(stringBytes.items);
    }
};
