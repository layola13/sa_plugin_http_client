const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sci_root = b.option([]const u8, "sci-root", "Path to the sci checkout") orelse "../sci";
    const sa_net_primitives = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ sci_root, "src", "runtime", "sa_net_primitives.zig" })),
        .target = target,
        .optimize = optimize,
    });
    const sio_module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ sci_root, "src", "sa_io.zig" })),
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
    root_module.addImport("sio", sio_module);
    const lib = b.addLibrary(.{
        .name = "http-client",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/plugin_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("plugin", root_module);
    test_module.addImport("plugin_api", plugin_api);
    test_module.addImport("sio", sio_module);
    const sa_http_client_module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ sci_root, "src/runtime/sa_http_client.zig" })),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sa_http_client_module.addImport("sio", sio_module);
    test_module.addImport("sa_http_client", sa_http_client_module);
    const tests = b.addTest(.{
        .root_module = test_module,
        .filters = b.option([]const []const u8, "test-filter", "Filter tests by name substring") orelse &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
}
