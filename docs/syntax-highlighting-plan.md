# Native Zsh syntax highlighting plan

Status: Milestones 0 and 1 implemented; Milestones 2 through 4 remain planned

The dependency, safety, ownership, validation, and performance record for the
implemented synchronous pipeline is in
[`syntax-highlighting-baseline.md`](syntax-highlighting-baseline.md).

Target baseline:

- Zig 0.16
- Zsh 5.9 private module and ZLE APIs
- `tree-sitter/zig-tree-sitter`
- `georgeharker/tree-sitter-zsh`

## Summary

Build a native Zigsh syntax highlighter that combines incremental Tree-sitter
parsing with direct access to the live Zsh runtime. The syntax engine provides
structural understanding; a Zsh-aware semantic layer resolves aliases,
functions, builtins, commands, options, paths, and other runtime-dependent
meanings. Final highlights are installed directly as Zsh
`struct region_highlight` entries without constructing the public string
representation.

The intended end state is:

- Better structural accuracy than token/state-machine highlighters, especially
  for nested and incomplete Zsh input.
- Semantic coverage at least comparable to the `main` highlighter in
  `zsh-syntax-highlighting`.
- A synchronous fast path for ordinary command lines.
- A latest-result-only asynchronous path for work that exceeds the ZLE latency
  budget.
- No Zsh allocation, API, or global-state access from worker threads.
- Crash-safe, bounded parsing of incomplete and adversarial input.

## Recommended milestone order

The proposed order is fundamentally correct:

1. Synchronous Tree-sitter pipeline.
2. Zsh-aware semantic pipeline.
3. Asynchronous fallback with a time budget.
4. Grammar hardening and upstreaming.

Two refinements are required:

1. Add a Milestone 0 for architecture contracts, measurement, and isolated
   grammar-safety reproduction.
2. Split grammar hardening into:
   - A narrow, early safety gate for known hangs, assertions, and memory-safety
     problems before interactive use is enabled by default.
   - Broader correctness, coverage, fuzzing, and upstream work in Milestone 4.

The unmodified `tree-sitter-zsh` grammar remains the first integration target.
If its known hangs or scanner assertions reproduce, that exact version may run
only in a test subprocess or explicit developer mode. An asynchronous thread
does not isolate Zsh from a parser abort, memory corruption, or a worker that
cannot terminate.

Semantics should precede concurrency. This gives the asynchronous design a
realistic workload and measured budget instead of optimizing a syntax-only
prototype whose cost profile will change later.

## Goals

### Functional goals

- Incrementally parse the current ZLE buffer after edits.
- Highlight valid, incomplete, and temporarily invalid Zsh input.
- Understand Zsh-specific syntax, including nested substitutions, parameter
  expansion, arithmetic, redirections, compound commands, and globbing.
- Resolve live Zsh semantics:
  - Regular, global, and suffix aliases.
  - Reserved words and precommand modifiers.
  - Shell functions, including disabled and autoloaded functions.
  - Builtins, including disabled builtins.
  - Hashed commands, external commands, and unknown commands.
  - `PATH`, `PATH_DIRS`, `AUTO_CD`, `CDPATH`, named directories, and executable
    paths.
  - Shell options that affect parsing or interpretation.
  - Safe parameter, tilde, and equals expansion where needed for path
    classification.
- Apply native `zattr` values directly to Zsh-owned highlight regions.
- Support safe setup, unload, reload, fork, and interactive-shell lifecycle.

### Performance goals

- Keep ordinary edits on a synchronous path when the complete parse, query,
  semantic resolution, and region application fit within the ZLE budget.
- Never wait for stale work.
- Coalesce worker input so only the newest unpublished generation is parsed.
- Avoid reparsing or re-resolving unchanged work where correctness permits.
- Avoid shell evaluation, forks, public parameter materialization, highlight
  strings, and style parsing on the per-keystroke hot path.
- Bound capture counts, region counts, parser work, query work, filesystem work,
  and retained memory.

### Quality goals

- Establish a differential compatibility suite against
  `zsh-syntax-highlighting` for semantic categories.
- Establish a Zsh grammar corpus containing complete, incomplete, malformed,
  and option-dependent input.
- Make every crash, assertion, hang, and unbounded-growth reproducer a permanent
  regression test.
- Keep grammar changes suitable for upstream review whenever practical.

## Non-goals for the first release

- Supporting arbitrary Zsh versions through one private-ABI build.
- Calling Zsh internals from a worker thread.
- Using Zsh's global lexer or parser concurrently or as an in-process dry-run
  evaluator.
