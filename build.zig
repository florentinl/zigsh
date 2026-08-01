const std = @import("std");

const ZshConfiguration = struct {
    include_path: []const u8,
    prepare: ?*std.Build.Step.Run,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zsh = configureZsh(b);

    const zigsh_module = b.createModule(.{
        .root_source_file = b.path("src/zigsh.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureZshModule(zigsh_module, zsh.include_path);

    const zigsh = addZigshLibrary(b, zigsh_module);
    dependOnZshPreparation(&zigsh.step, zsh);

    const install = registerInstall(b, zigsh);

    registerCheck(b, zigsh_module, zsh);
    registerTests(b, target, optimize, &install.step);
    registerRun(b, &install.step);
}

fn configureZsh(b: *std.Build) ZshConfiguration {
    const configured_include = b.option(
        []const u8,
        "zsh-include",
        "Use an existing configured Zsh Src directory instead of vendor/zsh/Src",
    );
    if (configured_include) |include_path| {
        return .{ .include_path = include_path, .prepare = null };
    }

    const prepare = b.addSystemCommand(&.{
        "sh",
        "scripts/prepare-zsh.sh",
        "vendor/zsh",
    });
    return .{ .include_path = "vendor/zsh/Src", .prepare = prepare };
}

fn configureZshModule(module: *std.Build.Module, zsh_include: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = zsh_include });
    // zsh.mdh normally renames these symbols for its own modules. An external
    // module must retain the loader's conventional names: boot_, setup_, etc.
    module.addCMacro("IMPORTING_MODULE_zshQsmain", "1");
}

fn addZigshLibrary(
    b: *std.Build,
    zigsh_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const zigsh = b.addLibrary(.{
        .name = "zigsh",
        .linkage = .dynamic,
        .root_module = zigsh_module,
    });
    // Zsh resolves its module API from the running shell process.
    zigsh.linker_allow_shlib_undefined = true;
    return zigsh;
}

fn dependOnZshPreparation(step: *std.Build.Step, zsh: ZshConfiguration) void {
    if (zsh.prepare) |prepare| {
        step.dependOn(&prepare.step);
    }
}

fn registerInstall(
    b: *std.Build,
    zigsh: *std.Build.Step.Compile,
) *std.Build.Step.InstallArtifact {
    const install = b.addInstallArtifact(zigsh, .{
        .dest_dir = .{ .override = .lib },
        .dest_sub_path = "zigsh.so",
    });
    b.getInstallStep().dependOn(&install.step);
    return install;
}

fn registerCheck(
    b: *std.Build,
    zigsh_module: *std.Build.Module,
    zsh: ZshConfiguration,
) void {
    // ZLS detects this step and uses it to report compiler diagnostics from
    // the complete import graph without producing or installing an artifact.
    const zigsh_check = addZigshLibrary(b, zigsh_module);
    dependOnZshPreparation(&zigsh_check.step, zsh);

    const check_step = b.step("check", "Check zigsh without emitting a library");
    check_step.dependOn(&zigsh_check.step);
}

fn registerTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_step: *std.Build.Step,
) void {
    const test_step = b.step("test", "Load zigsh and exercise its native features");
    registerUnitTest(b, test_step, target, optimize, "src/prompt/git.zig");
    registerUnitTest(b, test_step, target, optimize, "src/prompt/template.zig");
    registerTest(b, test_step, install_step, "test/test.zsh");
    registerTest(b, test_step, install_step, "test/test-history.zsh");
    registerTest(b, test_step, install_step, "test/test-prompt.zsh");
}

fn registerUnitTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) void {
    const unit_test_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = unit_test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}

fn registerTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    install_step: *std.Build.Step,
    path: []const u8,
) void {
    const run = b.addSystemCommand(&.{ "zsh", "-f", path });
    run.step.dependOn(install_step);
    test_step.dependOn(&run.step);
}

fn registerRun(b: *std.Build, install_step: *std.Build.Step) void {
    const run_step = b.step("run", "Build zigsh and start an interactive Zsh");
    const run = b.addSystemCommand(&.{ "zsh", "-d", "-i" });
    run.stdio = .inherit;
    run.setEnvironmentVariable("ZDOTDIR", b.pathFromRoot("run"));
    run.setEnvironmentVariable("ZIGSH_MODULE_DIR", b.getInstallPath(.lib, ""));
    run.step.dependOn(install_step);
    run_step.dependOn(&run.step);
}
