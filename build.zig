const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("chelar", "src/chelar.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/chelar.zig");
    main_tests.setBuildMode(mode);
    var enum_tests = b.addTest("src/enum_parser.zig");
    var fmt_structs_tests = b.addTest("src/fmt_structs.zig");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&enum_tests.step);
    test_step.dependOn(&fmt_structs_tests.step);
}