- Executing or evaluating the command buffer to determine highlighting.
- Perfectly composing the non-special highlight tail with arbitrary third-party
  highlighters.
- Guaranteeing that filesystem-dependent highlighting is instantly current on
  slow or unavailable network filesystems.
- Treating Tree-sitter parse recovery as proof that a command will execute
  successfully.

The first supported configuration should be one Zigsh highlighter owning all
non-special highlight regions. Zsh's reserved selection, search, suffix, and
paste regions remain Zsh-owned.

## Architecture

### Components

The implementation should be separated into pure parsing logic, Zsh adapters,
and orchestration:

```text
ZLE hook dispatcher
  -> buffer snapshot and generation
  -> syntax engine
       -> Tree-sitter parser/tree
       -> query/capture normalization
  -> semantic resolver
       -> live Zsh tables and options
       -> cached filesystem resolver
  -> span compositor
  -> Zsh 5.9 region adapter
  -> redisplay

Long or over-budget work:

ZLE thread
  -> immutable job in latest-job slot
  -> wake pipe
  -> worker-owned parser/tree/query and filesystem state
  -> immutable result in latest-result slot
  -> completion pipe
  -> ZLE FD callback validates and applies result
```

### Proposed source layout

The exact names may evolve, but ownership should remain explicit:

```text
src/
  highlight/
    mod.zig                 feature lifecycle and orchestration
    snapshot.zig            UTF-8 snapshot and offset mapping
    syntax.zig              parser/tree ownership and incremental edits
    queries.zig             query loading and capture normalization
    spans.zig               precedence, clipping, merging, and limits
    semantics.zig           pure semantic classification coordinator
    semantic_cache.zig      positive/negative caches and invalidation
    worker.zig              latest-only worker protocol
    protocol.zig            immutable job/result types and generations
    styles.zig              capture/style IDs and compiled zattr table
    zsh_state.zig           main-thread views of Zsh runtime state
    zsh59_regions.zig       private region_highlight ABI adapter
    zsh59_fd_watch.zig      private watched-FD adapter, if required
  zle_hooks.zig             one native owner for shared ZLE hooks

queries/
  zsh/highlights.scm

test/
  highlighting/
    corpus/
    expected/
    differential/
    adversarial/

bench/
  highlighting/

patches/tree-sitter-zsh/    optional upstreamable patch series
```

### Thread ownership

The ZLE thread exclusively owns:

- All Zsh globals, tables, options, allocators, widgets, and ZLE APIs.
- The live `region_highlights` array.
- Snapshotting `zleline` and the live semantic state.
- Registration and removal of hooks and watched file descriptors.
- Validation and application of completed worker results.

The worker exclusively owns:

- Its parser, old tree, query cursor, and parser-side source snapshot.
- Worker allocations and immutable output spans.
- Filesystem work based only on immutable snapshots.
- No borrowed pointer into Zsh-owned storage.

No parser, mutable tree, query cursor, allocator state, or job payload may be
used concurrently by both owners.

### Buffer and offset model

ZLE exposes character-oriented offsets while Tree-sitter exposes UTF-8 byte
offsets. Every buffer snapshot must therefore contain:

```text
generation
semantic_epoch
owner_pid
UTF-8 source bytes
UTF-8 byte -> ZLE character offset map
source fingerprint
```

The source given to Tree-sitter must be a module-owned UTF-8 encoding of
`zleline`, not Zsh's metafied public string representation. Tests must cover
ASCII, combining characters, wide characters, emoji, invalid/incomplete input,
and multiline buffers.

### Highlight span model

Internal spans should be allocation-light and independent of display strings:

```zig
const HighlightSpan = struct {
    start_byte: u32,
    end_byte: u32,
    style_id: StyleId,
    layer: Layer,
    priority: u16,
};
```

The compositor must:

- Resolve overlaps deterministically.
- Define precedence between syntax, semantic, error, bracket, and user layers.
- Clip spans to the current source.
- Convert bytes to ZLE character offsets once.
- Merge adjacent regions with identical attributes.
- Drop zero-width and redundant regions.
- Enforce configurable hard limits.

### Direct Zsh region ownership

The Zsh 5.9 adapter must:

- Preserve the first `N_SPECIAL_HIGHLIGHTS` entries.
- Run only on the ZLE thread.
- Use Zsh allocation and reallocation for Zsh-owned arrays.
- Free existing memo fields with Zsh's corresponding routine.
- Initialize every field, including meta offsets, flags, and memo pointers.
- Compile configured style strings to `zattr` outside the per-edit hot path.
- Reject incompatible runtime Zsh versions before enabling the feature.
- Assert expected structure sizes and offsets at build time where possible.
- Restore or clear Zigsh-owned regions during cleanup.

