const history = @import("history.zig");
const prompt = @import("prompt.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

fn zigsh(
    _: [*c]u8,
    _: [*c][*c]u8,
    _: zsh.Options,
    _: c_int,
) callconv(.c) c_int {
    _ = zsh.printf("Hello from Zig!\n");
    return 0;
}

var builtins = [_]zsh.struct_builtin{.{
    .node = .{
        .next = null,
        .nam = @constCast("zigsh"),
        .flags = 0,
    },
    .handlerfunc = &zigsh,
    .minargs = 0,
    .maxargs = -1,
    .funcid = 0,
    .optstr = null,
    .defopts = null,
}};

var module_features = zsh.struct_features{
    .bn_list = &builtins,
    .bn_size = builtins.len,
    .cd_list = null,
    .cd_size = 0,
    .mf_list = null,
    .mf_size = 0,
    .pd_list = null,
    .pd_size = 0,
    .n_abstract = 0,
};

pub export fn setup_(_: zsh.Module) callconv(.c) c_int {
    const history_result = history.setup();
    if (history_result != 0) return history_result;
    return prompt.setup();
}

pub export fn features_(module: zsh.Module, out: [*c][*c][*c]u8) callconv(.c) c_int {
    out.* = zsh.featuresarray(module, &module_features);
    return 0;
}

pub export fn enables_(module: zsh.Module, out: [*c][*c]c_int) callconv(.c) c_int {
    return zsh.handlefeatures(module, &module_features, out);
}

pub export fn boot_(_: zsh.Module) callconv(.c) c_int {
    return 0;
}

pub export fn cleanup_(module: zsh.Module) callconv(.c) c_int {
    prompt.cleanup();
    history.cleanup();
    return zsh.setfeatureenables(module, &module_features, null);
}

pub export fn finish_(_: zsh.Module) callconv(.c) c_int {
    return 0;
}
