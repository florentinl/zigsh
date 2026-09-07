#!/usr/bin/env zsh -f
set -eu

if (( $# != 1 )) || [[ ! -f $1/zsh-syntax-highlighting.zsh ]]; then
  print -u2 'usage: test/compare-highlighting.zsh PATH_TO_ZSH_SYNTAX_HIGHLIGHTING'
  exit 2
fi

upstream_root=${1:A}
repository_root=${0:A:h:h}
test_home=$(mktemp -d)
dump_file="$test_home/regions"
trap 'zpty -d zigsh_shell 2>/dev/null || true; rm -rf -- "$test_home"' EXIT

zmodload zsh/zpty
mkdir -p -- "$test_home/bin" "$test_home/functions" "$test_home/auto-dir" "$test_home/cd-root/cd-dir"
print -r -- '#!/bin/sh' >| "$test_home/bin/external-command"
chmod +x "$test_home/bin/external-command"
touch -- "$test_home/existing-file" "$test_home/-output"
print -r -- 'available-function() { :; }' >| "$test_home/functions/available-function"

common_setup='cd -- $DIFF_HOME
path=($DIFF_HOME/bin $path)
fpath=($DIFF_HOME/functions $fpath)
cdpath=($DIFF_HOME/cd-root)
typeset PROJECT_ROOT=$DIFF_HOME
setopt AUTO_CD BANG_HIST
alias ll=print
alias first="print "
alias second=print
alias separator="print ok;"
alias redirector="print hi >"
alias assignment="NAME=value"
alias recurse=separator
alias cycle-a=cycle-b
alias cycle-b=cycle-a
alias -g G="| cat"
alias -g PIPE="|"
alias -s txt=cat
function helper { : }
autoload available-function missing-function
hash hashed-command=$DIFF_HOME/bin/external-command
hash -d work=$DIFF_HOME
disable -r repeat'

setup_chunks=(
  'cd -- $DIFF_HOME; path=($DIFF_HOME/bin $path); fpath=($DIFF_HOME/functions $fpath); cdpath=($DIFF_HOME/cd-root); typeset PROJECT_ROOT=$DIFF_HOME; setopt AUTO_CD BANG_HIST'
  'alias ll=print first="print " second=print separator="print ok;" redirector="print hi >" assignment="NAME=value" recurse=separator'
  'alias cycle-a=cycle-b cycle-b=cycle-a; alias -g G="| cat" PIPE="|"; alias -s txt=cat'
  'function helper { : }; autoload available-function missing-function'
  'hash hashed-command=$DIFF_HOME/bin/external-command; hash -d work=$DIFF_HOME; disable -r repeat'
)

function styles_in_range {
  local regions=$1 start=$2 end=$3 line style
  local -i offset
  local -a fields styles
  for (( offset = start; offset < end; offset += 1 )); do
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

function upstream_regions {
  local buffer=$1
  DIFF_BUFFER=$buffer DIFF_HOME=$test_home zsh -dfc '
    source "$1/zsh-syntax-highlighting.zsh"
    eval "$2"
    BUFFER=$DIFF_BUFFER
    CURSOR=${#BUFFER}
    typeset -a region_highlight
    region_highlight=()
    _zsh_highlight
    print -rl -- $region_highlight
  ' -- "$upstream_root" "$common_setup"
}

function start_zigsh_shell {
  local output command
  zpty zigsh_shell env \
    HOME="$test_home" \
    ZDOTDIR="$test_home" \
    DIFF_HOME="$test_home" \
    ZIGSH_HIGHLIGHT_DUMP="$dump_file" \
    zsh -dfi
  zpty -w zigsh_shell \
    "module_path=($repository_root/zig-out/lib \$module_path); zmodload -d zigsh zsh/zle; zmodload zigsh; print ZIGSH_MODULE_READY"
  zpty -r -m zigsh_shell output '*ZIGSH_MODULE_READY*'
  local -i setup_index=0
  for command in $setup_chunks; do
    (( setup_index += 1 ))
    if ! zpty -w zigsh_shell "$command; print ZIGSH_DIFFERENTIAL_SETUP_$setup_index"; then
      print -u2 -r -- "setup command $setup_index could not be written: $command"
      return 1
    fi
    zpty -r -m zigsh_shell output "*ZIGSH_DIFFERENTIAL_SETUP_$setup_index*"
  done
  zpty -w zigsh_shell 'function diff-dump { print -rl -- $region_highlight >| $ZIGSH_HIGHLIGHT_DUMP; (( diff_count += 1 )); BUFFER="print DIFF_DUMPED_$diff_count"; zle accept-line; }; print DIFF_WIDGET_DEFINED'
  zpty -r -m zigsh_shell output '*DIFF_WIDGET_DEFINED*'
  zpty -w zigsh_shell "typeset -gi diff_count=0; zle -N diff-dump; bindkey '^G' diff-dump; print ZIGSH_DIFFERENTIAL_READY"
  zpty -r -m zigsh_shell output '*ZIGSH_DIFFERENTIAL_READY*'
}

typeset -gi expected_zigsh_dump=0
function load_zigsh_regions {
  local buffer=$1 output
  (( expected_zigsh_dump += 1 ))
  zpty -wn zigsh_shell "${buffer}"$'\C-G'
  zpty -r -m zigsh_shell output "*DIFF_DUMPED_$expected_zigsh_dump*"
  REPLY=$(<"$dump_file")
}

fixtures=(
  $'regular-alias\tll\t0\t2'
  $'trailing-alias\tfirst second\t6\t12\tintentional-improvement'
  $'global-alias\tprint G hello\t6\t7'
  $'suffix-alias\tsnapshot.txt\t0\t12'
  $'function\thelper\t0\t6'
  $'autoload-function\tavailable-function\t0\t18'
  $'missing-autoload\tmissing-function\t0\t16\tintentional-improvement'
  $'reserved-word\tif true; then print ok; fi\t0\t2'
  $'builtin-token\tunset\t0\t5'
  $'disabled-reserved\trepeat\t0\t6'
  $'builtin\tprint\t0\t5'
  $'external\texternal-command\t0\t16'
  $'hashed\thashed-command\t0\t14'
  $'unknown\tmissing-command\t0\t15'
  $'precommand\tenv -u OLD print\t0\t3'
  $'precommand-command\tenv -u OLD print\t11\t16'
  $'autocd\tauto-dir\t0\t8'
  $'path\tprint existing-file\t6\t19'
  $'path-prefix\tprint exist\t6\t11'
  $'named-directory\tprint ~work/existing-file\t6\t25'
  $'safe-parameter\tprint $PROJECT_ROOT/existing-file\t19\t33\tintentional-improvement'
  $'equals-path\tprint =external-command\t6\t23'
  $'equals-command\t=external-command\t0\t17'
  $'separator-alias\tseparator missing-command\t10\t25'
  $'redirection-alias\tredirector -output\t11\t18'
  $'assignment-alias\tassignment missing-command\t11\t26'
  $'recursive-alias\trecurse missing-command\t8\t23'
  $'global-pipeline\tprint PIPE missing-command\t11\t26\tintentional-improvement'
  $'globbing\tprint *.zig\t6\t11'
  $'number-range-globbing\tprint <-> x<->y\t6\t9'
  $'redirection-globbing-without-multios\tcat < *\t6\t7'
  $'globbing-with-quotes\t: "foo"*\'bar\'?"baz?"<17-29>"qu*ux"\t7\t8'
  $'glob-numeric-range-with-quotes\t: "foo"*\'bar\'?"baz?"<17-29>"qu*ux"\t20\t27'
  $'history-expansion\tprint !42\t6\t9'
  $'redirection\tprint hi > existing-file\t9\t10'
  $'redirection-coprocess-target\tcat <&p\t6\t7'
  $'redirection-numeric-target\techo foo>&2\t10\t11'
  $'redirection-named-fd\texec {foo}>&/tmp ls\t5\t10'
  $'double-quoted\tprint "hello"\t6\t13'
  $'incomplete-double-quoted-variable\t: "foo$bar\t6\t10'
  $'incomplete-dollar-quoted-escape\t: $\'\\xa1\t4\t8'
  $'dollar-quoted-invalid-escape\t: $\'foo\\xbar\\udeadbeef\\uzzzz\'\t22\t24'
  $'double-quoted-numeric-parameter\t: "$42foo"\t3\t6'
  $'double-quoted-braced-parameter\t: "${foo}bar"\t3\t9'
  $'command-substitution-delimiter\tprint $(print hi)\t6\t8'
  $'quoted-command-substitution-unclosed\techo "foo$( \t9\t11'
  $'process-substitution-delimiter\t: --foo=<(echo bar)\t8\t10'
  $'backquote-delimiter\tprint `print hi`\t6\t7'
)

typeset -gi failures=0 intentional_differences=0
start_zigsh_shell
for fixture in $fixtures; do
  fields=( ${(ps:\t:)fixture} )
  name=$fields[1]
  buffer=$fields[2]
  start=$fields[3]
  end=$fields[4]
  classification=${fields[5]:-match}
  load_zigsh_regions "$buffer"
  zigsh_output=$REPLY
  upstream=$(upstream_regions "$buffer")
  zigsh_style=$(styles_in_range "$zigsh_output" "$start" "$end")
  upstream_style=$(styles_in_range "$upstream" "$start" "$end")
  if [[ $zigsh_style != $upstream_style ]]; then
    if [[ $classification == intentional-improvement ]]; then
      (( intentional_differences += 1 ))
    else
      print -u2 -r -- "$name: zigsh=$zigsh_style upstream=$upstream_style buffer=${(qqq)buffer} range=$start..$end zigsh-regions=${(qqq)zigsh_output} upstream-regions=${(qqq)upstream}"
      (( failures += 1 ))
    fi
  fi
done

print -r -- "matched=$(( ${#fixtures} - intentional_differences )) intentional-improvements=$intentional_differences"
(( failures == 0 ))