The version-sensitive code must remain isolated from the parser and semantic
engine so future Zsh adapters do not fork the entire feature.

### ZLE hook ownership

Zigsh currently has more than one feature that may need `zle-line-pre-redraw`.
Introduce one native hook dispatcher before syntax highlighting takes ownership
of the hook. The dispatcher should:

- Register the special widget once.
- Call feature callbacks in a documented order.
- Allow feature setup failure to roll back only that feature.
- Prevent a prompt or highlighting feature from silently replacing another.
- Remove the hook only after all consumers are detached.

## Milestone 0: contracts, safety harness, and baseline

### Purpose

Establish boundaries and measurements before the parser is connected to an
interactive shell.

### M0.1: dependency and provenance decisions

- Pin an exact `zig-tree-sitter` version and dependency hash.
- Pin the exact `tree-sitter-zsh` commit used by the first prototype.
- Record grammar ABI/language version and generated-parser provenance.
- Verify dependency licenses and redistribution requirements.
- Decide how the grammar is consumed:
  - Exact upstream checkout plus repository-owned patch series, or
  - A Zigsh fork pinned to a commit.
- Ensure the build is reproducible without silently tracking a moving branch.

Recommended approach: retain an exact upstream baseline and a small ordered
patch series. This makes the unmodified baseline testable and each safety or
grammar fix independently upstreamable.

### M0.2: pure parser harness

- Build a standalone parser executable or test binary with no Zsh process
  state.
- Support one-shot parsing, repeated incremental edits, query execution, and
  parse-tree diagnostics.
- Add a subprocess timeout wrapper so known hangs cannot block the test suite.
- Make crashes, signals, timeout, excessive memory, and query-limit exhaustion
  distinct test failures.
- Record parser and query timings separately.

### M0.3: known-risk reproduction

- Reproduce or close each currently known parser hang and scanner assertion.
- Add the exact input to `test/highlighting/adversarial/`.
- Determine whether Tree-sitter cancellation can interrupt each hang.
- Classify every issue as:
  - Safe to defer for a developer-only prototype.
  - Must fix before any in-process ZLE integration.
  - Must isolate in a subprocess if no immediate fix exists.

### M0.4: baseline corpus and benchmark

Create representative input groups:

- 20-100 byte ordinary commands.
- 100-500 byte nested commands.
- 1 KiB, 10 KiB, and 100 KiB stress buffers.
- Repeated single-character insertion and deletion.
- Cursor edits at the start, middle, and end.
- Multiline functions, loops, conditionals, and here-documents.
- Incomplete quotes, substitutions, arrays, braces, and redirections.
- Unicode before and inside highlighted ranges.
- Known grammar adversarial inputs.

Capture:

- Full parse time.
- Incremental edit plus parse time.
- Query time.
- Capture and final region counts.
- Peak and retained memory.

### M0.5: lifecycle and feature gate

- Add a syntax-highlighting feature flag that defaults off during the unsafe
  prototype stage.
- Define setup and cleanup as idempotent state transitions.
- Introduce the shared ZLE hook dispatcher.
- Define the parser/semantic/region APIs so synchronous and asynchronous
  execution use the same result types.

### Milestone 0 exit criteria

- Exact dependencies and licenses are recorded.
- The parser harness can reproduce known failures without wedging the test run.
- The baseline corpus and timing output are checked in.
- ZLE, parser, semantic, and allocator ownership contracts are documented in
  code-facing interfaces.
- No unsafe grammar is enabled by default in an interactive shell.

## Milestone 1: basic synchronous Tree-sitter pipeline

### Purpose

Produce the smallest end-to-end pipeline from ZLE buffer to native highlight
regions using the pinned, initially unmodified Zsh grammar.

### M1.1: build integration

- Add `zig-tree-sitter` to `build.zig.zon` at an exact revision/version.
- Compile and link the pinned Zsh parser and external scanner.
- Verify Tree-sitter language ABI compatibility at startup.
- Keep grammar build logic separate from Zsh header preparation.
- Add explicit build failures for missing or mismatched generated parser files.

### M1.2: snapshot and incremental edit calculation

- Snapshot `zleline` into module-owned UTF-8 storage.
- Build the byte-to-ZLE-character mapping in the same pass.
- Retain the previous source owned by the synchronous parser.
- Compute a single replacement edit with longest common prefix/suffix.
- Convert that edit into a Tree-sitter `InputEdit` with correct byte and point
  positions.
- Call `Tree.edit()` before parsing with the old tree.
- Fall back to a full parse if edit validation fails.

