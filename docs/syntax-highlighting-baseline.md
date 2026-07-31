# Syntax highlighting baseline

This document records the reproducible Milestone 0 baseline used by the first
synchronous highlighter.

## Dependency provenance

| Component | Pinned source | Version and ABI | License |
| --- | --- | --- | --- |
| Zig bindings | `tree-sitter/zig-tree-sitter@c18983f9dee9acb63d816e79ada2eff186ed1ddf` | package 0.26.0 | MIT |
| Tree-sitter runtime | `tree-sitter/tree-sitter@24a64db7ccb7dff830789cf44ecfeaacf7fee822` | runtime 0.27.0, language ABI 13 through 15 | MIT |
| Zsh grammar | `georgeharker/tree-sitter-zsh@7a593401efb5418ffdedbe3c0e4c61c6d240166d` | grammar 0.63.4, generated language ABI 15 | MIT |
| Zsh | configured Zsh 5.9 headers and the loading process | private `region_highlight` ABI | custom Zsh license |

`build.zig.zon` pins the official Zig binding by commit and package hash. The
binding pins the runtime transitively. `scripts/prepare-tree-sitter-zsh.sh`
checks out the exact grammar commit, verifies that `parser.c` is unmodified,
preserves the exact upstream scanner as `scanner.upstream.c`, and rejects any
scanner change outside the ordered patch series.

The grammar's lockfile records Tree-sitter CLI 0.25.10 as the generator of the
committed parser. The unmodified scanner remains buildable as
`zigsh-highlight-parser-upstream` for differential safety tests.

## Narrow safety patch series

The interactive module applies three scanner-only patches:

1. `0001-bound-serialized-scanner-counts.patch` prevents 8-bit serialized
   counts from desynchronizing the scanner and clears the heredoc collection
   during reset. It covers the upstream scanner assertion reported in issues
   33 and 35 and follows the approach in pull request 36.
2. `0002-reject-empty-regex-without-slash.patch` prevents a zero-width
   `REGEX_NO_SLASH` token. It covers the non-terminating parse in issue 37 and
   the incremental growth case in pull request 44.
3. `0003-declare-scanner-create-void.patch` makes the scanner create function
   match the generated Tree-sitter prototype exactly. This avoids a
   `FunctionTypeMismatch` trap under `ReleaseSafe` undefined-behavior checks.

The exact upstream failure inputs live in `test/highlighting/adversarial/`.
`test/test-highlight-safety.zsh` runs both parsers in bounded subprocesses. It
rejects an unexpected successful upstream parse while accepting a timeout or
safety trap as optimization-dependent manifestations of the known defects, and
rejects every patched-parser failure.

The issue 37 loop occurs inside the external scanner and never returns control
to Tree-sitter's parser progress callback. It therefore cannot be made safe by
an in-process cancellation callback. Rejecting the zero-width token is required
before the grammar can run in ZLE.

## Ownership contracts

- The ZLE thread owns `zleline`, Zsh parameters, compiled `zattr` values, the
  shared redraw hook, and `region_highlights`.
- `Snapshot` copies the character-oriented ZLE line to module-owned UTF-8 and
  owns its byte-to-character boundary map.
- `Engine` exclusively owns its parser, query, cursor, previous source, and
  mutable syntax tree. It exposes immutable result spans.
- The Zsh 5.9 adapter preserves the four special regions and owns the complete
  non-special tail. Every native entry is initialized without constructing the
  public string representation.
- Worker ownership does not exist yet. No parser or Zsh state is accessed from
  another thread in Milestone 1.

Set `ZIGSH_SYNTAX_HIGHLIGHTING=off` before loading the module to leave the
highlighter disabled while keeping the other Zigsh features active.

## Standalone harness

The parser harness has no Zsh process dependency:

```console
zig build highlight-parse -- 'if true; then echo "$USER"; fi'
zig build highlight-tree -- 'if true; then echo "$USER"; fi'
zig build highlight-edits -- 'e' 'ec' 'echo $USER'
zig build highlight-benchmark -- 1000 'echo $USER'
zig build -Doptimize=ReleaseFast highlight-benchmark-suite -- 1000
```

The `parse` command reports parse, query, and composition timings plus capture
and final-region counts. `tree` also prints the syntax tree. `edits` applies a
sequence to one incremental engine. The benchmark suite covers ordinary,
nested, multiline, heredoc, incomplete, and Unicode commands, followed by
1 KiB, 10 KiB, and 100 KiB generated stress buffers.

## Initial benchmark

Recorded on 2026-07-31 with an Apple M4 Max Mac16,6, 16 logical CPUs, 64 GiB
RAM, macOS 26.5.1, Zig 0.16.0, Zsh 5.9, and `ReleaseFast`. Each edit alternates
between the source and the source plus one trailing byte. These figures cover
incremental parse, whole-tree query, and span composition; they do not include
ZLE snapshotting, native region installation, or terminal refresh.

| Corpus | Bytes | Iterations | Total p50 | Total p99 |
| --- | ---: | ---: | ---: | ---: |
| ordinary | 53 | 1,000 | 5 us | 8 us |
| nested | 86 | 1,000 | 8 us | 12 us |
| multiline | 113 | 1,000 | 8 us | 11 us |
| heredoc | 77 | 1,000 | 6 us | 8 us |
| incomplete | 51 | 1,000 | 19 us | 25 us |
| Unicode | 49 | 1,000 | 5 us | 5 us |
| stress | 1,050 | 500 | 73 us | 89 us |
| stress | 10,250 | 100 | 672 us | 756 us |
| stress | 102,400 | 10 | 6.655 ms | 6.810 ms |

The 100 KiB query is intentionally above the eventual synchronous ZLE budget.
It remains useful as a bounded parser baseline for the asynchronous milestone.
The initial capture ceiling is 65,536, which admits this corpus without making
capture growth unbounded.

## Validation surface

`zig build test` covers pure unit tests, the complete structural corpus,
incremental-versus-clean span equivalence, repeated incomplete edits, Unicode
offset conversion, both adversarial subprocesses, module setup and cleanup,
history behavior, the disabled feature gate, and a real interactive `zpty`
session. The PTY test types Unicode, reads the resulting native regions,
performs multiline bracketed paste and Backspace, and cycles module
unload/reload twenty times.

The per-keystroke prompt mutation from `dedb308` was removed before this branch
registered its shared redraw hook. A separate PTY regression verifies that line
editing does not redraw or mutate the prompt; syntax highlighting only updates
the native region array.
