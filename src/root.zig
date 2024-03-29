const jstring = @import("jstring");
const std = @import("std");
const unicode = std.unicode;
const StringChunks = std.ArrayList([]u32);
const gpt2Pattern = "'(?:[sdmt]|ll|ve|re)| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+";
const gpt4Pattern = "'(?i:[sdmt]|ll|ve|re)|[^\r\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\r\n]*|\\s*[\r\n]|\\s+(?!\\S)|\\s+";
const testing = std.testing;

pub const Pair = struct {
    p0: u32,
    p1: u32,
};
// assigns a token ID to a bunch of bytes
// starting with id 0..255 for the first 8bit of values
// that is id 0 => null byte
// id 1 => 1
// id 2 => 2....
// when we find common pairs, such as 'ab' or ' x'
// we create a new token ID for this pair
// in the next run we merge these pairs together 'ab x' and then
// assigne a new token for this pair
pub const Vocab = std.AutoArrayHashMap(u32, []const u8);
pub const SpecialTokens = std.StringArrayHashMap(u32);

/// Track the replacement for a given pair of u32 tokens
pub const PairReplacement = std.AutoArrayHashMap(Pair, u32);
pub const PairCounts = std.ArrayHashMap(Pair, u32, struct {
    pub fn eql(_: @This(), a: Pair, b: Pair, _: usize) bool {
        return a.p0 == b.p0 and a.p1 == b.p1;
    }
    pub fn hash(_: @This(), a: Pair) u32 {
        return @as(u32, @truncate(a.p0 * a.p1));
    }
}, false);

