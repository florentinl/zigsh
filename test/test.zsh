#!/usr/bin/env zsh -f
set -eu

module_path=("${0:A:h:h}/zig-out/lib" $module_path)
zmodload -d zigsh zsh/zle
zmodload zigsh

[[ $PROMPT == $' '*$'\n--> ' ]]
[[ $PROMPT == *"ok"$'\n--> ' ]]
[[ -z $RPROMPT ]]
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
