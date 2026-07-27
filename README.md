# zigsh

A minimal native [Zsh module](https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html)
implemented in Zig.  Loading it registers one builtin:

```zsh
% zigsh
Hello from Zig!
```

## Zsh headers

Zig's `@cImport` directly imports Zsh's module API from `zsh.mdh`; there is no
bindgen step or generated Zig bindings checked into this repository.  Zsh does
not install that private generated header with the shell binary.  On the first
build, `scripts/prepare-zsh.sh` clones the official Zsh Git repository into
`vendor/zsh`, checks out `zsh-5.9`, runs its configure flow, and generates
`Src/zsh.mdh`. Zsh 5.9 matches the local shell.

`vendor/zsh` is ignored because it is a reproducible build input. To use a
different already-configured source tree, pass its `Src` directory explicitly:

```sh
zig build -Dzsh-include=/path/to/zsh/Src
```

## Build and run

```sh
zig build test
```

The build installs the module at `zig-out/lib/zigsh.so`, which is the filename
Zsh expects on every platform (including macOS). The test temporarily adds that
directory to `module_path`, loads the module, runs `zigsh`, and unloads it.

To build the module and open an interactive Zsh with it already loaded:

```sh
zig build run
```

This uses an isolated startup file from `run/.zshrc`, adds the build's library
directory to `module_path`, and loads `zigsh`. Exit the shell normally to finish
the build command.

## Layout

- `src/zigsh.zig` imports the named `prompt` module and implements Zsh's module
  lifecycle.
- `src/prompt.zig` owns the prompt setup and imports the Zsh APIs it needs.
- `build.zig` prepares Zsh 5.9 from Git and builds a shared library with
  unresolved Zsh symbols left for the running shell to resolve. It registers
  `src/prompt.zig` with `addImport("prompt", ...)`, making it available through
  `@import("prompt")`.
- `scripts/prepare-zsh.sh` mirrors the Rust project's Zsh source/header setup.
- `run/.zshrc` loads the freshly built module for `zig build run`.
- `test.zsh` is an end-to-end Zsh loader test.
