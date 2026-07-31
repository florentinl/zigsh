#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
dump_file="$test_home/regions"
trap 'zpty -d semantic_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

mkdir -p -- "$test_home/bin" "$test_home/auto-dir" "$test_home/cd-root/cd-dir"
print -r -- '#!/bin/sh' >| "$test_home/bin/external-command"
chmod +x -- "$test_home/bin/external-command"
print -r -- '#!/bin/sh' >| "$test_home/non-executable"
touch -- "$test_home/existing-file"
ln -s -- "$test_home/existing-file" "$test_home/existing-link"

zpty -b semantic_shell env \
  HOME="$test_home" \
  ZDOTDIR="$test_home" \
  ZIGSH_HIGHLIGHT_DUMP="$dump_file" \
  ZIGSH_TEST_HOME="$test_home" \
  zsh -dfi

zpty -w semantic_shell \
  "module_path=(${0:A:h:h}/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh
cd -- \$ZIGSH_TEST_HOME
path=(\$ZIGSH_TEST_HOME/bin \$path)
cdpath=(\$ZIGSH_TEST_HOME/cd-root)
setopt AUTO_CD BANG_HIST
alias ll=print
alias first='print '
alias second=print
alias -g G='| cat'
alias -s txt=cat
alias dead-alias=print
disable -a dead-alias
function helper { : }
function dead-function { : }
disable -f dead-function
hash hashed-command=\$ZIGSH_TEST_HOME/bin/external-command
hash -d work=\$ZIGSH_TEST_HOME
disable setopt
function zigsh-dump-semantic-highlights {
  print -rl -- \$region_highlight >| \$ZIGSH_HIGHLIGHT_DUMP
  (( dump_count += 1 ))
  BUFFER=\"print ZIGSH_SEMANTIC_DUMPED_\$dump_count\"
  zle accept-line
}
typeset -gi dump_count=0
zle -N zigsh-dump-semantic-highlights
bindkey '^G' zigsh-dump-semantic-highlights
print ZIGSH_SEMANTIC_READY"
zpty -r -m semantic_shell output '*ZIGSH_SEMANTIC_READY*'

function dump_buffer {
  local buffer=$1
  (( expected_dump += 1 ))
  zpty -wn semantic_shell "${buffer}"$'\C-G'
  zpty -r -m semantic_shell output "*ZIGSH_SEMANTIC_DUMPED_${expected_dump}*"
  regions=("${(@f)$(<"$dump_file")}")
  joined_regions="${(F)regions}"
}

function require_region {
  local start=$1 end=$2 style=$3
  [[ $'\n'"$joined_regions"$'\n' == *$'\n'"$start $end $style"$'\n'* ]]
}

function reject_region {
  local start=$1 end=$2
  [[ $'\n'"$joined_regions"$'\n' != *$'\n'"$start $end "* ]]
}

typeset -gi expected_dump=0
typeset -a regions
typeset joined_regions

dump_buffer 'll'
require_region 0 2 'fg=green'

dump_buffer 'first second'
require_region 0 5 'fg=green'
require_region 6 12 'fg=green'

dump_buffer 'G'
require_region 0 1 'fg=cyan'

dump_buffer 'snapshot.txt'
require_region 0 12 'fg=green,underline'

dump_buffer 'helper'
require_region 0 6 'fg=green'

dump_buffer 'print'
require_region 0 5 'fg=green'

dump_buffer 'external-command'
require_region 0 16 'fg=green'

dump_buffer 'hashed-command'
require_region 0 14 'fg=green'

dump_buffer 'missing-command'
require_region 0 15 'fg=red,bold'

dump_buffer 'dead-alias'
require_region 0 10 'fg=red,bold'

dump_buffer 'dead-function'
require_region 0 13 'fg=red,bold'

dump_buffer 'setopt'
require_region 0 6 'fg=red,bold'

dump_buffer 'env -u OLD print'
require_region 0 3 'fg=green,underline'
require_region 11 16 'fg=green'

dump_buffer 'env -u OLD command -p print'
require_region 0 3 'fg=green,underline'
require_region 11 18 'fg=green,underline'
require_region 22 27 'fg=green'

dump_buffer 'command -v print'
require_region 0 7 'fg=green,underline'
reject_region 11 16

dump_buffer 'auto-dir'
require_region 0 8 'fg=green,underline'

dump_buffer 'cd-dir'
require_region 0 6 'fg=green,underline'

executable="$test_home/bin/external-command"
dump_buffer "$executable"
require_region 0 ${#executable} 'fg=green'

non_executable="$test_home/non-executable"
dump_buffer "$non_executable"
require_region 0 ${#non_executable} 'fg=red,bold'

dump_buffer 'print existing-file'
require_region 6 19 'underline'

dump_buffer 'print existing-link'
require_region 6 19 'underline'

dump_buffer 'print auto-dir'
require_region 6 14 'underline'

dump_buffer 'print cd-dir'
require_region 6 12 'underline'

dump_buffer 'print ~work/existing-file'
require_region 6 25 'underline'

dump_buffer 'print exist'
require_region 6 11 'underline'

dump_buffer './bin/external'
require_region 0 14 'underline'

dump_buffer 'print *.zig'
require_region 6 11 'fg=blue'

dump_buffer 'print !42'
require_region 6 9 'fg=blue'

dump_buffer 'print hi > existing-file'
require_region 9 10 'fg=yellow'
require_region 11 24 'underline'
