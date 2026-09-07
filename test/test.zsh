#!/usr/bin/env zsh -f
set -eu

module_path=("${0:A:h:h}/zig-out/lib" $module_path)
COLUMNS=120
zmodload -d zigsh zsh/zle
zmodload zigsh

[[ $PROMPT == *'╭─'* ]]
case $OSTYPE in
  darwin*) [[ $PROMPT == *' '* ]] ;;
  linux*) [[ $PROMPT == *' '* ]] ;;
esac
# Noninteractive loading must not wait for Git. The initial directory comes
# from shell PWD; PTY tests verify the later worker-supplied repository state.
[[ $PROMPT == *'  '* ]]
[[ $PROMPT == *zigsh* ]]
[[ $PROMPT == *$'\n'*'╰─'*'❯'* ]]
[[ $RPROMPT == *'─╯'* ]]
prompt_fill=${PROMPT#*}
prompt_fill=${prompt_fill%%*}
[[ $prompt_fill != *'48;2'* ]]
[[ ! -o prompt_subst ]]
[[ $HISTFILE == "$HOME/.zsh_history" ]]
(( HISTSIZE == 50000 ))
(( SAVEHIST == 10000 ))
[[ -o extended_history ]]
[[ -o hist_expire_dups_first ]]
[[ -o hist_ignore_dups ]]
[[ -o hist_ignore_space ]]
[[ -o hist_verify ]]
[[ -o share_history ]]

timing_output=$(zigsh timings)
[[ $timing_output == *'Prompt pipeline (latest render:'* ]]
[[ $timing_output == *'render_total'* ]]
[[ $timing_output == *'initial_total'* ]]
[[ $timing_output == *'context'* ]]
[[ $timing_output == *'layout'* ]]
[[ $timing_output == *'git_worker'* ]]
[[ $timing_output == *'Segment renderers'* ]]
[[ $timing_output == *'directory'* ]]

normal_cursor_up=$'\e[A'
normal_cursor_down=$'\e[B'
application_cursor_up=$'\eOA'
application_cursor_down=$'\eOB'

for keymap in emacs viins vicmd; do
  [[ $(bindkey -M "$keymap" "$normal_cursor_up") == *' zigsh-up-line-or-beginning-search' ]]
  [[ $(bindkey -M "$keymap" "$normal_cursor_down") == *' zigsh-down-line-or-beginning-search' ]]
  [[ $(bindkey -M "$keymap" "$application_cursor_up") == *' zigsh-up-line-or-beginning-search' ]]
  [[ $(bindkey -M "$keymap" "$application_cursor_down") == *' zigsh-down-line-or-beginning-search' ]]
done

zigsh
zmodload -u zigsh
