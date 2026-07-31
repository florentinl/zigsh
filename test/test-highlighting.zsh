#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
dump_file="$test_home/regions"
buffer_file="$test_home/buffer"
trap 'zpty -d highlight_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

zpty -b highlight_shell env \
  HOME="$test_home" \
  ZDOTDIR="$test_home" \
  ZIGSH_HIGHLIGHT_DUMP="$dump_file" \
  ZIGSH_BUFFER_DUMP="$buffer_file" \
  zsh -dfi

zpty -w highlight_shell \
  "module_path=(${0:A:h:h}/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh
function zigsh-dump-highlights {
  print -rl -- \$region_highlight >| \$ZIGSH_HIGHLIGHT_DUMP
  print -rn -- \$BUFFER >| \$ZIGSH_BUFFER_DUMP
  (( dump_count += 1 ))
  BUFFER="print ZIGSH_HIGHLIGHTS_DUMPED_\$dump_count"
  zle accept-line
}
typeset -gi dump_count=0
zle -N zigsh-dump-highlights
bindkey '^G' zigsh-dump-highlights
print ZIGSH_HIGHLIGHT_READY"
zpty -r -m highlight_shell output '*ZIGSH_HIGHLIGHT_READY*'

zpty -wn highlight_shell $'if true; then echo "é🙂 $USER"; fi # note\C-G'
zpty -r -m highlight_shell output '*ZIGSH_HIGHLIGHTS_DUMPED_1*'

regions=("${(@f)$(<"$dump_file")}")
joined_regions="${(F)regions}"
[[ "$joined_regions" == *$'0 2 '* ]]
[[ "$joined_regions" == *$'14 18 '* ]]
[[ "$joined_regions" == *$'19 23 '* ]]
[[ "$joined_regions" == *$'23 28 '* ]]
[[ "$joined_regions" == *$'34 40 '* ]]
[[ "$joined_regions" == *'fg=green'* ]]
[[ "$joined_regions" == *'fg=cyan'* ]]
[[ "$joined_regions" == *'fg=yellow'* ]]

for iteration in {1..20}; do
  zpty -w highlight_shell "zmodload -u zigsh; zmodload zigsh; print ZIGSH_RELOADED_$iteration"
  zpty -r -m highlight_shell output "*ZIGSH_RELOADED_$iteration*"
done

zpty -wn highlight_shell $'for item in one two; do print "$item"; done\C-G'
zpty -r -m highlight_shell output '*ZIGSH_HIGHLIGHTS_DUMPED_2*'

regions=("${(@f)$(<"$dump_file")}")
joined_regions="${(F)regions}"
[[ "$joined_regions" == *$'0 3 '* ]]
[[ "$joined_regions" == *$'21 23 '* ]]
[[ "$joined_regions" == *$'39 43 '* ]]

zpty -wn highlight_shell $'\e[200~echo one\necho two\e[201~'
zpty -wn highlight_shell $'\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\C-G'
zpty -r -m highlight_shell output '*ZIGSH_HIGHLIGHTS_DUMPED_3*'
[[ "$(<"$buffer_file")" == 'echo one' ]]
