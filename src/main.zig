const std = @import("std");
const deps = @import("deps");
const jstring = @import("jstring");
const os = std.os;
const unicode = std.unicode;
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var managedString = try jstring.JStringUnmanaged.newFromSlice(allocator, "hello,hello,world");
    const results = try managedString.split(allocator, ",", -1);
    for (results) |r| {
        std.debug.print("result is {s}\n", .{r});
    }
    std.debug.print("number of splits we have is {}\n", .{results.len});
    const fd = try os.open("taylorswift.txt", .{ .ACCMODE = .RDONLY }, 0);
    defer os.close(fd);
    const stat = try os.fstat(fd);
    const mapping = try std.os.mmap(null, @as(u64, @intCast(stat.size)), std.os.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0);
    defer std.os.munmap(mapping);

    var tokenizer = try deps.Tokenizer.init(allocator);
    const textAsUtf8 = try unicode.Utf8View.init(mapping);
    try tokenizer.train(textAsUtf8, @as(usize, 512));
    std.debug.print("\n\n Merge \n\n", .{});
    tokenizer.printMerge();
    std.debug.print("\n\n Vocab \n\n", .{});
    // tokenizer.printVocab();
}

test "gpt4 regex test" {
    const allocator = std.testing.allocator;
    var gpt4Pattern = try jstring.RegexUnmanaged.init(allocator, "'(?:[sdmt]|ll|ve|re)|[^\r\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\r\n]*|\\s*[\r\n]|\\s+(?!\\S)|\\s+", 0);
    var gpt2Pattern = try jstring.RegexUnmanaged.init(allocator, "'(?:[sdmt]|ll|ve|re)| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+", 0);
    defer gpt2Pattern.deinit(allocator);
    defer gpt4Pattern.deinit(allocator);
    try gpt4Pattern.matchAll(allocator, "abcdeparallel ४७१", 0, 0);
    try std.testing.expect(gpt4Pattern.matchSucceed());
    const matched_results = gpt4Pattern.getResults();
    try std.testing.expect(matched_results != null);

    var gpt2_matched_results = gpt2Pattern.getResultsIterator("abcdeparallel ४७१");
    while (gpt2_matched_results.nextResult()) |result| {
        std.debug.print("{} {} : {s} \n", .{ result.start, result.len, result.value });
    }
}
