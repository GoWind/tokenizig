const std = @import("std");
const jstring = @import("jstring");
const tokenizers = @import("./root.zig");

test "gpt2 regex test for jstring" {
    _ = tokenizers;
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
