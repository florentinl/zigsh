#!/bin/sh
set -eu

zsh_dir=$1

if [ ! -d "$zsh_dir/.git" ]; then
    mkdir -p "$(dirname "$zsh_dir")"
    git clone https://git.code.sf.net/p/zsh/code "$zsh_dir"
fi

if [ ! -f "$zsh_dir/Src/zsh.mdh" ]; then
    git -C "$zsh_dir" checkout --detach zsh-5.9
    (
        cd "$zsh_dir"
        sh Util/preconfig
        ./configure
        make -C Src headers
    )
fi