The first implementation may query the full new tree after every parse. Changed
range query invalidation should not be introduced until tests prove it preserves
context-dependent highlights.

### M1.3: minimal structural query

Start with a small query owned by Zigsh rather than copying an editor-specific
query with unsupported predicates. Cover:

- Comments.
- Strings and quote delimiters.
- Command names.
- Operators and command separators.
- Redirections.
- Variables and parameter expansions.
- Command, process, and arithmetic substitution delimiters.
- Keywords and function definitions.
- Obvious parse errors.

Normalize query captures immediately to Zigsh `StyleId` values. Enforce match,
capture, span, and nesting limits.

### M1.4: direct region adapter

- Compile a minimal fixed theme into native `zattr` values.
- Convert captures to ZLE offsets.
- Preserve Zsh's special highlight prefix.
- Install a sorted, merged non-special tail directly.
- Force redisplay through the native ZLE API.
- Provide a test-only inspection path for deterministic region assertions; do
  not add string serialization to the production hot path.

### M1.5: synchronous ZLE integration

- Run from the shared `zle-line-pre-redraw` dispatcher.
- Skip unsupported ZLE contexts such as `select` or `vared` initially.
- Prevent recursion when highlight application requests redisplay.
- Detect unchanged buffer/style/semantic generations and avoid redundant work.
- On parser or query failure, retain no misleading new regions and keep ZLE
  usable.

### M1.6: narrow grammar safety gate

The first unmodified-grammar result is a development milestone, not necessarily
an interactive-release milestone.

Before enabling it by default:

- Fix or prove unreachable every known in-process assertion.
- Fix or bound known non-terminating parses.
- Run the adversarial corpus under sanitizers where supported.
- Verify parser cancellation and teardown.
- Confirm repeated load, edit, unload, and reload do not leak or retain callbacks.

Keep the fixes narrowly separated from broader grammar improvements so the
unmodified baseline remains measurable.

### Milestone 1 exit criteria

- A normal interactive buffer is parsed incrementally and highlighted through
  direct native regions.
- Unicode offsets and multiline buffers are correct.
- Structural tests cover valid, incomplete, and invalid input.
- Direct-region ownership survives repeated redraw and module unload.
- Typical parse/query/apply latency is recorded, not inferred.
- The unmodified baseline is preserved in tests.
- Default interactive enablement occurs only after the narrow safety gate is
  green.

## Milestone 2: Zsh-aware semantic pipeline

### Purpose

Match or exceed the semantic categories of `zsh-syntax-highlighting` while
using live Zsh state directly and preserving a bounded ZLE hot path.

### M2.1: semantic precedence specification

Write executable table-driven tests for command-position precedence:

1. Alias eligibility and alias kind.
2. Reserved-word context.
3. Shell function, including disabled/autoload state.
4. Builtin, including disabled state.
5. Hashed command.
6. External executable discovered through `PATH`/`PATH_DIRS`.
7. `AUTO_CD` directory resolution.
8. Unknown command.

Use actual Zsh source behavior as the ownership oracle. Do not assume that a
`cmdnamtab` miss means an unknown command because the command table is lazy.

### M2.2: main-thread Zsh state adapter

Expose read-only operations over:

- `aliastab` and `sufaliastab`.
- `reswdtab`.
- `shfunctab`.
- `builtintab`.
- `cmdnamtab` and `pathchecked`.
- `paramtab` and named-directory state where safe.
- `opts`, `path`, `cdpath`, `pwd`, and relevant shell generations.

Rules:

- All operations run on the ZLE thread.
- Returned values are copied before leaving the callback.
- Disabled/autoload/global/suffix/hashed flags are interpreted explicitly.
- Helpers that allocate or mutate Zsh state are documented as such.
- Expensive table filling or PATH scanning never happens accidentally inside a
  supposedly constant-time lookup.

### M2.3: command classification

- Classify reserved words, functions, builtins, hashed commands, external
  commands, and unknown commands.
- Model Zsh command-position context from Tree-sitter nodes rather than a second
  whole-buffer ad hoc lexer.
- Support precommand modifiers and their option arguments.
- Distinguish direct paths from names requiring PATH lookup.
- Respect relevant options such as `PATH_DIRS`, `HASH_CMDS`,
  `HASH_EXECUTABLES_ONLY`, and `AUTO_CD`.
- Avoid mutating Zsh's command hash merely for painting unless matching Zsh's
  behavior requires it and the side effect is explicitly accepted.

### M2.4: alias expansion and source mapping

Alias handling is a semantic parse transformation, not just command coloring.
Implement:

