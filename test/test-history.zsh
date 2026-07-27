#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty
zmodload zsh/termcap

test_home=$(mktemp -d)
trap 'zpty -d history_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

cursor_up=$(echotc ku 2>/dev/null) || cursor_up=$'\e[A'
cursor_down=$(echotc kd 2>/dev/null) || cursor_down=$'\e[B'

zpty -b history_shell env \
  HOME="$test_home" \
  ZDOTDIR="$test_home" \
  zsh -dfi

zpty -w history_shell \
  "module_path=(${0:A:h:h}/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh; print ZIGSH_READY"
zpty -r -m history_shell output '*ZIGSH_READY*'

zpty -w history_shell 'history_probe=alpha'
zpty -r -m history_shell output '*welcome to zig*'
zpty -w history_shell 'history_probe=beta'
zpty -r -m history_shell output '*welcome to zig*'

zpty -wn history_shell \
  $'history_probe='"$cursor_up$cursor_up$cursor_down"$'\n'
zpty -r -m history_shell output '*welcome to zig*'
zpty -w history_shell 'print ZIGSH_RESULT:$history_probe'
zpty -r -m history_shell output '*ZIGSH_RESULT:beta*'
