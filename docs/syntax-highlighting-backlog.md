# Native syntax highlighting compatibility backlog

This is the execution checkpoint for default `zsh-syntax-highlighting` main
compatibility. It records evidence from the isolated corpus runner without
treating upstream's display choices as a ceiling for Zigsh.

## Comparison contract

The runner compares effective per-character styles from a fresh upstream shell
and a fresh native ZLE shell for each upstream fixture.

- `missing`: upstream supplies meaning that Zigsh does not highlight.
- `conflicting`: both highlight a character, but they disagree about its
  meaning.
- `richer`: Zigsh adds a distinct visual meaning where upstream is plain.

Only `missing` and `conflicting` results are correctness work by default.
`richer` results remain visible until a review proves that they obscure a
correct shell interpretation. Upstream fixtures dedicated to configurable
directory blacklists or path-separator styles are out of scope.

Run the corpus with:

```console
zig build highlight-upstream-corpus -- /path/to/zsh-syntax-highlighting
```

Set `ZIGSH_CORPUS_REPORT` to retain a line-oriented report outside the
repository.

## Checkpoints

| Slice | Status | Evidence | Next action |
| --- | --- | --- | --- |
| Isolated main corpus runner | complete | Fresh ZLE and upstream shells; fixture setup is isolated and the command buffer is never executed | Keep as the compatibility gate |
| Complete redirection grammar | complete | `redirection-all`: 19 conflicting regions reduced to 0; 15 blue structural characters remain richer | Keep raw operator normalization beside Tree-sitter recovery |
| Command-position paths | complete | `abspath-in-command-position*`: 5 conflicting regions reduced to 0; two magenta command separators remain richer | Treat an existing directory at an unfinished command position as a path prefix unless `AUTO_CD` gives it stronger meaning |
| Alias validity and context | complete | Core alias fixtures have no missing or conflicting regions; nested aliases leave only richer magenta separators | Preserve valid aliases, then project comment, unusable-directory, and unknown-command outcomes back through alias lineage |
| Dynamic scalar expansion | complete | `parameter-expansion-untokenized2` matches; `untokenized1` recovers the following command and keeps a native cyan parameter layer | Virtualize only simple safe scalar command words, with lineage and depth limits shared with aliases |
| Analysis pipeline boundaries | complete | Semantic analysis now returns visual spans and typed alias or safe-parameter expansion candidates separately; virtual expansion no longer infers behavior from a color style | Keep display composition, semantic meaning, and virtual source projection as separate layers |
| AST-scoped recovery | complete | Valid Zsh extensions are recovered from `function_definition`, `always_clause`, and `string` nodes; malformed forms are scanned only inside Tree-sitter `ERROR` ranges | Prefer a grammar patch when valid Zsh needs broader structural understanding |
| Assignment before reserved words | complete | All five fixtures have no missing or conflicting regions; assignment names remain cyan as an intentional native layer | Keep assignment names semantically visible while recovering the following structure |
| Incomplete syntax recovery | in progress | `always*` match; representative anonymous, bracket, and arithmetic fixtures now have no missing regions, with only explicit error feedback or extra punctuation remaining | Keep source-proven recovery narrow, then harden Tree-sitter for deeper malformed structures |
| Nested quote and substitution state | in progress | Unclosed backticks now restore their delimiter, command, and path-prefix context; adjacent substitutions retain a yellow outer-string layer | Extend recovery only where a bounded lexical context is unambiguous; leave nested backtick grammar for the hardening milestone |
| Default-corpus closure | pending | Full corpus report | Classify every remaining mismatch as correctness, approved richer behavior, or unsupported configuration |

## Redirection acceptance cases

The first implementation slice must cover the operators exercised by upstream's
`redirection-all` fixture:

- input, output, append, clobber, read-write, here-string, and heredoc forms;
- optional source descriptors, including numeric descriptors;
- descriptor duplication to a number, `-`, or coprocess `p`;
- combined stdout/stderr operators and their clobber variants;
- plain destinations that remain ordinary arguments or paths rather than file
  descriptors.

The success criterion is correct source/operator/destination interpretation.
Magenta structural delimiters may remain an approved richer layer if they do
not replace the redirection meaning.

## Approved semantic differences

`alias-assignment1` remains intentionally different. Its `x=y` is represented
as an assignment name with a cyan variable layer, rather than being painted as
an invalid command because an alias happens to have the same spelling. This is
a more faithful syntax interpretation and does not suppress any command or
error information.

`command-substitution-adjacent` retains the native yellow outer-string layer
around adjacent substitutions. The substitutions remain structurally parsed;
the difference is presentation rather than lost shell meaning.

`parameter-expansion-untokenized1` retains a cyan `$x` parameter layer where
upstream marks the expansion as an unknown token. The following command is now
recovered through bounded scalar virtual expansion, so no command context is
lost.
