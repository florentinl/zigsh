#!/usr/bin/env zsh -f
# Exercise the production workers through ZLE, not the test-only job dispatcher.
set -eu
zmodload zsh/zpty

project_root=${0:A:h:h}
module_dir=${ZIGSH_TEST_MODULE_DIR:-$project_root/zig-out/lib}
test_home=$(mktemp -d)
real_kubectl=${commands[kubectl]:-}
trap 'zpty -d async_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT
mkdir -p "$test_home/bin" "$test_home/slow-repo/.git"
# Even initial Git metadata lookup would hang if done on the editor thread.
mkfifo "$test_home/slow-repo/.git/HEAD"
print -r -- '#!/bin/sh
if [ -f "$HOME/hang-kube" ]; then
  echo $$ > "$HOME/kube-child"
  exec sleep 60
fi
if [ -f "$HOME/use-real" ]; then
  exec "$ZIGSH_REAL_KUBECTL" "$@"
fi
printf '\''%s\n'\'' '\''{"current-context":"local","contexts":[{"name":"local","context":{"namespace":"development"}}]}'\''
' > "$test_home/bin/kubectl"
chmod +x "$test_home/bin/kubectl"

terminal_tail=
function drain {
  local chunk
  while zpty -rt async_shell chunk; do
    terminal_tail+=$chunk
    terminal_tail=${terminal_tail[-16384,-1]}
  done
}
function wait-file {
  local file_path=$1
  repeat 150; do
    drain
    [[ -f $file_path ]] && return 0
    sleep 0.01
  done
  print -u2 -r -- "shell did not respond: $file_path"
  print -u2 -r -- "$terminal_tail"
  if [[ -f $test_home/shell-pid ]]; then
    ps -o pid,ppid,stat,wchan,comm -p "$(<$test_home/shell-pid)" >&2 || true
  fi
  return 1
}
function dump {
  rm -f "$test_home/dumped"
  zpty -wn async_shell $'\C-G'
  wait-file "$test_home/dumped"
  REPLY=$(<$test_home/prompt)
  typeset -ga snapshot=( ${(s.:.)$(<$test_home/dumped)} )
}
function expect-prompt {
  local expected=$1
  repeat 150; do
    dump
    [[ $REPLY == *$expected* ]] && (( snapshot[2] > 0 )) && return 0
    sleep 0.01
  done
  print -u2 -r -- "prompt never contained: $expected"
  return 1
}
function fresh-prompt {
  zpty -wn async_shell $'\C-C'
  repeat 150; do
    dump
    (( snapshot[1] == 0 )) && return 0
  done
  return 1
}

zpty -b async_shell env HOME="$test_home" ZDOTDIR="$test_home" \
  TERM=xterm-256color PATH="$test_home/bin:$PATH" \
  KUBECONFIG="$test_home/config1:$test_home/config2" \
  VIRTUAL_ENV= ZIGSH_REAL_KUBECTL="$real_kubectl" \
  ZIGSH_SYNTAX_HIGHLIGHTING=1 zsh -di
