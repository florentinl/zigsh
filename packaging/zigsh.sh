# Opt-in loader for the Homebrew zigsh formula.
#
# Source this file from an interactive zsh session or add the source command
# shown in the formula's caveat to ~/.zshrc. Homebrew installation alone never
# loads zigsh or changes the shell's configuration.

if [[ -o interactive ]] && (( ! $+builtins[zle] )); then
  zmodload zsh/zle || return 1
fi

if ! zmodload -e zigsh; then
  typeset -g ZIGSH_MODULE_DIR=${${(%):-%x}:A:h}/libexec
  module_path=("$ZIGSH_MODULE_DIR" $module_path)
  zmodload -d zigsh zsh/zle || return 1
  zmodload zigsh || return 1
  unset ZIGSH_MODULE_DIR
fi