/// Return the pair with the highest frequency
pub fn maxFrequency(p: PairCounts) Pair {
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

/// Return the pair with the lowest frequency
pub fn minFrequency(p: PairCounts) Pair {
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

/// Count the frequency of each pair of consecutive tokens
pub fn countConsecutivePairs(ids: []const u32, counts: *PairCounts) !void {
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

pub const BasicTokenizer = struct {
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

    pub fn deinit(self: *Self) void {
        self.merges.deinit();
        self.special_tokens.deinit();
        var vocabIterator = self.vocab.iterator();
        while (vocabIterator.next()) |val| {
            self.allocator.free(val.value_ptr.*);
        }
        self.vocab.deinit();
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
        defer self.allocator.free(copy);
        for (unicodeStr.bytes, 0..) |byte, idx| {
            copy[idx] = byte;
        }
        const numMerges = vocab - 256;
        var pairCount = PairCounts.init(self.allocator);
        defer pairCount.deinit();
        var i: usize = 0;
        while (i < numMerges) : (i += 1) {
            try countConsecutivePairs(copy, &pairCount);
            // Find pair with max frequency
            const pair = maxFrequency(pairCount);
            // calculate its replacement token
            const replacementIdx = 256 + @as(u32, @truncate(i));
            // replace pair in our token stream with the replacement token
            const afterCopy = merge(copy, copy, pair.p0, pair.p1, replacementIdx);
            // store the association of our pair -> its replacement
            try self.merges.put(pair, replacementIdx);
            std.debug.print("iter {}, merging {} {} -> {}\n", .{ i, pair.p0, pair.p1, replacementIdx });
            const concatenatedValue = try std.mem.concat(self.allocator, u8, &[_][]const u8{ self.vocab.get(pair.p0).?, self.vocab.get(pair.p1).? });
            // the characters represented by this new token
            try self.vocab.put(replacementIdx, concatenatedValue);
            _ = pairCount.swapRemove(pair);
            copy = copy[0..afterCopy];
        }
    }

    pub fn encode(self: Self, text: unicode.Utf8View) ![]u32 {
        const copy = try self.allocator.alloc(u32, text.bytes.len);
        @memcpy(copy, text.bytes);
        const pairCount = PairCounts.init(self.allocator);
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

pub const RegexTokenizer = struct {
    pattern: []const u8,
    alloc: std.mem.Allocator,
    // pattern: []const u8,
    merges: PairReplacement,
    special_tokens: SpecialTokens,
    vocab: Vocab,
    const Self = @This();
    pub fn init(alloc: std.mem.Allocator, maybe_pattern: ?[]const u8) !Self {
        var vocab = Vocab.init(alloc);
        try Self.buildInitVocab(alloc, &vocab);
        const pat = if (maybe_pattern) |pattern| pattern else gpt4Pattern;
        const copy = try alloc.alloc(u8, pat.len);
        std.mem.copyForwards(u8, copy, pat);

        return Self{
            .alloc = alloc,
            .merges = PairReplacement.init(alloc),
            .pattern = copy,
            .special_tokens = SpecialTokens.init(alloc),
            .vocab = vocab,
        };
    }

    pub fn deinit(self: *Self) void {
        self.merges.deinit();
        self.special_tokens.deinit();
        var vocabIterator = self.vocab.iterator();
        while (vocabIterator.next()) |val| {
            self.alloc.free(val.value_ptr.*);
        }
        self.vocab.deinit();
        self.alloc.free(self.pattern);
    }

    fn buildInitVocab(alloc: std.mem.Allocator, vocab: *Vocab) !void {
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
        var pairCount = PairCounts.init(self.alloc);
        var chunks = StringChunks.init(self.alloc);
        var matches = try unicodeStr.matchAll(self.pattern, 0, 0, 0);
        std.debug.assert(matches.matchSucceed() == true);
        const results = matches.getResults().?;
        std.debug.print("number of matches is {}\n", .{results.len});
        for (results) |result| {
            var chunk = std.ArrayList(u32).init(self.alloc);
            const start = result.start;
            var i: usize = 0;
            // Turn the string into a list of u32
            while (i < result.len) : (i += 1) {
                try chunk.append(try unicodeStr.charAt(@as(isize, @intCast(start + i))));
            }

            try chunks.append(try chunk.toOwnedSlice());
        }

        const numMerges = vocab - 256;
        var i: usize = 0;
        while (i < numMerges) : (i += 1) {
            for (chunks.items) |chunk| {
                try countConsecutivePairs(chunk, &pairCount);
            }
            const pair = maxFrequency(pairCount);
            const replacementIdx = 256 + @as(u32, @truncate(i));
            for (chunks.items) |*cc| {
                var chunk = cc.*;
                const reducedSize = merge(chunk, chunk, pair.p0, pair.p1, replacementIdx);
                chunk = chunk[0..reducedSize];
            }
            std.debug.print("iter {}, merging {} {} -> {}\n", .{ i, pair.p0, pair.p1, replacementIdx });
            try self.merges.put(pair, replacementIdx);
            const concatenatedValue = try std.mem.concat(self.alloc, u8, &[_][]const u8{ self.vocab.get(pair.p0).?, self.vocab.get(pair.p1).? });
            // the characters represented by this new token
            try self.vocab.put(replacementIdx, concatenatedValue);
            _ = pairCount.swapRemove(pair);
        }
    }

    pub fn printMerge(self: Self) void {
        var iterator = self.merges.iterator();
        while (iterator.next()) |iter| {
            const key = iter.key_ptr.*;
            const value = iter.value_ptr.*;
            std.debug.print("({d}, {d}) -> {d}\n", .{ key.p0, key.p1, value });
        }
    }

    pub fn save(self: Self) !void {
        const dir = std.fs.cwd();
        const file = try dir.createFile("regextokenizer.model", .{ .truncate = true });
        defer file.close();
        var writer = file.writer();
        try writer.print("minbpe v1\n", .{});
        var formattedPattern = std.ArrayList(u8).init(self.alloc);
        defer formattedPattern.deinit();
        for (self.pattern) |c| {
            if (c == '\r') {
                try formattedPattern.append('\\');
                try formattedPattern.append('r');
            } else if (c == '\n') {
                try formattedPattern.append('\\');
                try formattedPattern.append('n');
            } else {
                try formattedPattern.append(c);
            }
        }
        try writer.print("{s}\n", .{formattedPattern.items});
        try writer.print("{d}\n", .{self.special_tokens.count()});
        var specialtokeniterator = self.special_tokens.iterator();
        while (specialtokeniterator.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        var iterator = self.merges.iterator();
        while (iterator.next()) |iter| {
            const key = iter.key_ptr.*;
            try writer.print("{d} {d}\n", .{ key.p0, key.p1 });
        }
    }

    fn buildVocab(self: *Self) !void {
        var replacements = self.merges.iterator();
        while (replacements.next()) |replacement| {
            const pair = replacement.key_ptr.*;
            const idx = replacement.value_ptr.*;
            const value = try std.mem.concat(self.alloc, u8, &[_][]const u8{ self.vocab.get(pair.p0).?, self.vocab.get(pair.p1).? });
            try self.vocab.put(idx, value);
        }

        var specialTokeIter = self.special_tokens.iterator();
        while (specialTokeIter.next()) |entry| {
            const specialToken = entry.key_ptr.*;
            const idx = entry.value_ptr.*;
            try self.vocab.put(idx, specialToken);
        }
    }

    pub fn encode_chunk(self: Self, alloc: std.mem.Allocator, text_chunk: []u8) ![]u32 {
        var tokens = std.ArrayList(u32).init(alloc);
        var pairCounts = PairCounts.init(alloc);
        for(text_chunk) |c| {
            try tokens.append(@as(u32, @intCast(c)));
        }
        while(tokens.items.len >= 2) {
            countConsecutivePairs(tokens, &pairCounts);
            const minPair = minFrequency(pairCounts);
            if(self.merges.get(minPair)) |replacement| {
                const afterCopy = merge(tokens.items, tokens.items, minPair.p0, minPair.p1, replacement);
                tokens.items = tokens.items[0..afterCopy];
            } else {
                break;
            }
        }

        return tokens.toOwnedSlice();
            
    }

    pub fn 
    

    pub fn load(self: *Self, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        var reader = file.reader();
        const header = try reader.readUntilDelimiterAlloc(self.alloc, '\n', 500);
        defer self.alloc.free(header);
        if (!std.mem.eql(u8, header, "minbpe v1")) {
            @panic("invalid header");
        }
        self.pattern = try reader.readUntilDelimiterAlloc(self.alloc, '\n', 500);
        const numSpecialTokensStr = try reader.readUntilDelimiterAlloc(self.alloc, '\n', 500);
        defer self.alloc.free(numSpecialTokensStr);
        const numSpecialTokens = try std.fmt.parseInt(usize, numSpecialTokensStr, 10);
        var i: usize = 0;
        while (i < numSpecialTokens) : (i += 1) {
            const specialTokenLine = try reader.readUntilDelimiterAlloc(self.alloc, '\n', 500);
            defer self.alloc.free(specialTokenLine);
            var specialToken = std.mem.splitScalar(u8, specialTokenLine, ' ');
            try self.special_tokens.put(specialToken.first(), try std.fmt.parseInt(u32, specialToken.next().?, 0));
        }
        var idx: u32 = 256;
        while (try reader.readUntilDelimiterOrEofAlloc(self.alloc, '\n', 500)) |line| {
            var pair = std.mem.splitScalar(u8, line, ' ');
            try self.merges.put(Pair{ .p0 = try std.fmt.parseInt(u32, pair.next().?, 0), .p1 = try std.fmt.parseInt(u32, pair.next().?, 0) }, idx);
            idx += 1;
            self.alloc.free(line);
        }
        try self.buildVocab();
    }

    pub fn printVocab(self: *Self) void {
        var iterator = self.vocab.iterator();
        while (iterator.next()) |iter| {
            const key = iter.key_ptr.*;
            const value = iter.value_ptr.*;
            std.debug.print("({d}) -> {s}\n", .{ key, value });
        }
    }
};

test "gpt2 regex test for jstring" {
    const allocator = std.testing.allocator;
    const pattern = "(*UTF)'(?:[sdmt]|ll|ve|re)| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+/g";
    const slice = "abcdeparallel ४७१";
    var utf8String = try jstring.JString.newFromSlice(allocator, slice);
    defer utf8String.deinit();
    var regex = try utf8String.matchAll(pattern, 0, 0, 0);
    defer regex.deinit();
    if (regex.getResults()) |results| {
        try std.testing.expectEqual(2, results.len);
        for (results) |result| {
            var match = try utf8String.slice(@as(isize, @intCast(result.start)), @as(isize, @intCast(result.start + result.len)));
            defer match.deinit();
            std.debug.print("{s}\n", .{match});
        }
    }
    try std.testing.expect(regex.matchSucceed() == true);
}

test "basic tokenizer test" {
    const allocator = std.testing.allocator;
    var managedString = try jstring.JStringUnmanaged.newFromSlice(allocator, "hello,hello,world");
    defer managedString.deinit(allocator);
    const results = try managedString.split(allocator, ",", -1);

    for (results) |r| {
        std.debug.print("result is {s}\n", .{r});
    }
    std.debug.print("number of splits we have is {}\n", .{results.len});
    const fd = try std.os.open("taylorswift.txt", .{ .ACCMODE = .RDONLY }, 0);
    defer std.os.close(fd);
    const stat = try std.os.fstat(fd);
    const mapping = try std.os.mmap(null, @as(u64, @intCast(stat.size)), std.os.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0);
    defer std.os.munmap(mapping);

    var tokenizer = try BasicTokenizer.init(allocator);
    defer tokenizer.deinit();
    const textAsUtf8 = try unicode.Utf8View.init(mapping);
    try tokenizer.train(textAsUtf8, @as(usize, 512));
    //std.debug.print("\n\n Merge \n\n", .{});
    //tokenizer.printMerge();
    // std.debug.print("\n\n Vocab \n\n", .{});
    for (results) |r| {
        r.deinit(std.testing.allocator);
    }
}