- Regular, global, and suffix aliases.
- Disabled aliases.
- Alias eligibility by lexical/command context.
- Recursive expansion with cycle detection and a depth/size limit.
- Trailing-space behavior that enables expansion of the following word.
- Expansions that introduce separators, redirections, assignments, or command
  words.
- Mapping from virtual expanded input back to original buffer ranges.

Recommended staged approach:

1. Classify and color the alias token itself.
2. Construct a bounded virtual token/source stream for aliases that affect
   downstream structure.
3. Reparse only that virtual representation when necessary.
4. Project semantic results back to the original alias token and downstream
   source ranges.

Do not call Zsh's global lexer/parser reentrantly from the worker. If exact
behavior cannot be reproduced safely for a case, classify it conservatively and
add a differential fixture.

### M2.5: paths, executability, and directory semantics

Implement synchronous correctness first, with instrumentation around every
filesystem operation:

- Existing file, directory, symlink, and executable classification.
- Command-position executable requirements.
- `PATH` and `PATH_DIRS` resolution.
- `AUTO_CD` and `CDPATH` resolution.
- Named directories and safe tilde expansion.
- Safe simple parameter expansion used in path positions.
- Equals-command expansion when enabled.
- Path-prefix highlighting for the word being edited.
- Configurable path blacklists for slow or unsafe directory trees.

Avoid expanding arbitrary special parameters or running user code. Match the
safe subset of `zsh-syntax-highlighting` first, then widen it only with explicit
tests.

### M2.6: semantic cache and invalidation

Cache at least:

- Command type by command name and alias-eligibility mode.
- Positive and negative PATH resolution.
- Path metadata and prefix existence.
- CDPATH directory resolution.
- Compiled styles.

Cache keys or epochs must include the relevant state:

- `PATH`, `CDPATH`, `PWD`, and effective process identity.
- Alias/function/builtin/command-table changes.
- Relevant option bits.
- Style configuration.

If Zsh provides no reliable mutation generation for a table, begin with safe
invalidation at `precmd`, explicit Zigsh configuration changes, and detected
pointer/value changes. Measure before adding complex hooks.

### M2.7: differential compatibility suite

Run the same buffers in controlled interactive Zsh instances with:

- Zigsh highlighting.
- `zsh-syntax-highlighting` main highlighter.

Normalize both results to semantic style categories rather than terminal colors.
Cover:

- Alias/function/builtin/command precedence.
- Global and suffix aliases.
- Unknown commands.
- Precommands and option arguments.
- `AUTO_CD`, `CDPATH`, and path prefixes.
- Executable and non-executable paths.
- Option-dependent parsing and expansion.
- Nested command substitutions and incomplete input.

Differences must be classified as intentional improvement, unsupported case, or
bug. Intentional differences need dedicated expected fixtures.

### Milestone 2 exit criteria

- Direct-table categories match live Zsh precedence tests.
- Alias expansion changes downstream highlighting correctly for the supported
  bounded cases.
- External, unknown, executable, path-prefix, `AUTO_CD`, and `CDPATH` behavior
  have deterministic tests.
- Semantic caches have explicit invalidation tests.
- Differential coverage is reported by category.
- Per-stage timings identify whether parsing, semantic lookup, filesystem work,
  composition, or Zsh refresh dominates.

## Milestone 3: asynchronous worker and time budget

### Purpose

Preserve synchronous immediacy for ordinary input while preventing long,
pathological, or filesystem-heavy work from blocking ZLE.

### M3.1: budget policy

Start with observable inputs and refine from measurements:

- Source byte length.
- Changed byte count.
- Previous parse/query/semantic duration.
- Previous capture and region counts.
- Presence of an uncached filesystem lookup.
- Recent cancellation or parser-limit exhaustion.

Use a deadline-aware synchronous attempt rather than only a fixed length
threshold. A provisional target is:

- Typical buffers complete synchronously below 1 ms.
- No intentional ZLE-thread work exceeds 2 ms.
- Longer work is cancelled or deferred.

These values are initial engineering budgets, not performance claims. Tune them
using key-to-redraw measurements on documented hardware.

The synchronous and worker paths must keep independent parser and tree state.
Cancelling a synchronous parse leaves its last completed tree intact; either
owner can later catch up to the newest source with one validated replacement
edit. Do not transfer a mutable tree between paths to save memory.

Only start deadline-bounded work on the synchronous path. In particular, an
uncached directory scan, path-prefix glob, or network-filesystem lookup should
be deferred before it begins rather than discovered to be over budget after it
has already blocked ZLE.

### M3.2: latest-only protocol

Use immutable generations and bounded storage:

