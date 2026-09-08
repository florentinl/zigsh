# zigsh

A minimal native [Zsh module](https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html)
implemented in Zig.  Loading it will eventually cover everything...

- prompt (git is hard then easy but long and painful)
- syntax highlighting
- fzf like tab completion
- fzf like history searching
- auto completion hints ?

## Homebrew

Install the dedicated tap and formula:

```zsh
brew tap florentinl/zigsh https://github.com/florentinl/zigsh
brew install florentinl/zigsh/zigsh
```

Installing the formula only places the module and its opt-in loader on disk; it
does not load Zigsh, modify `~/.zshrc`, or otherwise initialize a shell. Add
this line to an interactive Zsh setup only when you want to enable it:

```zsh
source "$(brew --prefix zigsh)/zigsh.sh"
```

Remove that line (and restart the shell) to stop loading Zigsh. The loader is
also safe to source manually and does nothing when `zigsh` is already loaded.

New bottles are published from `main`; retrieve them with `brew update && brew
upgrade zigsh`.

## Command-aware prompt

- **Python** shows the active `VIRTUAL_ENV`. A `.venv` directory uses its parent
  project's name; other environments use their directory name.
- **Kubernetes** shows the configured current context and namespace while typing
  `kubectl` or `helm`, including command positions in pipelines and aliases.
  It requires `kubectl` on `PATH`, even when typing `helm`. The worker runs the
  local-only `kubectl config view -o json` command so YAML syntax and colon-separated
  `KUBECONFIG` merging follow Kubernetes semantics. It does not contact a cluster
  or run credential plugins. Command-line `--context`/`--namespace` overrides are
  not reflected; this segment describes the configured defaults.
- **AWS** currently shows a badge for `aws` or `aws-vault`, not an account/profile.

Argument text such as `echo kubectl` does not activate a segment. Command analysis
continues when `ZIGSH_SYNTAX_HIGHLIGHTING=0`; that setting disables colors only.

### Responsiveness and failure behavior

Prompt rendering reads shell-owned values and cached worker results only: it does
not run Git/kubectl, inspect files, or call `realpath`. Git metadata/status and
Kubernetes config loading run in separate worker processes from line analysis.
The initial prompt never waits for them; segments appear when results arrive.
Kubernetes is requested lazily once per prompt and refreshed after accepting a
command. Missing tools, invalid configs, and failed/timed-out jobs hide unavailable
data rather than blocking input. Git can briefly show cached data for the same
working directory while it refreshes.

Worker transport is bounded and nonblocking on the editor thread, including large
requests and partial responses. New prompts cancel obsolete work; cancellation
kills the read-only worker process group without waiting for child exit in ZLE.
Workers have hard execution limits (30 seconds for Git, 5 seconds otherwise).
Oversized or failed line analysis is skipped for that snapshot and retried when
input changes, so it cannot create a redraw/retry loop.

Run `zig build test` for unit and PTY integration tests. The latter cover stalled
providers, large analysis replies, cancellation, and unload. Real kubeconfig
YAML/merge checks run when `kubectl` is installed; deterministic provider tests do
not require it.
