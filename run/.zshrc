module_path=("$ZIGSH_MODULE_DIR" $module_path)
zmodload -d zigsh zsh/zle
zmodload zigsh || return 1

unset ZIGSH_MODULE_DIR ZDOTDIR