```text
pending_job: atomic latest pointer/slot
published_result: atomic latest pointer/slot
main_to_worker_pipe: wake signal only
worker_to_zle_pipe: completion signal only
```

- Publishing a job replaces and frees an older unpublished job safely.
- Publishing a result replaces and frees an older unapplied result safely.
- Pipes are nonblocking on the publishing side.
- A full pipe is not an error: an unread byte already means inspect the slot.
- The receiver drains the pipe before taking the newest slot.
- Every payload carries buffer generation, semantic epoch, PID, and source
  fingerprint.
- Backpressure is constant-space; there is no unbounded queue of keystrokes.

Zig's queue primitives may be evaluated, but the selected mechanism must fit
ZLE's FD wake-up model and have an auditable shutdown/fork story.

### M3.3: worker-owned incremental engine

- Give the worker its own parser, tree, query cursor, previous source, and
  allocator state.
- Compute the edit from the worker's last completed source directly to the
  newest job; skipped generations need not be replayed.
- Check for a newer generation from Tree-sitter's progress callback.
- Abort query or semantic work when limits or staleness are detected.
- Perform only snapshot-safe semantic work in the worker.
- Return captures/style IDs, never Zsh pointers or `zattr` values tied to live
  mutable configuration.

### M3.4: FD completion callback

- Register a native ZLE FD widget or isolated Zsh 5.9 watched-FD adapter.
- Drain the completion pipe.
- Atomically take the newest result.
- Reject results whose generation, semantic epoch, PID, or source fingerprint
  differs from the live buffer.
- Perform current-state direct Zsh lookups that cannot safely be snapshotted.
- Map offsets, compose spans, apply native regions, and request redisplay.
- Prevent a completion redisplay from publishing duplicate work.

### M3.5: fork and unload lifecycle

Define and test these states:

```text
disabled -> starting -> running -> stopping -> disabled
                         |
                         +-> invalid-after-fork -> starting
```

- Record the owner PID.
- Ensure a child never locks, joins, or signals a vanished inherited worker.
- Close or invalidate inherited pipe endpoints in the child where safe.
- Lazily create new worker state if an interactive child re-enters ZLE.
- During cleanup:
  1. Stop new hook jobs.
  2. Unregister the completion FD.
  3. Publish stop and wake the worker.
  4. Join the worker.
  5. Close descriptors.
  6. Free pending jobs/results and parser state.
  7. Remove widgets/hooks.
- Never unload module code while a worker or FD callback can execute it.

### M3.6: race and stress tests

- Type faster than parsing completes.
- Alternate large and small buffers.
- Change aliases, functions, options, `PWD`, and `PATH` while work is pending.
- Deliver completion and terminal input in either order.
- Repeatedly load/unload while idle and after queued work.
- Exercise subshells, forks, jobs, and interrupted ZLE sessions.
- Force pipe saturation and allocator failures.
- Run ThreadSanitizer or an equivalent race detector where the Zig/C toolchain
  supports it.

### Milestone 3 exit criteria

- Normal buffers retain same-frame synchronous highlighting under the budget.
- Over-budget work does not block input.
- Only an exact-current result is ever applied.
- Job/result memory remains bounded during sustained typing.
- Fork and unload stress tests have no deadlock, use-after-free, callback-after-
  unload, or descriptor leak.
- Key-to-redraw latency and CPU usage are benchmarked against the synchronous
  implementation and established Zsh highlighters.

## Milestone 4: grammar quality, hardening, and upstreaming

### Purpose

Turn the safety-patched grammar into a well-specified Zsh grammar suitable for
long-term incremental editor use and reduce the Zigsh-specific fork.

This milestone begins after Milestone 0 and continues throughout development;
it is listed last because broad grammar completeness should not block learning
from the end-to-end pipeline.

### M4.1: Zsh construct inventory

Build a coverage matrix for at least:

- Simple commands, assignments, redirections, pipelines, and lists.
- Functions, anonymous functions, autoload forms, and `always` blocks.
- `if`, loops, `case`, `select`, `repeat`, `coproc`, and `time`.
- Single, double, dollar, backtick, and RC-style quoting.
- Parameter expansion flags, modifiers, nested substitutions, arrays, and
  associative subscripts.
- Arithmetic commands, conditions, and substitutions.
- Process substitution and equals substitution.
- Here-documents and here-strings.
- Extended globbing, exclusions, approximate matching, and glob qualifiers.
- History expansion and interactive comments.
- Zsh option-dependent token meanings.
- Incomplete forms for every construct.

For each entry record:

- Grammar support.
- Incremental edit stability.
- Query capture coverage.
- Known ambiguity or recovery behavior.
- Corpus and highlighting fixtures.

