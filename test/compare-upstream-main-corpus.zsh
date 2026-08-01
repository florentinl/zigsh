#!/usr/bin/env zsh -f
set -u

if (( $# < 1 )) || [[ ! -f $1/zsh-syntax-highlighting.zsh ]]; then
  print -u2 'usage: test/compare-upstream-main-corpus.zsh PATH_TO_ZSH_SYNTAX_HIGHLIGHTING [FIXTURE ...]'
  exit 2
fi

upstream_root=${1:A}
repository_root=${0:A:h:h}
fixture_root=$upstream_root/highlighters/main/test-data
shift
report_path=${ZIGSH_CORPUS_REPORT:-}
shard_count=${ZIGSH_CORPUS_SHARD_COUNT:-1}
shard_index=${ZIGSH_CORPUS_SHARD_INDEX:-0}
strict=${ZIGSH_CORPUS_STRICT:-0}
max_difference_lines=${ZIGSH_CORPUS_MAX_DIFFERENCE_LINES:-3}

if [[ $shard_count != <-> ]] || (( shard_count == 0 )); then
  print -u2 -r -- 'ZIGSH_CORPUS_SHARD_COUNT must be a positive integer'
  exit 2
fi
if [[ $shard_index != <-> ]] || (( shard_index >= shard_count )); then
  print -u2 -r -- 'ZIGSH_CORPUS_SHARD_INDEX must be smaller than ZIGSH_CORPUS_SHARD_COUNT'
  exit 2
fi
if [[ $max_difference_lines != <-> ]]; then
  print -u2 -r -- 'ZIGSH_CORPUS_MAX_DIFFERENCE_LINES must be a non-negative integer'
  exit 2
fi

if [[ -n $report_path ]]; then
  : >| "$report_path"
fi

function report {
  print -r -- "$*"
  if [[ -n $report_path ]]; then
    print -r -- "$*" >> "$report_path"
  fi
}

if (( $# )); then
  fixtures=("$@")
else
  fixtures=($fixture_root/*.zsh(N))
fi

if (( ${#fixtures} == 0 )); then
  print -u2 -r -- "no fixtures found in $fixture_root"
  exit 2
fi

typeset -ar configuration_fixtures=(
  dirs_blacklist.zsh
  path-separators.zsh
  path-separators2.zsh
)

workspace=$(mktemp -d)
trap 'zpty -d corpus_shell 2>/dev/null || true; rm -rf -- "$workspace"' EXIT
zmodload zsh/zpty

typeset -gi matching_fixtures=0
typeset -gi differing_fixtures=0
typeset -gi skipped_fixtures=0
typeset -gi native_failures=0
typeset -gi missing_highlights=0
typeset -gi conflicting_highlights=0
typeset -gi richer_highlights=0
typeset -gi selected_fixtures=0

function styles_for_buffer {
  local regions=$1 buffer=$2 line style
  local -i offset
  local -a fields styles

  for (( offset = 0; offset < ${#buffer}; offset += 1 )); do
    style=none
    for line in "${(@f)regions}"; do
      fields=( ${(z)line} )
      (( ${#fields} >= 3 )) || continue
      if (( fields[1] <= offset && offset < fields[2] )); then
        style=${fields[3]%,}
      fi
    done
    styles+=($style)
  done
  print -r -- "${(j:|:)styles}"
}

function classify_difference {
  local upstream_style=$1 native_style=$2
  if [[ $upstream_style == none ]]; then
    REPLY=richer
  elif [[ $native_style == none ]]; then
    REPLY=missing
  else
    REPLY=conflicting
  fi
}

function fixture_command {
  local fixture=$1 buffer_path=$2 ready_marker=$3
  print -r -- "if source ${(q)fixture}; then print -rn -- \"\$PREBUFFER\$BUFFER\"$'\\0' >| ${(q)buffer_path}; print ${(q)ready_marker}; else print ${ready_marker}_FAILED; fi"
}

function start_native_shell {
  local fixture=$1 fixture_dir=$2 buffer_path=$3 marker=$4 output command
  zpty corpus_shell env \
    HOME="$fixture_dir/home" \
    ZDOTDIR="$fixture_dir/home" \
    ZIGSH_HIGHLIGHT_DUMP="$fixture_dir/regions" \
    zsh -dfi
  zpty -w corpus_shell "cd -- ${(q)fixture_dir}; module_path=($repository_root/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh; function corpus-dump { print -rl -- \$region_highlight >| \$ZIGSH_HIGHLIGHT_DUMP; (( corpus_dump_count += 1 )); BUFFER=\"print CORPUS_DUMPED_\$corpus_dump_count\"; zle accept-line; }; typeset -gi corpus_dump_count=0; zle -N corpus-dump; bindkey '^G' corpus-dump; print CORPUS_MODULE_READY"
  zpty -r -m corpus_shell output '*CORPUS_MODULE_READY*' || return 1

  command=$(fixture_command "$fixture" "$buffer_path" "$marker")
  zpty -w corpus_shell "$command"
  zpty -r -m corpus_shell output "*$marker*" || return 1
  [[ $output != *"${marker}_FAILED"* ]]
}

function upstream_regions {
  local fixture=$1 fixture_dir=$2
  UPSTREAM_FIXTURE=$fixture UPSTREAM_WORKSPACE=$fixture_dir zsh -dfc '
    cd -- "$UPSTREAM_WORKSPACE"
    source "$1/zsh-syntax-highlighting.zsh" || exit 1
    source "$UPSTREAM_FIXTURE" || exit 1
    CURSOR=${#BUFFER}
    typeset -a region_highlight
    region_highlight=()
    _zsh_highlight
    print -rl -- $region_highlight
  ' -- "$upstream_root"
}

function compare_fixture {
  local fixture=$1 name=${fixture:t:r}
  local marker="CORPUS_FIXTURE_${RANDOM}_${RANDOM}"
  local fixture_dir="$workspace/$name"
  local buffer_path="$fixture_dir/buffer"
  local output upstream_output native_output upstream_styles native_styles
  local -i offset differences=0 printed_differences=0

  mkdir -p -- "$fixture_dir/home" "$fixture_dir/upstream" "$fixture_dir/native"
  if ! start_native_shell "$fixture" "$fixture_dir/native" "$buffer_path" "$marker"; then
    report "SKIP $name native fixture setup failed"
    (( skipped_fixtures += 1 ))
    zpty -d corpus_shell 2>/dev/null || true
    return
  fi

  local fixture_buffer
  if ! IFS= read -r -d '' fixture_buffer < "$buffer_path"; then
    report "SKIP $name fixture did not define a buffer"
    (( skipped_fixtures += 1 ))
    zpty -d corpus_shell 2>/dev/null || true
    return
  fi

  upstream_output=$(upstream_regions "$fixture" "$fixture_dir/upstream") || {
    report "SKIP $name upstream fixture setup failed"
    (( skipped_fixtures += 1 ))
    zpty -d corpus_shell 2>/dev/null || true
    return
  }

  zpty -wn corpus_shell $'\e[200~'"$fixture_buffer"$'\e[201~\C-G'
  if ! zpty -r -m corpus_shell output '*CORPUS_DUMPED_1*'; then
    report "FAIL $name native ZLE dump failed"
    (( native_failures += 1 ))
    zpty -d corpus_shell 2>/dev/null || true
    return
  fi
  native_output=$(<"$fixture_dir/native/regions")
  zpty -d corpus_shell 2>/dev/null || true

  upstream_styles=$(styles_for_buffer "$upstream_output" "$fixture_buffer")
  native_styles=$(styles_for_buffer "$native_output" "$fixture_buffer")
  if [[ $upstream_styles == $native_styles ]]; then
    (( matching_fixtures += 1 ))
    return
  fi

  (( differing_fixtures += 1 ))
  local -a upstream_by_offset native_by_offset
  upstream_by_offset=( ${(s:|:)upstream_styles} )
  native_by_offset=( ${(s:|:)native_styles} )
  for (( offset = 1; offset <= ${#upstream_by_offset}; offset += 1 )); do
    [[ ${upstream_by_offset[offset]} == ${native_by_offset[offset]} ]] && continue
    classify_difference "${upstream_by_offset[offset]}" "${native_by_offset[offset]}"
    case $REPLY in
      missing) (( missing_highlights += 1 )) ;;
      conflicting) (( conflicting_highlights += 1 )) ;;
      richer) (( richer_highlights += 1 )) ;;
    esac
    (( differences += 1 ))
    if (( printed_differences < max_difference_lines )); then
      report "DIFF $name char=$(( offset - 1 )) kind=$REPLY upstream=${upstream_by_offset[offset]} native=${native_by_offset[offset]}"
      (( printed_differences += 1 ))
    fi
  done
  report "BACKLOG $name differences=$differences"
}

function is_configuration_fixture {
  local fixture=$1 excluded
  for excluded in $configuration_fixtures; do
    if [[ ${fixture:t} == $excluded ]]; then
      return 0
    fi
  done
  return 1
}

typeset -gi fixture_index=0
for fixture in $fixtures; do
  if (( fixture_index % shard_count != shard_index )); then
    (( fixture_index += 1 ))
    continue
  fi
  (( fixture_index += 1 ))
  (( selected_fixtures += 1 ))
  if [[ ! -f $fixture ]]; then
    fixture="$fixture_root/$fixture"
  fi
  if [[ ! -f $fixture ]]; then
    report "SKIP ${fixture:t:r} fixture not found"
    (( skipped_fixtures += 1 ))
    continue
  fi
  if is_configuration_fixture "$fixture"; then
    report "SKIP ${fixture:t:r} upstream configuration fixture"
    (( skipped_fixtures += 1 ))
    continue
  fi
  compare_fixture "$fixture"
done

report "SUMMARY shard=$shard_index/$shard_count fixtures=$selected_fixtures matched=$matching_fixtures differing=$differing_fixtures skipped=$skipped_fixtures native-failures=$native_failures missing=$missing_highlights conflicting=$conflicting_highlights richer=$richer_highlights"

if [[ $strict != 0 ]] && (( native_failures || missing_highlights || conflicting_highlights )); then
  exit 1
fi
