#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
dump_file="$test_home/regions"
trap 'zpty -d semantic_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

mkdir -p -- "$test_home/bin" "$test_home/functions" "$test_home/auto-dir" "$test_home/cd-root/cd-dir"
print -r -- '#!/bin/sh' >| "$test_home/bin/external-command"
chmod +x -- "$test_home/bin/external-command"
print -r -- '#!/bin/sh' >| "$test_home/non-executable"
touch -- "$test_home/existing-file"
touch -- "$test_home/-output"
ln -s -- "$test_home/existing-file" "$test_home/existing-link"
print -r -- 'available-function() { :; }' >| "$test_home/functions/available-function"

zpty semantic_shell env \
  HOME="$test_home" \
  ZDOTDIR="$test_home" \
  ZIGSH_HIGHLIGHT_DUMP="$dump_file" \
  ZIGSH_TEST_HOME="$test_home" \
  zsh -dfi

setup_commands=(
  "module_path=(${0:A:h:h}/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh"
  'cd -- $ZIGSH_TEST_HOME'
  'path=($ZIGSH_TEST_HOME/bin $path); fpath=($ZIGSH_TEST_HOME/functions $fpath); cdpath=($ZIGSH_TEST_HOME/cd-root)'
  'typeset PROJECT_ROOT=$ZIGSH_TEST_HOME; setopt AUTO_CD BANG_HIST'
  "alias ll=print first='print ' second=print separator='print ok;' redirector='print hi >' assignment='NAME=value' recurse=separator time=':' nocorrect=':' '\$foo'='print alias'"
  "alias cycle-a=cycle-b cycle-b=cycle-a; alias -g G='| cat' PIPE='|'; alias -s txt=cat"
  'alias dead-alias=print; disable -a dead-alias'
  'function helper { : }; autoload available-function missing-function'
  'function dead-function { : }; disable -f dead-function'
  'hash hashed-command=$ZIGSH_TEST_HOME/bin/external-command; hash -d work=$ZIGSH_TEST_HOME'
  'disable setopt; disable -r repeat'
  'function zigsh-dump-semantic-highlights { print -rl -- $region_highlight >| $ZIGSH_HIGHLIGHT_DUMP; (( dump_count += 1 )); BUFFER="print ZIGSH_SEMANTIC_DUMPED_$dump_count"; zle accept-line; }'
  "typeset -gi dump_count=0; zle -N zigsh-dump-semantic-highlights; bindkey '^G' zigsh-dump-semantic-highlights"
  'print ZIGSH_SEMANTIC_READY'
)
typeset -gi setup_index=0
for command in $setup_commands; do
  (( setup_index += 1 ))
  zpty -w semantic_shell "$command; print ZIGSH_SETUP_$setup_index"
  zpty -r -m semantic_shell output "*ZIGSH_SETUP_$setup_index*"
done

function dump_buffer {
  local buffer=$1
  (( expected_dump += 1 ))
  zpty -wn semantic_shell "${buffer}"$'\C-G'
  if ! zpty -r -m semantic_shell output "*ZIGSH_SEMANTIC_DUMPED_${expected_dump}*"; then
    print -u2 -r -- "$output"
    return 1
  fi
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

dump_buffer 'separator missing-command'
require_region 0 9 'fg=green'
require_region 10 25 'fg=red,bold'

dump_buffer 'redirector -output'
require_region 0 10 'fg=green'
require_region 11 18 'underline'

dump_buffer 'assignment missing-command'
require_region 0 10 'fg=green'
require_region 11 26 'fg=red,bold'

dump_buffer 'recurse missing-command'
require_region 0 7 'fg=green'
require_region 8 23 'fg=red,bold'

dump_buffer 'cycle-a'
require_region 0 7 'fg=green'

dump_buffer 'print PIPE missing-command'
require_region 6 10 'fg=cyan'
require_region 11 26 'fg=red,bold'

dump_buffer 'G'
require_region 0 1 'fg=cyan'

dump_buffer 'print G hello'
require_region 6 7 'fg=cyan'

dump_buffer 'snapshot.txt'
require_region 0 12 'fg=green,underline'

dump_buffer 'helper'
require_region 0 6 'fg=green'

dump_buffer 'available-function'
require_region 0 18 'fg=green'

dump_buffer 'missing-function'
require_region 0 16 'fg=red,bold'

dump_buffer 'if true; then print ok; fi'
require_region 0 2 'fg=yellow'

dump_buffer 'time external-command'
require_region 0 4 'fg=green'

dump_buffer 'nocorrect external-command'
require_region 0 9 'fg=green'

dump_buffer '$foo'
require_region 0 4 'fg=green'

dump_buffer 'unset'
require_region 0 5 'fg=green'

dump_buffer 'repeat'
require_region 0 6 'fg=red,bold'

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

dump_buffer 'print $PROJECT_ROOT/existing-file'
require_region 6 19 'fg=cyan'
require_region 19 33 'underline'

dump_buffer 'print =external-command'
require_region 6 23 'underline'

dump_buffer '=external-command'
require_region 0 17 'fg=green'

dump_buffer 'print =missing'
require_region 6 14 'fg=red,bold'

dump_buffer 'print exist'
require_region 6 11 'underline'

dump_buffer './bin/external'
require_region 0 14 'underline'

dump_buffer 'print *.zig'
require_region 6 7 'fg=blue'

dump_buffer 'print !42'
require_region 6 9 'fg=blue'

dump_buffer 'print hi > existing-file'
require_region 9 10 'fg=yellow'
require_region 11 24 'underline'

zpty -w semantic_shell 'unsetopt EQUALS; print ZIGSH_EQUALS_DISABLED'
zpty -r -m semantic_shell output '*ZIGSH_EQUALS_DISABLED*'
dump_buffer 'print =external-command'
reject_region 6 23

zpty -w semantic_shell 'unsetopt ALIASES; print ZIGSH_ALIASES_DISABLED'
zpty -r -m semantic_shell output '*ZIGSH_ALIASES_DISABLED*'
dump_buffer 'll'
require_region 0 2 'fg=red,bold'
