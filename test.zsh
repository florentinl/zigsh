#!/usr/bin/env zsh -f
set -eu

module_path=("${0:A:h}/zig-out/lib" $module_path)
zmodload -d zigsh zsh/zle
zmodload zigsh
[[ $PROMPT == "welcome to zig -> " ]]
zigsh
zmodload -u zigsh