### M4.2: differential grammar tests

- Compare complete-input acceptance with `zsh -n` in controlled option sets.
- Do not require Tree-sitter and Zsh to reject incomplete input identically;
  record expected recovery behavior instead.
- Minimize every disagreement before deciding whether it is a grammar bug,
  option mismatch, or intentional recovery extension.
- Add edit-sequence tests, not only final-source tests, to catch incremental tree
  reuse errors.
- Verify changed ranges and final trees against full reparses.

### M4.3: fuzzing and resource bounds

- Run grammar-aware mutation of corpus inputs.
- Run random byte/edit-sequence fuzzing through parse, edit, reparse, and query.
- Seed with known Bash and Zsh parser edge cases.
- Exercise external-scanner serialization/deserialization at all buffer sizes.
- Compare incremental final trees with clean full parses where meaningful.
- Enforce time, memory, depth, and capture limits in the harness.
- Run AddressSanitizer, UndefinedBehaviorSanitizer, and leak checks for the C
  parser/scanner where supported.
- Preserve minimized crashes, hangs, and assertion inputs permanently.

### M4.4: upstream patch discipline

- Keep safety fixes separate from feature additions.
- Include standalone corpus tests with every grammar patch.
- Avoid Zigsh-specific capture names or runtime assumptions in grammar changes.
- Submit focused upstream pull requests when the behavior is independently
  useful.
- Track upstream issue/PR links and the exact local patch that corresponds to
  each submission.
- Regularly test the Zigsh query and harness against the upstream grammar head
  without silently changing the pinned production revision.
- Drop local patches promptly after an upstream release containing them is
  pinned and validated.

### M4.5: compatibility and release gate

- Define the supported Zsh build/runtime matrix.
- Validate at least macOS and Linux on Zsh 5.9 before the first release claim.
- Fail closed when the private Zsh ABI does not match.
- Publish grammar commit, Tree-sitter versions, query version, and ABI adapter
  version in diagnostic output.
- Document feature flags and recovery behavior when highlighting is disabled.

### Milestone 4 exit criteria

- No known parser crash, assertion, hang, or unbounded-memory input remains.
- The supported construct matrix has explicit status and fixtures.
- Incremental and clean parses agree for the defined comparable corpus.
- Fuzzing runs continuously with reproducible seeds and retained regressions.
- Local grammar changes are either upstreamed, submitted, or documented with a
  concrete reason for remaining downstream.
- Cross-platform interactive and lifecycle validation is green for the declared
  support matrix.

## Cross-cutting test strategy

### Unit tests

- UTF-8 snapshot and offset conversion.
- Longest-prefix/suffix edit construction.
- Tree edit point calculation.
- Capture normalization and span precedence.
- Adjacent-region merging and hard limits.
- Command-resolution precedence.
- Cache keys and invalidation.
- Generation and atomic-slot ownership.
- Lifecycle state transitions.

### Grammar and query tests

- Complete and incomplete corpus cases.
- Incremental edit sequences.
- Full-parse versus incremental-parse final tree comparison.
- Capture snapshots expressed in semantic style IDs.
- Adversarial timeout and crash subprocesses.

### Zsh integration tests

- Module dependency and load order.
- Native hook registration and coexistence with the prompt feature.
- Direct region layout and preservation of special regions.
- Interactive redraw through `zpty` or a PTY harness.
- Option, alias, function, command-hash, `PWD`, `PATH`, and `CDPATH` changes.
- Module unload/reload and fork behavior.

Static `zle -l` checks are not sufficient for native internal widgets. Exercise
the callbacks in a real interactive ZLE session.

### Differential tests

- `zsh-syntax-highlighting` semantic categories.
- `zsh -n` complete-input syntax acceptance under controlled options.
- Full parse versus incremental parse.
- Synchronous result versus asynchronous result for the same state snapshot.

### Performance tests

Measure at least:

- Key event to completed redraw.
- Snapshot and encoding.
- Edit construction.
- Parse.
- Query.
- Semantic direct-table resolution.
- Filesystem resolution.
- Span composition.
- Region installation.
- Zsh refresh.
- Worker publication/wake/application overhead.

Report distributions, not only means. Record hardware, OS, Zsh build, Zig
optimization mode, buffer corpus, cache state, and whether the result was sync
or async.

## Initial performance gates

These are provisional targets to validate or revise after Milestone 0:

- For representative buffers up to 512 UTF-8 bytes with warm semantic caches:
  - Parse/query/semantic/apply p50 at or below 0.5 ms.
  - p99 at or below 1 ms on the reference development machine.