zpty -w async_shell "cd -- ${(q)test_home}/slow-repo; stty columns 220; module_path=(${(q)module_dir} \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh
function async-dump { print -Pn -- \"\$PROMPT\" >| \"\$HOME/prompt\"; print -r -- \"\${#BUFFER}:\${#region_highlight}\" >| \"\$HOME/dumped\"; }
function async-load { BUFFER=\$(<\"\$HOME/long-buffer\"); CURSOR=0; }
function async-aws { BUFFER='aws sts get-caller-identity'; CURSOR=0; }
zle -N async-dump; zle -N async-load; zle -N async-aws
bindkey '^G' async-dump; bindkey '^L' async-load; bindkey '^W' async-aws
print -r -- \$\$ >| \"\$HOME/shell-pid\"; print ready >| \"\$HOME/ready\""
wait-file "$test_home/ready"
dump
[[ $REPLY == *'❯'* ]]

# Force EOF recovery with line analysis as the last ZLE fd watcher. The first
# idle-worker death moves its replacement to the end of the watch list. Then
# an obsolete in-flight request fails and must queue/install the latest buffer
# without any keyboard event helping the replacement socket make progress.
fresh-prompt
shell_pid=$(<$test_home/shell-pid)
function live-workers {
  local pid state
  typeset -ga worker_pids=()
  for pid in ${(f)"$(pgrep -P "$shell_pid")"}; do
    state=$(ps -o stat= -p "$pid") || continue
    [[ $state == *Z* ]] || worker_pids+=($pid)
  done
  worker_pids=( ${(on)worker_pids} )
}
live-workers
(( ${#worker_pids} == 3 ))
old_workers=( $worker_pids )
kill -KILL "$worker_pids[1]"
replacement=
repeat 150; do
  drain
  live-workers
  for pid in $worker_pids; do
    (( ${old_workers[(Ie)$pid]} == 0 )) && replacement=$pid
  done
  [[ -n $replacement ]] && break
  sleep 0.01
done
[[ -n $replacement ]]
kill -STOP "$replacement"
zpty -wn async_shell 'echo obsolete'
zpty -wn async_shell $'\C-W'
dump
(( snapshot[1] == 27 ))
terminal_tail=
kill -KILL "$replacement"
# Deliberately no dump widget, zle redraw, or keyboard input in this wait.
repeat 150; do
  drain
  [[ $terminal_tail == *'  aws '* ]] && break
  sleep 0.01
done
[[ $terminal_tail == *'  aws '* ]]
fresh-prompt

# Config subprocesses can stall, but typing, dumping and changing prompts must
# remain responsive. They use a different worker from command analysis.
touch "$test_home/hang-kube"
zpty -wn async_shell 'kubectl get pods'
wait-file "$test_home/kube-child"
kube_child=$(<$test_home/kube-child)
dump
(( snapshot[1] == 16 ))
zpty -wn async_shell $'\C-W'
expect-prompt '  aws '
rm "$test_home/hang-kube"
fresh-prompt
repeat 150; do
  kill -0 "$kube_child" 2>/dev/null || break
  sleep 0.01
done
! kill -0 "$kube_child" 2>/dev/null
zpty -wn async_shell 'kubectl get pods'
expect-prompt '󱃾  local development '

# A provider that never finishes must also be timed out without user input,
# including its subprocess. The next prompt must recover and load new data.
fresh-prompt
touch "$test_home/hang-kube"
rm -f "$test_home/kube-child"
zpty -wn async_shell 'kubectl get pods'
wait-file "$test_home/kube-child"
kube_child=$(<$test_home/kube-child)
repeat 700; do
  drain
  kill -0 "$kube_child" 2>/dev/null || break
  sleep 0.01
done
! kill -0 "$kube_child" 2>/dev/null
rm "$test_home/hang-kube"
fresh-prompt
zpty -wn async_shell 'kubectl get pods'
expect-prompt '󱃾  local development '

# The first reply exceeds normal socket buffering. The second exceeds the
# response limit. Neither may wedge the next generation or block ZLE.
padding=
for length in 32768 1048576; do
  print -rn -- ${(pl:$length::a:)padding} >| "$test_home/long-buffer"
  zpty -wn async_shell $'\C-L'
  dump
  (( snapshot[1] == length ))
  zpty -wn async_shell $'\C-W'
  expect-prompt '  aws '
  (( snapshot[2] > 0 ))
done

# Optional real-provider contract checks: no cluster/network access is made.
# The normal test suite also exercises canonical JSON without kubectl installed.
if [[ -n $real_kubectl ]]; then
  touch "$test_home/use-real"
  print -r -- 'current-context: ""' >| "$test_home/config1"
  for config in \
    $'contexts:\n# generated entries\n- name: local\n  context:\n    namespace: development\ncurrent-context: local # active' \
    'contexts: [{name: local, context: {namespace: development}}]
current-context: local'; do
    print -r -- "$config" >| "$test_home/config2"
    fresh-prompt
    zpty -wn async_shell 'kubectl get pods'
    expect-prompt '󱃾  local development '
  done
  # A FIFO config also cannot block the shell, and is cancelled on unload.
  rm "$test_home/config1" "$test_home/config2"
  mkfifo "$test_home/config1"
  fresh-prompt
  zpty -wn async_shell 'kubectl get pods'
  dump
  (( snapshot[1] == 16 ))
fi

fresh-prompt
zpty -w async_shell 'zmodload -u zigsh; print UNLOADED; print done >| "$HOME/unloaded"'
wait-file "$test_home/unloaded"
