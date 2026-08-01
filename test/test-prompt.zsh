#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
project_root=${0:A:h:h}
module_dir=${ZIGSH_TEST_MODULE_DIR:-$project_root/zig-out/lib}
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
    elif (( received_output && ++idle_polls == 5 )); then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

zpty -b prompt_shell env \
  HOME="$test_home" \
  TERM=xterm-256color \
  ZDOTDIR="$project_root/run" \
  ZIGSH_MODULE_DIR="$module_dir" \
  zsh -di

wait-for-output
startup_output=$REPLY

zpty -wn prompt_shell $'\e[200~false\n\e[201~'
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
[[ "$startup_output" == *'main '* ]]
[[ "$startup_output" == *$'\e[48;2;28;28;28m'* ]]
[[ "$startup_output" == *$'\e[0m'* ]]
[[ "$startup_output" == *'❯ '* ]]
[[ "$startup_output" == *' '* ]]
[[ "$failure_output" == *'✗ 1'* ]]
[[ "$paste_output$backspace_output" != *'welcome to zig'* ]]
