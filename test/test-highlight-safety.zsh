#!/usr/bin/env zsh -f
set -eu
unsetopt bg_nice

patched_parser=$1
upstream_parser=$2
fixture_dir=${0:A:h}/highlighting/adversarial

function run-with-timeout {
  local parser=$1
  local polls=$2
  shift 2

  (
    limit addressspace 256m
    "$parser" "$@" >/dev/null 2>&1
  ) &
  local parser_pid=$!

  local poll=0
  while kill -0 "$parser_pid" 2>/dev/null; do
    if (( poll == polls )); then
      kill -KILL "$parser_pid" 2>/dev/null || true
      wait "$parser_pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.01
    (( poll += 1 ))
  done

  if wait "$parser_pid" 2>/dev/null; then
    return 0
  else
    return $?
  fi
}

hang_input=$(<"$fixture_dir/empty-regex-no-slash.zsh")
if run-with-timeout "$upstream_parser" 25 parse "$hang_input"; then
  print -u2 'unmodified tree-sitter-zsh unexpectedly accepted the known hang input'
  exit 1
fi

if run-with-timeout "$patched_parser" 200 parse "$hang_input"; then
  :
else
  patched_hang_status=$?
  print -u2 "patched tree-sitter-zsh failed the hang input with status $patched_hang_status"
  exit 1
fi

overflow_input=$(<"$fixture_dir/scanner-count-overflow.zsh")
if run-with-timeout "$upstream_parser" 200 parse "$overflow_input"; then
  print -u2 'unmodified tree-sitter-zsh unexpectedly accepted the scanner overflow input'
  exit 1
else
  upstream_overflow_status=$?
fi
if (( upstream_overflow_status == 124 )); then
  print -u2 'unmodified tree-sitter-zsh hung instead of aborting on the scanner overflow input'
  exit 1
fi

if run-with-timeout "$patched_parser" 200 parse "$overflow_input"; then
  :
else
  patched_overflow_status=$?
  print -u2 "patched tree-sitter-zsh failed the scanner overflow input with status $patched_overflow_status"
  exit 1
fi

incremental_before=$(<"$fixture_dir/zero-width-regex-before.zsh")
incremental_after=$(<"$fixture_dir/zero-width-regex-after.zsh")
if run-with-timeout "$upstream_parser" 25 edits "$incremental_before" "$incremental_after"; then
  print -u2 'unmodified tree-sitter-zsh unexpectedly accepted the zero-width incremental input'
  exit 1
fi

if run-with-timeout "$patched_parser" 200 edits "$incremental_before" "$incremental_after"; then
  :
else
  patched_incremental_status=$?
  print -u2 "patched tree-sitter-zsh failed the zero-width incremental input with status $patched_incremental_status"
  exit 1
fi
