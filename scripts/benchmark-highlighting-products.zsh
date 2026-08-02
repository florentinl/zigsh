#!/usr/bin/env zsh -f
set -eu

zmodload zsh/zpty zsh/datetime

project_root=${0:A:h:h}
upstream_dir=${1:-}
iterations=${2:-10}
module_dir=${3:-$project_root/zig-out/lib}
sizes=(32 1024 10240)

function cleanup {
  local shell_name
  for shell_name in benchmark_zigsh benchmark_upstream; do
    zpty -w "$shell_name" 'zmodload -u zigsh 2>/dev/null || true; exit' 2>/dev/null || true
    zpty -d "$shell_name" 2>/dev/null || true
  done
}
trap cleanup EXIT

[[ -f $module_dir/zigsh.so ]] || {
  print -u2 "missing $module_dir/zigsh.so; run: zig build -Doptimize=ReleaseSafe"
  exit 2
}
[[ -n $upstream_dir && -f $upstream_dir/zsh-syntax-highlighting.zsh ]] || {
  print -u2 "usage: $0 ZSH_SYNTAX_HIGHLIGHTING_CHECKOUT [ITERATIONS] [MODULE_DIR]"
  exit 2
}

function drain-until-highlight {
  local shell_name=$1 chunk
  REPLY=
  repeat 3000; do
    if zpty -rt "$shell_name" chunk; then
      REPLY+=$chunk
      [[ $REPLY == *$'\e[32m'* ]] && return 0
    fi
    sleep 0.001
  done
  return 1
}

function drain-until-marker {
  local shell_name=$1 marker=$2 chunk
  REPLY=
  repeat 3000; do
    if zpty -rt "$shell_name" chunk; then
      REPLY+=$chunk
      # The terminal echoes the command once; the explicit print is the second
      # occurrence and proves that ZLE is ready for the benchmark keystroke.
      [[ $REPLY == *$marker*$marker* ]] && return 0
    fi
    sleep 0.001
  done
  return 1
}

function start-product {
  local name=$1 product=$2
  zpty -b "$name" env HOME=/tmp TERM=xterm-256color zsh -dfi
  zpty -w "$name" 'typeset -gi ZIGSH_BENCH_SIZE=0'
  zpty -w "$name" 'function zigsh-bench-widget { BUFFER="echo ${(l:ZIGSH_BENCH_SIZE::x:)}"; CURSOR=0; region_highlight=(); zle redisplay }'
  zpty -w "$name" 'zle -N zigsh-bench-widget; bindkey "^B" zigsh-bench-widget'
  if [[ $product == zigsh ]]; then
    zpty -w "$name" "module_path=(${(q)module_dir} \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh"
  else
    zpty -w "$name" "source ${(q)upstream_dir}/zsh-syntax-highlighting.zsh"
  fi
  zpty -w "$name" 'print ZIGSH_BENCH_SETUP_READY'
  drain-until-marker "$name" ZIGSH_BENCH_SETUP_READY
  sleep 0.02
  local ignored
  while zpty -rt "$name" ignored; do :; done
}

function benchmark-product {
  local product=$1 shell_name="benchmark_$1"
  start-product "$shell_name" "$product"
  print "$product"
  for size in $sizes; do
    local -a samples=()
    repeat $iterations; do
      zpty -w "$shell_name" "ZIGSH_BENCH_SIZE=$size; print ZIGSH_BENCH_ARMED"
      drain-until-marker "$shell_name" ZIGSH_BENCH_ARMED
      local -F started=$EPOCHREALTIME
      zpty -wn "$shell_name" $'\x02'
      drain-until-highlight "$shell_name"
      samples+=($(( (EPOCHREALTIME-started)*1000 )))
      zpty -wn "$shell_name" $'\x03'
    done
    local -F total=0 sample
    for sample in $samples; do (( total += sample )); done
    printf '  %6d bytes  mean %8.3f ms  (%d runs)\n' $size $(( total / $#samples )) $#samples
  done
  zpty -d "$shell_name"
}

print "Full persistent-ZLE highlighting latency (keystroke to colored redisplay)"
benchmark-product zigsh
benchmark-product upstream
