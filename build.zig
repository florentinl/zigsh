const std = @import("std");

const ZshConfiguration = struct {
    include_path: []const u8,
    ncurses_include_path: ?[]const u8,
    prepare: ?*std.Build.Step.Run,
};

const TreeSitterConfiguration = struct {
    module: *std.Build.Module,
    include_path: std.Build.LazyPath,
    parser_source: std.Build.LazyPath,
    scanner_source: std.Build.LazyPath,
    upstream_scanner_source: std.Build.LazyPath,
    query_source: std.Build.LazyPath,
    prepare: *std.Build.Step.Run,
};

const HighlightTools = struct {
    parser: *std.Build.Step.Compile,
    upstream_parser: *std.Build.Step.Compile,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zsh = configureZsh(b);
    const tree_sitter = configureTreeSitter(b, target, optimize);

    const zigsh_module = b.createModule(.{
        .root_source_file = b.path("src/zigsh.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureZshModule(zigsh_module, zsh);
    configureParserModule(zigsh_module, tree_sitter, tree_sitter.scanner_source);

    const zigsh = addZigshLibrary(b, zigsh_module);
    dependOnZshPreparation(&zigsh.step, zsh);
    zigsh.step.dependOn(&tree_sitter.prepare.step);

    const install = registerInstall(b, zigsh);
    const highlight_tools = registerHighlightTools(b, target, optimize, tree_sitter);

    registerCheck(b, zigsh_module, zsh, tree_sitter);
    registerTests(b, &install.step, target, optimize, zsh, tree_sitter, highlight_tools);
    registerDifferentialTest(b, &install.step);
    registerUpstreamCorpusTest(b, &install.step);
    registerRun(b, &install.step);
}

fn configureTreeSitter(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) TreeSitterConfiguration {
    const dependency = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const prepare = b.addSystemCommand(&.{
        "sh",
        "scripts/prepare-tree-sitter-zsh.sh",
        "vendor/tree-sitter-zsh",
        "patches/tree-sitter-zsh",
    });

    return .{
        .module = dependency.module("tree_sitter"),
        .include_path = b.path("vendor/tree-sitter-zsh/src"),
        .parser_source = b.path("vendor/tree-sitter-zsh/src/parser.c"),
        .scanner_source = b.path("vendor/tree-sitter-zsh/src/scanner.c"),
        .upstream_scanner_source = b.path("vendor/tree-sitter-zsh/src/scanner.upstream.c"),
        .query_source = b.path("queries/zsh/highlights.scm"),
        .prepare = prepare,
    };
}

fn configureParserModule(
    module: *std.Build.Module,
    tree_sitter: TreeSitterConfiguration,
    scanner_source: std.Build.LazyPath,
) void {
    module.addImport("tree-sitter", tree_sitter.module);
    module.addIncludePath(tree_sitter.include_path);
    module.addCSourceFile(.{
        .file = tree_sitter.parser_source,
        .flags = &.{"-std=c11"},
    });
    module.addCSourceFile(.{
        .file = scanner_source,
        .flags = &.{"-std=c11"},
    });
    module.addAnonymousImport("zsh-highlights.scm", .{
        .root_source_file = tree_sitter.query_source,
    });
}

fn configureZsh(b: *std.Build) ZshConfiguration {
    const ncurses_include_path = b.option(
        []const u8,
        "ncurses-include",
        "Add an ncurses include directory for configured Zsh headers",
    );
    const configured_include = b.option(
        []const u8,
        "zsh-include",
        "Use an existing configured Zsh Src directory instead of vendor/zsh/Src",
    );
    if (configured_include) |include_path| {
        return .{
            .include_path = include_path,
            .ncurses_include_path = ncurses_include_path,
            .prepare = null,
        };
    }

    const prepare = b.addSystemCommand(&.{
        "sh",
        "scripts/prepare-zsh.sh",
        "vendor/zsh",
    });
    return .{
        .include_path = "vendor/zsh/Src",
        .ncurses_include_path = ncurses_include_path,
        .prepare = prepare,
    };
}

fn configureZshModule(module: *std.Build.Module, zsh: ZshConfiguration) void {
    module.addIncludePath(.{ .cwd_relative = zsh.include_path });
    if (zsh.ncurses_include_path) |include_path| {
        module.addSystemIncludePath(.{ .cwd_relative = include_path });
    }
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
    if (zigsh.rootModuleTarget().os.tag.isDarwin()) {
        zigsh.headerpad_max_install_names = true;
    }
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
    tree_sitter: TreeSitterConfiguration,
) void {
    // ZLS detects this step and uses it to report compiler diagnostics from
    // the complete import graph without producing or installing an artifact.
    const zigsh_check = addZigshLibrary(b, zigsh_module);
    dependOnZshPreparation(&zigsh_check.step, zsh);
    zigsh_check.step.dependOn(&tree_sitter.prepare.step);

    const check_step = b.step("check", "Check zigsh without emitting a library");
    check_step.dependOn(&zigsh_check.step);
}

fn registerHighlightTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tree_sitter: TreeSitterConfiguration,
) HighlightTools {
    const parser = addHighlightParser(
        b,
        "zigsh-highlight-parser",
        target,
        optimize,
        tree_sitter,
        tree_sitter.scanner_source,
    );
    const upstream_parser = addHighlightParser(
        b,
        "zigsh-highlight-parser-upstream",
        target,
        optimize,
        tree_sitter,
        tree_sitter.upstream_scanner_source,
    );

    const parse = b.addRunArtifact(parser);
    parse.addArg("parse");
    if (b.args) |args| parse.addArgs(args);
    const parse_step = b.step("highlight-parse", "Parse and highlight a Zsh source string");
    parse_step.dependOn(&parse.step);

    const tree = b.addRunArtifact(parser);
    tree.addArg("tree");
    if (b.args) |args| tree.addArgs(args);
    const tree_step = b.step("highlight-tree", "Print the Zsh syntax tree and highlights");
    tree_step.dependOn(&tree.step);

    const edits = b.addRunArtifact(parser);
    edits.addArg("edits");
    if (b.args) |args| edits.addArgs(args);
    const edits_step = b.step("highlight-edits", "Apply an incremental Zsh edit sequence");
    edits_step.dependOn(&edits.step);

    const benchmark = b.addRunArtifact(parser);
    benchmark.addArg("benchmark");
    if (b.args) |args| benchmark.addArgs(args);
    const benchmark_step = b.step("highlight-benchmark", "Benchmark incremental Zsh highlighting");
    benchmark_step.dependOn(&benchmark.step);

    const benchmark_suite = b.addRunArtifact(parser);
    benchmark_suite.addArg("benchmark-suite");
    if (b.args) |args| benchmark_suite.addArgs(args);
    const benchmark_suite_step = b.step(
        "highlight-benchmark-suite",
        "Benchmark the Zsh highlighting corpus and stress buffers",
    );
    benchmark_suite_step.dependOn(&benchmark_suite.step);

    const upstream_parse = b.addRunArtifact(upstream_parser);
    upstream_parse.addArg("parse");
    if (b.args) |args| upstream_parse.addArgs(args);
    const upstream_step = b.step("highlight-parse-upstream", "Parse with unmodified tree-sitter-zsh");
    upstream_step.dependOn(&upstream_parse.step);

    return .{ .parser = parser, .upstream_parser = upstream_parser };
}

fn addHighlightParser(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tree_sitter: TreeSitterConfiguration,
    scanner_source: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/highlight_cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureParserModule(module, tree_sitter, scanner_source);

    const parser = b.addExecutable(.{ .name = name, .root_module = module });
    parser.step.dependOn(&tree_sitter.prepare.step);
    return parser;
}

fn registerTests(
    b: *std.Build,
    install_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zsh: ZshConfiguration,
    tree_sitter: TreeSitterConfiguration,
    highlight_tools: HighlightTools,
) void {
    const test_step = b.step("test", "Load zigsh and exercise its native features");
    registerUnitTest(b, test_step, target, optimize, "src/prompt/git.zig");
    registerUnitTest(b, test_step, target, optimize, "src/prompt/template.zig");
    registerZshUnitTest(b, test_step, target, optimize, zsh, "src/prompt/metrics.zig");
    registerZshUnitTest(b, test_step, target, optimize, zsh, "src/zle_hooks.zig");
    registerZshUnitTest(b, test_step, target, optimize, zsh, "src/zle_events.zig");
    registerAsyncUnitTests(b, test_step, target, optimize, zsh, tree_sitter);
    registerTest(b, test_step, install_step, "test/test.zsh");
    registerTest(b, test_step, install_step, "test/test-history.zsh");
    registerTest(b, test_step, install_step, "test/test-prompt.zsh");
    registerTest(b, test_step, install_step, "test/test-async-prompt.zsh");
    registerTest(b, test_step, install_step, "test/test-highlighting.zsh");
    registerTest(b, test_step, install_step, "test/test-highlighting-semantics.zsh");
    registerTest(b, test_step, install_step, "test/test-highlighting-disabled.zsh");

    const safety_test = b.addSystemCommand(&.{ "zsh", "-f", "test/test-highlight-safety.zsh" });
    safety_test.addArtifactArg(highlight_tools.parser);
    safety_test.addArtifactArg(highlight_tools.upstream_parser);
    test_step.dependOn(&safety_test.step);

    const unit_module = b.createModule(.{
        .root_source_file = b.path("src/highlight/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureParserModule(unit_module, tree_sitter, tree_sitter.scanner_source);
    const unit_tests = b.addTest(.{ .root_module = unit_module });
    unit_tests.step.dependOn(&tree_sitter.prepare.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}

fn registerAsyncUnitTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zsh: ZshConfiguration,
    tree_sitter: TreeSitterConfiguration,
) void {
    const unit_module = b.createModule(.{
        .root_source_file = b.path("src/async_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureZshModule(unit_module, zsh);
    configureParserModule(unit_module, tree_sitter, tree_sitter.scanner_source);
    const unit_tests = b.addTest(.{ .root_module = unit_module });
    dependOnZshPreparation(&unit_tests.step, zsh);
    unit_tests.step.dependOn(&tree_sitter.prepare.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
    b.step("async-test", "Run async worker and protocol unit tests").dependOn(&run_unit_tests.step);
}

fn registerZshUnitTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zsh: ZshConfiguration,
    path: []const u8,
) void {
    const unit_test_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureZshModule(unit_test_module, zsh);
    const unit_tests = b.addTest(.{ .root_module = unit_test_module });
    dependOnZshPreparation(&unit_tests.step, zsh);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
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
        .link_libc = true,
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

fn registerDifferentialTest(b: *std.Build, install_step: *std.Build.Step) void {
    const run = b.addSystemCommand(&.{ "zsh", "-f", "test/compare-highlighting.zsh" });
    if (b.args) |args| run.addArgs(args);
    run.step.dependOn(install_step);

    const step = b.step(
        "highlight-differential",
        "Compare semantic regions with a zsh-syntax-highlighting checkout",
    );
    step.dependOn(&run.step);
}

fn registerUpstreamCorpusTest(b: *std.Build, install_step: *std.Build.Step) void {
    const run = b.addSystemCommand(&.{ "zsh", "-f", "test/compare-upstream-main-corpus.zsh" });
    if (b.args) |args| run.addArgs(args);
    run.step.dependOn(install_step);

    const step = b.step(
        "highlight-upstream-corpus",
        "Classify native highlights against zsh-syntax-highlighting main test-data",
    );
    step.dependOn(&run.step);
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
