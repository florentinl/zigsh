#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

test_home=$(mktemp -d)
project_root=${0:A:h:h}
module_dir=${ZIGSH_TEST_MODULE_DIR:-$project_root/zig-out/lib}
expected_branch=$(git -C "$project_root" branch --show-current)
trap 'zpty -d prompt_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

mkdir -p -- "$test_home/.kube" "$test_home/bin"
# Keep the UI test deterministic and independent of a local kubectl install.
# Real YAML/merge behavior is covered by test-async-prompt.zsh when available.
print -r -- '#!/bin/sh
printf '\''%s\n'\'' '\''{"current-context":"test-cluster","contexts":[{"name":"test-cluster","context":{"namespace":"datadog"}}]}'\''
' >| "$test_home/bin/kubectl"
chmod +x "$test_home/bin/kubectl"
print -r -- 'contexts:
- context:
    namespace: datadog
  name: test-cluster
current-context: test-cluster' >| "$test_home/.kube/config"

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

function wait-for-prompt-settle {
  local chunk
  local -i idle_polls=0
  repeat 1000; do
    if zpty -rt prompt_shell chunk; then
      idle_polls=0
    elif (( ++idle_polls == 100 )); then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

function replace-buffer {
  local buffer=$1 expected=$2 forbidden=${3:-ZIGSH_NEVER_PRESENT} also_expected=${4:-} ignored
  while zpty -rt prompt_shell ignored; do :; done
  zpty -wn prompt_shell $'\C-U'
  zpty -wn prompt_shell "$buffer"
  # Visibility and provider data arrive independently. Inspect the actual
  # current prompt, not the first redraw or accumulated terminal output.
  repeat 500; do
    zpty -wn prompt_shell $'\C-G'
    sleep 0.01
    while zpty -rt prompt_shell ignored; do :; done
    if [[ -f $test_home/buffer-dump && $(<$test_home/buffer-dump) == "$buffer" ]]; then
      REPLY=$(<$test_home/prompt-dump)
      [[ $REPLY == *$expected* && $REPLY == *$also_expected* && $REPLY != *$forbidden* ]] && return 0
    fi
  done
  print -u2 -r -- "timed out waiting for prompt: $buffer"
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
  PATH="$test_home/bin:$PATH" \
  KUBECONFIG="$test_home/.kube/config" \
  TERM=xterm-256color \
  VIRTUAL_ENV="$test_home/project-env/.venv" \
  ZDOTDIR="$project_root/run" \
  ZIGSH_MODULE_DIR="$module_dir" \
  ZIGSH_SYNTAX_HIGHLIGHTING=0 \
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

case $OSTYPE in
  darwin*) [[ "$startup_output" == *' '* ]] ;;
  linux*) [[ "$startup_output" == *' '* ]] ;;
esac
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

zpty -wn prompt_shell $'\C-C'
wait-for-output
zpty -w prompt_shell 'alias k=kubectl cloud=aws; function zigsh-dump-prompt { print -Pn -- "$PROMPT" >| "$HOME/prompt-dump"; print -rn -- "$BUFFER" >| "$HOME/buffer-dump"; }; zle -N zigsh-dump-prompt; bindkey "^G" zigsh-dump-prompt; print ZIGSH_COMMAND_PROMPT_READY'
wait-for-output
wait-for-prompt-settle
set-terminal-columns "$prompt_tty" 160
wait-for-output
wide_prompt=$REPLY
[[ $wide_prompt == *' project-env '* ]]
[[ $wide_prompt == *$'\e[38;2;28;28;28;48;2;255;222;87m'* ]]

replace-buffer 'kubectl get pods' '󱃾  test-cluster datadog ' '  aws '
[[ $REPLY == *' project-env '* ]]
[[ $REPLY == *'󱃾  test-cluster datadog '* ]]
[[ $REPLY == *$'\e[38;2;48;48;48;48;2;28;28;28m│ '* ]]
[[ $REPLY == *$'\e[38;2;50;108;229;48;2;28;28;28m󱃾  test-cluster datadog '* ]]
[[ $REPLY != *'  aws '* ]]

replace-buffer 'echo kubectl' ' project-env ' '󱃾 '
[[ $REPLY != *'󱃾  test-cluster datadog '* ]]

replace-buffer 'echo values | helm template chart' '󱃾  test-cluster datadog ' '  aws '
[[ $REPLY == *'󱃾  test-cluster datadog '* ]]

replace-buffer 'aws sts get-caller-identity' '  aws ' '󱃾 '
[[ $REPLY == *'  aws '* ]]
[[ $REPLY != *'󱃾  test-cluster datadog '* ]]

replace-buffer 'echo aws-vault' ' project-env ' '  aws '
[[ $REPLY != *'  aws '* ]]

replace-buffer 'aws-vault exec dev' '  aws '
[[ $REPLY == *'  aws '* ]]

replace-buffer 'k get pods; cloud s3 ls' '  aws ' '' '󱃾  test-cluster datadog '
[[ $REPLY == *'󱃾  test-cluster datadog '* ]]
[[ $REPLY == *'  aws '* ]]
