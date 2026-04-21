const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "e2e_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // skir_client unit tests (boolSerializer and others)
    const skir_client_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/skir_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_skir_client_tests = b.addRunArtifact(skir_client_tests);

    // ownership composition tests (nested optional/array serializer shapes)
    const ownership_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ownership_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_ownership_tests = b.addRunArtifact(ownership_tests);

    // golden tests
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/goldens_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_golden_tests = b.addRunArtifact(golden_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_skir_client_tests.step);
    test_step.dependOn(&run_ownership_tests.step);
    test_step.dependOn(&run_golden_tests.step);
}
