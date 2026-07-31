const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

fn initPrompt(new_prompt: [:0]const u8) void {
    zsh.zsfree(zsh.prompt);
    zsh.prompt = zsh.ztrdup_metafy(new_prompt);
}

pub fn setup() c_int {
    zsh.opts[zsh.PROMPTSUBST] = 0;
    zsh.rprompt_indent = 0;
    initPrompt("welcome to zig -> ");
    return 0;
}