- No intentional synchronous highlighter step above 2 ms.
- No stale asynchronous result applied, even transiently.
- Memory remains bounded under an hour of continuous edit-generation stress.
- Region count grows with meaningful styled ranges, not with every syntax node.
- Zigsh key-to-redraw latency is measured against:
  - No highlighter.
  - `zsh-syntax-highlighting`.
  - Another native/background highlighter where reproducible.

The project should claim state-of-the-art speed only after end-to-end PTY
measurements show it, not from parser microbenchmarks alone.

## Main risks and mitigations

### Grammar crashes or hangs kill the interactive shell

Mitigation: subprocess harness, early safety gate, cancellation tests,
sanitizers, fuzzing, and default-off developer integration until safe.

### Raw Tree-sitter input does not reflect alias-expanded Zsh syntax

Mitigation: bounded alias-aware virtual source/token mapping and differential
fixtures; never pretend command classification alone solves alias semantics.

### Private Zsh ABI changes

Mitigation: version-specific adapters, structure assertions, runtime guards,
and fail-closed feature setup.

### Filesystem work dominates parsing

Mitigation: positive/negative caches, precise invalidation, path blacklists,
latest-only worker execution, and per-stage timing.

### Worker observes or mutates unsafe Zsh state

Mitigation: immutable snapshots, strict ownership interfaces, no Zsh pointers in
jobs/results, semantic epochs, and apply-time validation.

### Zsh refresh dominates after direct region installation

Mitigation: merge spans, bound region counts, avoid redundant application, and
measure Zsh refresh separately.

### Multiple Zigsh features compete for ZLE hooks

Mitigation: one native hook dispatcher with explicit feature registration and
cleanup order.

### Cache staleness causes wrong semantic colors

Mitigation: conservative invalidation first, explicit state epochs, stale-result
rejection, differential tests, and observable diagnostics.

## Open design decisions

Resolve these with small prototypes or measurements rather than preference:

- Grammar distribution: patch series over upstream checkout versus maintained
  fork.
- Query invalidation: whole-tree query versus changed-range expansion.
- Alias expansion representation and source-map granularity.
- Whether uncached command discovery may update Zsh's own `cmdnamtab`.
- Worker synchronization primitive after lifecycle testing.
- Native watched-FD adapter versus a one-time public `zle -F` registration.
- Configuration compatibility with `ZSH_HIGHLIGHT_STYLES`.
- Coexistence policy with other highlighters.
- First supported Zsh versions beyond the 5.9 baseline.

## Suggested delivery slices

Each slice should be independently reviewable and leave tests green:

1. Parser dependency and standalone harness.
2. Corpus, incremental edit model, and timing output.
3. Shared ZLE hook dispatcher.
4. Snapshot/offset mapping and synchronous parser engine.
5. Minimal query and pure span compositor.
6. Zsh 5.9 direct-region adapter behind a feature flag.
7. Critical grammar safety fixes and regression fixtures.
8. Direct semantic table adapter and command precedence.
9. Alias classification, then alias expansion/source mapping.
10. Path, executability, `AUTO_CD`, and `CDPATH` correctness.
11. Semantic caches and differential oracle.
12. Latest-only worker protocol and FD wake-up.
13. Budget/cancellation policy and async filesystem work.
14. Fork/unload/race hardening.
15. Broad grammar corpus, fuzzing, and upstream patch series.
16. Cross-platform benchmark and release gate.

## Definition of done

The feature is ready to be described as a production-quality native Zsh
highlighter when:

- It provides structural and semantic highlighting for the declared Zsh
  construct matrix.
- Semantic categories meet the documented differential target against
  `zsh-syntax-highlighting`.
- The supported grammar has no known crash, assertion, hang, or unbounded
  resource input.
- Normal buffers are highlighted synchronously within the measured budget.
- Long or expensive work is asynchronous, bounded, cancellable, and never stale
  when applied.
- Worker, fork, ZLE FD, unload, and region ownership tests are green.
- Unicode and multiline offset mapping is correct.
- The private ABI fails closed outside its declared support matrix.
- End-to-end benchmarks substantiate the performance claims.
- Downstream grammar changes have an explicit upstream or maintenance status.

## References

- [zig-tree-sitter](https://github.com/tree-sitter/zig-tree-sitter)
- [Tree-sitter incremental parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html)
- [tree-sitter-zsh](https://github.com/georgeharker/tree-sitter-zsh)
- [zsh-syntax-highlighting main highlighter](https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/highlighters/main/main-highlighter.zsh)
- [zsh-syntax-highlighting main styles](https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/docs/highlighters/main.md)
- [Zsh Line Editor documentation](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html)
