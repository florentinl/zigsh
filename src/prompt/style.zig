pub const Name = enum {
    line,
    panel,
    separator,
    cap_left,
    cap_right,
    os,
    directory,
    git,
    git_state,
    git_status,
    success,
    @"error",
    sudo,
    character,
};

pub const Rgb = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const Style = struct {
    foreground: ?Rgb = null,
    background: ?Rgb = null,
    bold: bool = false,
};
