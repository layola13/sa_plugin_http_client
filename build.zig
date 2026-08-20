const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sci_root = b.option([]const u8, "sci-root", "Path to the sci checkout") orelse "../sci";
    const sci_net_primitives_path = b.pathJoin(&.{ sci_root, "src", "runtime", "sa_net_primitives.zig" });
    const sa_net_primitives = b.createModule(.{
        .root_source_file = .{ .cwd_relative = sci_net_primitives_path },
        .target = target,
        .optimize = optimize,
    });
    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addImport("sa_net_primitives", sa_net_primitives);
    const lib = b.addLibrary(.{
        .name = "http-client",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_source_file = b.path("tests/plugin_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests.root_module.addImport("plugin", root_module);
    tests.root_module.addImport("plugin_api", plugin_api);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
}
