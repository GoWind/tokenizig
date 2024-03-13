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
