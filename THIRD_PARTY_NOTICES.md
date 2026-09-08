# Third-party notices

Zigsh builds with the following dependencies; they are fetched at the pinned
revisions declared in `build.zig.zon` and the preparation scripts.

| Component | License | Use |
| --- | --- | --- |
| [zig-tree-sitter](https://github.com/tree-sitter/zig-tree-sitter) | MIT | Zig bindings for Tree-sitter |
| [tree-sitter-zsh](https://github.com/georgeharker/tree-sitter-zsh) | MIT | Zsh parser and external scanner; Zigsh applies the patch series in `patches/tree-sitter-zsh` |
| [Zsh 5.9](https://www.zsh.org/) | Zsh license | Generated module headers used only while building |
| [Zig](https://ziglang.org/) | MIT | Build toolchain |

The distributed Zigsh module does not contain the Zsh shell or its shell
functions. See each upstream project for its full license text.
