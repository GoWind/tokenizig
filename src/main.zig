const std = @import("std");
const deps = @import("deps");
const os = std.os;
const unicode = std.unicode;
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
    tokenizer.printVocab();
}
