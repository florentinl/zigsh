const std = @import("std");

pub const Case = struct {
    name: []const u8,
    source: []const u8,
};

pub const cases = [_]Case{
    .{
        .name = "ordinary",
        .source = "if [[ -n $USER ]]; then print -r -- \"hello $USER\"; fi",
    },
    .{
        .name = "nested",
        .source = "result=${${(M)${(f)$(git status --porcelain)}:#?? *}%%/*}:#}; print -r -- ${(q)result}",
    },
    .{
        .name = "multiline",
        .source =
        \\function collect_matches {
        \\  local item
        \\  for item in "$@"; do
        \\    [[ -x $item ]] && print -r -- "$item"
        \\  done
        \\}
        ,
    },
    .{
        .name = "heredoc",
        .source =
        \\while read -r line; do
        \\  print -r -- "${line:u}"
        \\done <<'INPUT'
        \\one
        \\two
        \\INPUT
        ,
    },
    .{
        .name = "incomplete",
        .source = "for item in ${(f)$(find . -type f); do print \"$item",
    },
    .{
        .name = "unicode",
        .source = "name='élan 🙂'; print -r -- \"$name\" # terminé",
    },
};

pub fn stressSource(allocator: std.mem.Allocator, minimum_length: usize) ![]u8 {
    const line = "if [[ -n $value ]]; then print -r -- \"$value\"; fi\n";
    var source = try std.ArrayList(u8).initCapacity(allocator, minimum_length + line.len);
    errdefer source.deinit(allocator);
    while (source.items.len < minimum_length) try source.appendSlice(allocator, line);
    return source.toOwnedSlice(allocator);
}
