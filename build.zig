const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const configured_zsh_include = b.option(
        []const u8,
        "zsh-include",
        "Use an existing configured Zsh Src directory instead of vendor/zsh/Src",
    );
    const zsh_include = configured_zsh_include orelse "vendor/zsh/Src";

    const zigsh_module = b.createModule(.{
        .root_source_file = b.path("src/zigsh.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureZshModule(zigsh_module, zsh_include);

    const zigsh = b.addLibrary(.{
        .name = "zigsh",
        .linkage = .dynamic,
        .root_module = zigsh_module,
    });
    // Zsh resolves its module API from the running shell process.
    zigsh.linker_allow_shlib_undefined = true;

    var prepare_zsh: ?*std.Build.Step.Run = null;
    if (configured_zsh_include == null) {
        prepare_zsh = b.addSystemCommand(&.{
            "sh",
            "scripts/prepare-zsh.sh",
            "vendor/zsh",
        });
        zigsh.step.dependOn(&prepare_zsh.?.step);
    }

    const install = b.addInstallArtifact(zigsh, .{
        .dest_dir = .{ .override = .lib },
        .dest_sub_path = "zigsh.so",
    });
    b.getInstallStep().dependOn(&install.step);

    // ZLS detects this step and uses it to report compiler diagnostics from
    // the complete import graph without producing or installing an artifact.
    const zigsh_check = b.addLibrary(.{
        .name = "zigsh",
        .linkage = .dynamic,
        .root_module = zigsh_module,
    });
    zigsh_check.linker_allow_shlib_undefined = true;
    if (prepare_zsh) |prepare| {
        zigsh_check.step.dependOn(&prepare.step);
    }

    const check_step = b.step("check", "Check zigsh without emitting a library");
    check_step.dependOn(&zigsh_check.step);

    const test_step = b.step("test", "Load the zigsh module in zsh and run its builtin");
    const test_run = b.addSystemCommand(&.{ "zsh", "-f", "test.zsh" });
    test_run.step.dependOn(&install.step);
    test_step.dependOn(&test_run.step);

    const run_step = b.step("run", "Build zigsh and start an interactive Zsh");
    const run = b.addSystemCommand(&.{ "zsh", "-d", "-i" });
    run.stdio = .inherit;
    run.setEnvironmentVariable("ZDOTDIR", b.pathFromRoot("run"));
    run.setEnvironmentVariable("ZIGSH_MODULE_DIR", b.getInstallPath(.lib, ""));
    run.step.dependOn(&install.step);
    run_step.dependOn(&run.step);
}

fn configureZshModule(module: *std.Build.Module, zsh_include: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = zsh_include });
    // zsh.mdh normally renames these symbols for its own modules. An external
    // module must retain the loader's conventional names: boot_, setup_, etc.
    module.addCMacro("IMPORTING_MODULE_zshQsmain", "1");
}
