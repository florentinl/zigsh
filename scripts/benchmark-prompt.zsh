#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty

project_root=${0:A:h:h}
target_dir=${1:-$PWD}
iterations=${2:-5}
module_dir=${3:-$project_root/zig-out/lib}
test_home=$(mktemp -d)

function cleanup {
  zpty -w benchmark_shell 'zmodload -u zigsh; exit' 2>/dev/null || true
  sleep 0.05
  zpty -d benchmark_shell 2>/dev/null || true
  rm -rf -- "$test_home"
}
trap cleanup EXIT

function drain-until-idle {
  local chunk
  local -i idle_polls=0 received=0
  REPLY=
  repeat 2000; do
    if zpty -rt benchmark_shell chunk; then
      REPLY+=$chunk
      idle_polls=0
      received=1
    elif (( received && ++idle_polls == 20 )); then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

[[ -d $target_dir ]] || { print -u2 "not a directory: $target_dir"; exit 2; }
[[ -f $module_dir/zigsh.so ]] || {
  print -u2 "missing $module_dir/zigsh.so; run: zig build -Doptimize=ReleaseSafe"
  exit 2
}

zpty -b benchmark_shell env \
  HOME="$test_home" \
  TERM=xterm-256color \
  ZDOTDIR="$project_root/run" \
  ZIGSH_MODULE_DIR="$module_dir" \
  zsh -di
drain-until-idle
zpty -w benchmark_shell "cd -- ${(q)target_dir}; print ZIGSH_BENCHMARK_READY"
drain-until-idle

print "zigsh prompt benchmark"
print "  directory:  $target_dir"
print "  iterations: $iterations"
print "  build:      $module_dir/zigsh.so"

for iteration in {1..$iterations}; do
  zpty -w benchmark_shell "print ZIGSH_BENCHMARK_$iteration"
  drain-until-idle
  zpty -w benchmark_shell "zigsh timings; print ZIGSH_TIMINGS_DONE"
  drain-until-idle
  snapshot=${REPLY#*Prompt pipeline}
  snapshot=${snapshot%%Segment renderers*}
  print
  print "iteration $iteration"
  print -r -- "Prompt pipeline${snapshot}"
done
