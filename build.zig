const std = @import("std");

pub fn build(b: *std.Build) void {
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

    const rootModule = b.addModule("root", .{
        .root_source_file = .{ .path = "src/root.zig" },
    });

    exe.root_module.addImport("deps", rootModule);
    exe.root_module.addImport("jstring", jstrings.module("jstring"));
    jstring_build.linkPCRE(exe, jstrings);
    b.installArtifact(exe);

    const runArtifact = b.addRunArtifact(exe);

    const runStep = b.step("run", "Run the app");

    runStep.dependOn(&runArtifact.step);
}
