const std = @import("std");

pub fn build(b: *std.Build) void {
    // import dependencies
    const jstring_build = @import("jstring");
    const jstrings = b.dependency("jstring", .{});

    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tokenizig",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const tokenizers = b.addModule("tokenizers", .{
        .root_source_file = .{ .path = "src/root.zig" },
    });

    exe.root_module.addImport("tokenizers", tokenizers);
    exe.root_module.addImport("jstring", jstrings.module("jstring"));
    jstring_build.linkPCRE(exe, jstrings);
    b.installArtifact(exe);

    const runArtifact = b.addRunArtifact(exe);

    const runStep = b.step("run", "Run the app");

    runStep.dependOn(&runArtifact.step);

    // Setup tests for the app
    const exe_test = b.addTest(.{ .root_source_file = .{ .path = "src/test.zig" } });
    exe_test.root_module.addImport("jstring", jstrings.module("jstring"));
    jstring_build.linkPCRE(exe_test, jstrings);
    const testStep = b.step("test", "test the app");
    testStep.dependOn(&b.addRunArtifact(exe_test).step);
}
