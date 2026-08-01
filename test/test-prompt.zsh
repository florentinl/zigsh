#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
project_root=${0:A:h:h}
module_dir=${ZIGSH_TEST_MODULE_DIR:-$project_root/zig-out/lib}
expected_branch=$(git -C "$project_root" branch --show-current)
trap 'zpty -d prompt_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

function wait-for-output {
  local chunk
  local -i idle_polls=0
  local -i received_output=0
  REPLY=
  repeat 400; do
    if zpty -rt prompt_shell chunk; then
      REPLY+=$chunk
      idle_polls=0
      received_output=1
    elif (( received_output && ++idle_polls == 20 )); then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

function set-terminal-columns {
  local tty_path=$1
  local columns=$2
  stty -f "$tty_path" columns "$columns" 2>/dev/null ||
    stty -F "$tty_path" columns "$columns"
}

zpty -b prompt_shell env \
  HOME="$test_home" \
  TERM=xterm-256color \
  ZDOTDIR="$project_root/run" \
  ZIGSH_MODULE_DIR="$module_dir" \
  zsh -di

wait-for-output
startup_output=$REPLY

zpty -w prompt_shell "cd -- ${(q)test_home}; print ZIGSH_CD_OUTSIDE"
wait-for-output
cd_output=$REPLY
after_cd_marker=${cd_output##*ZIGSH_CD_OUTSIDE}
cd_prompt_count=${#${(S)after_cd_marker//[^╭]/}}

zpty -w prompt_shell "cd -- ${(q)project_root}; print ZIGSH_CD_RETURNED"
wait-for-output

zpty -w prompt_shell "tty >| ${(q)test_home}/tty"
wait-for-output
prompt_tty=$(<$test_home/tty)

set-terminal-columns "$prompt_tty" 16
wait-for-output
resize_output=$REPLY

set-terminal-columns "$prompt_tty" 80
wait-for-output

zpty -wn prompt_shell $'false\n'
wait-for-output
failure_output=$REPLY

zpty -wn prompt_shell $'\e[200~echo one\necho two\e[201~'
wait-for-output
paste_output=$REPLY

zpty -wn prompt_shell $'\x7f'
wait-for-output
backspace_output=$REPLY

[[ "$startup_output" == *' '* ]]
[[ "$startup_output" == *'╭─'* ]]
[[ "$startup_output" == *"  ${project_root:t} "* ]]
[[ "$startup_output" == *"$expected_branch "* ]]
[[ "$startup_output" == *$'\e[48;2;28;28;28m'* ]]
[[ "$startup_output" == *$'\e[0m'* ]]
[[ "$startup_output" == *'❯'* ]]
[[ "$startup_output" == *' '* ]]
(( cd_prompt_count == 1 ))
[[ "$resize_output" == *'  zi…'* ]]
[[ "$failure_output" == *'✗ 1'* ]]
[[ "$failure_output" == *$'\e[1;38;2;255;102;102m❯\e[0m '* ]]
[[ "$paste_output$backspace_output" != *'welcome to zig'* ]]
