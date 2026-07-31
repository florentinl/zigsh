#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
trap 'zpty -d disabled_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

zpty -b disabled_shell env \
  HOME="$test_home" \
  ZDOTDIR="$test_home" \
  ZIGSH_SYNTAX_HIGHLIGHTING=off \
  zsh -dfi

zpty -w disabled_shell \
  "module_path=(${0:A:h:h}/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh
function zigsh-check-disabled {
  BUFFER=\"print ZIGSH_DISABLED_REGIONS:\${#region_highlight}\"
  zle accept-line
}
zle -N zigsh-check-disabled
bindkey '^G' zigsh-check-disabled
print ZIGSH_DISABLED_READY"
zpty -r -m disabled_shell output '*ZIGSH_DISABLED_READY*'

zpty -wn disabled_shell $'echo "$USER"\C-G'
zpty -r -m disabled_shell output '*ZIGSH_DISABLED_REGIONS:0*'
