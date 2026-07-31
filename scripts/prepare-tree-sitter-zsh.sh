#!/bin/sh
set -eu

grammar_dir=$1
patch_dir=$2
revision=7a593401efb5418ffdedbe3c0e4c61c6d240166d

patch_dir=$(cd "$patch_dir" && pwd)

if [ ! -d "$grammar_dir/.git" ]; then
    mkdir -p "$(dirname "$grammar_dir")"
    git clone https://github.com/georgeharker/tree-sitter-zsh.git "$grammar_dir"
    git -C "$grammar_dir" checkout --detach "$revision"
fi

actual_revision=$(git -C "$grammar_dir" rev-parse HEAD)
if [ "$actual_revision" != "$revision" ]; then
    echo "tree-sitter-zsh is at $actual_revision, expected $revision" >&2
    exit 1
fi

if ! git -C "$grammar_dir" diff --quiet -- src/parser.c; then
    echo "tree-sitter-zsh src/parser.c differs from $revision" >&2
    exit 1
fi

if [ ! -f "$grammar_dir/src/scanner.upstream.c" ]; then
    git -C "$grammar_dir" show "$revision:src/scanner.c" >"$grammar_dir/src/scanner.upstream.c"
fi
if ! git -C "$grammar_dir" show "$revision:src/scanner.c" | cmp -s - "$grammar_dir/src/scanner.upstream.c"; then
    echo "tree-sitter-zsh src/scanner.upstream.c differs from $revision" >&2
    exit 1
fi

for patch in "$patch_dir"/*.patch; do
    if git -C "$grammar_dir" apply --check "$patch" 2>/dev/null; then
        git -C "$grammar_dir" apply "$patch"
    elif ! git -C "$grammar_dir" apply --reverse --check "$patch" 2>/dev/null; then
        echo "cannot apply $patch cleanly" >&2
        exit 1
    fi
done

expected_dir=$(mktemp -d)
trap 'rm -rf -- "$expected_dir"' EXIT HUP INT TERM
mkdir -p "$expected_dir/src"
cp "$grammar_dir/src/scanner.upstream.c" "$expected_dir/src/scanner.c"
for patch_file in "$patch_dir"/*.patch; do
    patch -s -d "$expected_dir" -p1 <"$patch_file"
done
if ! cmp -s "$expected_dir/src/scanner.c" "$grammar_dir/src/scanner.c"; then
    echo "tree-sitter-zsh src/scanner.c contains changes outside the owned patch series" >&2
    exit 1
fi
