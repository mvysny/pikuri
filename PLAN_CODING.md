# PLAN_CODING.md

Plan for growing pikuri into a coding agent — a second binary
`bin/pikuri-code` alongside the existing `bin/pikuri-chat`. This file is the
session-spanning index: each numbered step is a separate brainstorming
session, this doc is the map that future-Claude reads cold to find its
bearings.

This is a planning artifact, not a permanent part of the codebase. Delete
when implementation is complete.

## Orientation for fresh Claude

- **Read first.** `CLAUDE.md` (project conventions), `COMPARISON.md`
  (where each design choice came from), `lib/tool.rb`, `lib/tool/sub_agent.rb`,
  `lib/agent.rb`, `bin/pikuri-chat`. These are the load-bearing files for
  this work.
- **The seam principle.** All `RubyLLM::*` references stay in three files
  (`bin/pikuri-chat`, `lib/agent.rb`, `lib/tool.rb`). New coding tools
  must obey this — they speak `Tool.new` + `Tool::Parameters`, nothing
  else. `bin/pikuri-code` becomes the fourth seam file.
- **Tool ergonomics.** Existing tools are exported as `ALL_CAPS`
  constants (`Tool::CALCULATOR`, `Tool::FETCH`, …). Tools that need
  per-invocation wiring (sub-agent needs the parent; bash needs a
  confirmer) ship as a `Tool` subclass instantiated by the caller —
  see `Tool::SubAgent` as the template.
- **Error convention.** Recoverable failures return `"Error: ..."`
  Strings; bugs raise. See `lib/tool.rb` doc-header.
- **Tool description shape.** Heredoc one-liner + blank line + `Usage:`
  bullets. Per-arg constraints live in the parameter description, not
  the tool description. Always include an `e.g. "..."` example value.

## Reference repositories

Cloned shallow into `/tmp/pikuri-code-plan/`:

- `/tmp/pikuri-code-plan/pi` — earendil-works/pi. Coding-agent harness.
  Most relevant files:
  - `packages/coding-agent/src/core/tools/read.ts`
  - `packages/coding-agent/src/core/tools/write.ts`
  - `packages/coding-agent/src/core/tools/edit.ts`
  - `packages/coding-agent/src/core/tools/bash.ts`
  - `packages/coding-agent/src/core/tools/grep.ts`
  - `packages/coding-agent/src/core/tools/find.ts`
  - `packages/coding-agent/src/core/tools/path-utils.ts` — sandbox helpers
- `/tmp/pikuri-code-plan/opencode` — sst/opencode. Full terminal coding
  agent. Most relevant files:
  - `packages/opencode/src/tool/read.ts` + `read.txt`
  - `packages/opencode/src/tool/write.ts` + `write.txt`
  - `packages/opencode/src/tool/edit.ts` + `edit.txt`
  - `packages/opencode/src/tool/shell.ts` + `shell/` directory
  - `packages/opencode/src/tool/grep.ts` + `grep.txt`
  - `packages/opencode/src/tool/glob.ts` + `glob.txt`
  - `packages/opencode/src/permission/index.ts` — the allow/deny/ask
    model (out of scope for v1 but useful context)

Both repos use `.ts` for code and (in opencode's case) `.txt` for the
tool description shown to the LLM. The `.txt` files are the closest
reference for what good tool descriptions look like.

If the clones are missing on a fresh machine:

```sh
mkdir -p /tmp/pikuri-code-plan
cd /tmp/pikuri-code-plan
git clone --depth 1 https://github.com/earendil-works/pi pi
git clone --depth 1 https://github.com/sst/opencode opencode
```

## Cross-cutting design decisions

These thread through several steps. Resolve them in the relevant step's
session — listed here so they don't get rediscovered three times.

1. **Confirmation seam.** Both Bash (every command) and Write
   (overwrite of existing file with non-identical content) confirm.
   The confirmation port is a duck-typed object
   (`Confirmer#confirm?(prompt:) -> Boolean`) injected into
   `Tool::Bash.new(...)` and `Tool::Write.new(...)`. Two implementations:
   a stdin one for `bin/pikuri-code`, an auto-approve one for tests.
   **The tool owns the prompt wording** — Bash composes
   `"OK to run bash: <command>?"`, Write composes
   `"OK to overwrite <path>: <old_size> bytes → <new_size> bytes?"`;
   the confirmer is dumb (renders the string, parses y/yes). **Do not**
   call `gets` / `puts` directly from inside the tool — same lesson as
   listeners, keep IO at the seam.

   **Be loud about no-op tool calls.** When the model emits a tool call
   that does nothing — Write with identical content, Edit with
   `old_string == new_string` — return an `"Error: ..."` observation
   rather than silently succeeding. The model can react: either
   "the file is already correct, move on" or "my arguments were wrong,
   re-read and try again". This is the same "errors are loud" principle
   from `CLAUDE.md` applied at the tool surface. Specific cases land in
   Steps 5 (Write) and 6 (Edit).

2. **Workspace.** Read/write/edit/grep/glob/bash all need to refuse
   paths outside the agent's permitted scope. The abstraction is
   `Tool::Workspace` — abstract base with `cwd`, `resolve_for_read(path)`,
   and `resolve_for_write(path)`. `cwd` is the project anchor — where
   shells run and where modifications are made. v1 ships one concrete
   impl, `Tool::Workspace::Cwd`, which locks read+write to a single
   subtree (CWD captured at `bin/pikuri-code` startup; `cwd == root`).
   v2 will add a multi-root workspace where read includes
   `~/.claude/skills` while write stays bounded to CWD, plus
   `Tool::Workspace::ALLOW_ALL` for Docker / dev-container mode.
   Tools take `workspace:` via constructor. Failures raise
   `Tool::Workspace::Error`, which tools catch and convert to
   `"Error: ..."` observations. Step 2 has the locked-in algorithm.

3. **Tool shape: constant vs. constructor.** Tools that need no
   per-session wiring (calculator) stay as `ALL_CAPS` constants. Tools
   that capture session state (the workspace, the confirmer, optional
   "files-read-so-far" tracking) follow the `Tool::SubAgent` pattern:
   a `Tool` subclass instantiated by `bin/pikuri-code`. Read/write/edit/
   grep/glob/bash will all be the second shape.

4. **"Must read before edit" invariant.** Claude Code and opencode track
   which files the model has read this session, and reject Edit on
   un-read files. This requires per-session state pikuri doesn't have
   today. **Open question for the Edit-step session:** add the state
   (a `Set<String>` shared by Read and Edit via closure capture), or
   skip the invariant for v1. Recommendation: skip for v1, revisit if
   the model edits stale content in practice.

5. **Coding system prompt.** The current `smolagents-system-prompt.txt`
   is wrong for coding work — it teaches a research/reasoning persona
   and a verbose "Final answer:" wrap-up. The coding agent needs a
   distinct prompt — terse, action-oriented, oriented around "make the
   change, run the tests, report". `bin/pikuri-code` will read
   `coding-system-prompt.txt`; the prompt itself is its own chunk of
   work (Step 10), separate from any single tool.

6. **Existing tools carry over.** `bin/pikuri-code` keeps web_search,
   web_scrape, fetch, calculator, sub_agent — a coding agent benefits
   from web access (search for stack traces, read GitHub issues) and
   sub-agents (delegate research side-quests). The new file/shell tools
   are additions, not replacements.

## Steps

Each step below is one separate brainstorming session. Steps are
ordered by dependency — earlier steps unblock later ones. The bullet
under each step is "things to decide in that session", **not** a
pre-decided spec.

### Step 1 — Confirmation seam (`Tool::Confirmer`)

Build the abstract base + two concrete implementations. Lands as
`lib/tool/confirmer.rb` (Zeitwerk autoloads it; `lib/pikuri.rb`'s
eager-load brings the constants in). No tool depends on it yet — this
step is the abstraction + its specs in isolation.

**Locked-in design** (the session implements; doesn't re-design):

```ruby
class Tool
  # Port for asking the user to confirm a potentially destructive tool
  # operation. Subclass and implement #confirm?.
  #
  # v1 returns Boolean. Two paths-not-taken worth recording so a future
  # reader knows the design space was considered:
  #   (a) richer return (:once / :always / :reject) — rejected because it
  #       creates decision fatigue.
  #   (b) agentic destructive-or-not classifier — deferred to v2.
  # The intended escape from confirmation prompts today is sandboxing
  # (docker / dev-container) plus the --yolo flag (see Step 11).
  class Confirmer
    # @param prompt [String] human-readable question composed by the
    #   calling tool (Bash, Write). The confirmer renders it and parses
    #   the answer; it does NOT compose its own prompt content.
    # @return [Boolean] true iff approved
    def confirm?(prompt:)
      raise NotImplementedError, "#{self.class}#confirm? must be implemented"
    end

    class Terminal < Confirmer
      # ... see parsing rule below
    end

    class AutoApprove < Confirmer
      def confirm?(prompt:) = true
    end

    TERMINAL     = Terminal.new
    AUTO_APPROVE = AutoApprove.new
  end
end
```

**`Terminal#confirm?` parsing rule** (locked in):

| Input (stripped, downcased) | Action |
|---|---|
| `"y"` or `"yes"` | return true |
| `"n"` or `"no"` | return false |
| nil (EOF / Ctrl+D) | return false — deliberate abort |
| anything else (blank, typo, `"maybe"`) | re-prompt with `"Please answer y or n: "`, loop |

No retry cap; EOF eventually breaks adversarial input.

**Coordination with the `Terminal` listener:** lead the prompt with a
bare `puts` so it starts on its own line and can't glue to a streamed
byte. Don't try to coordinate further — the listener's `before_tool_call`
should already have flushed by the time a tool's execute body calls the
confirmer.

Decisions left for the session:

- Where does `AutoApprove` actually live — same file as `Terminal`
  (one `lib/tool/confirmer.rb`), or split? Recommend: one file. The
  whole abstraction is ~30 lines.
- File header YARD: include the v2 design-space note above so the
  next reader doesn't think bool was unconsidered.

### Step 2 — Workspace (`Tool::Workspace`)

Build the abstract base + the v1 concrete impl (`Cwd`). Lands as
`lib/tool/workspace.rb` (Zeitwerk autoloads; `lib/pikuri.rb`'s eager-
load pulls it in). No tool depends on it yet — this step is the
abstraction + its specs in isolation.

**Why "Workspace", not "PathSandbox":** the v2 design admits multiple
roots with different permissions (CWD = read+write, `~/.claude/skills`
= read-only). That's a workspace concept (set of accessible paths),
not a sandbox concept (one boundary). Naming for the v2 shape so we
don't rename later.

**Locked-in design** (the session implements; doesn't re-design):

```ruby
class Tool
  # Defines which paths the agent can see and write to. Subclass and
  # implement #resolve_for_read / #resolve_for_write. Returned Pathnames
  # are absolute, post-symlink-resolution.
  #
  # For v1 Cwd, the two methods are the same — read-set and write-set
  # are both the CWD subtree. The interface admits future impls where
  # they differ:
  #   - Multi-root workspace: ~/.claude/skills readable, CWD writable.
  #   - ALLOW_ALL: no restriction (planned for Docker mode in v2).
  #
  # Existence is not the workspace's concern. resolve_for_read('foo.rb')
  # succeeds (returns a Pathname) even if foo.rb doesn't exist; the
  # caller (Read) errors with file-not-found when it tries to open it.
  class Workspace
    class Error < StandardError; end

    # Project anchor — where shells run, where modifications are made.
    # @return [Pathname]
    def cwd
      raise NotImplementedError, "#{self.class}#cwd must be implemented"
    end

    # @param path [String]
    # @return [Pathname]
    # @raise [Error]
    def resolve_for_read(path)
      raise NotImplementedError, "#{self.class}#resolve_for_read must be implemented"
    end

    # @param path [String]
    # @return [Pathname]
    # @raise [Error]
    def resolve_for_write(path)
      raise NotImplementedError, "#{self.class}#resolve_for_write must be implemented"
    end

    # Locks read+write to a single subtree.
    class Cwd < Workspace
      def initialize(root:)
        @root = Pathname.new(root).realpath  # resolve once at construction
      end

      def cwd = @root
      def resolve_for_read(path)  = resolve(path)
      def resolve_for_write(path) = resolve(path)

      private

      def resolve(path)
        pn = Pathname.new(path)
        pn = @root + pn unless pn.absolute?
        cleaned = pn.cleanpath              # lexical: collapses .. and .

        # Walk up to the deepest existing ancestor — handles paths whose
        # leaf and/or intermediate components don't exist yet (Write
        # creates parents freely; see Step 5).
        existing = cleaned
        existing = existing.parent until existing.exist? || existing.parent == existing
        anchor = existing.realpath          # filesystem: resolves symlinks in the existing portion

        unless anchor == @root || anchor.to_s.start_with?(@root.to_s + File::SEPARATOR)
          raise Error, "path '#{path}' is outside the workspace '#{@root}'"
        end

        anchor + cleaned.relative_path_from(existing)
      end
    end
  end
end
```

**Why walk-up-then-realpath:** four cases this algorithm must handle
correctly. Tracing each on `@root = /home/me/proj`:

| Case | Trace | Outcome |
|---|---|---|
| `lib/foo.rb` (exists) | existing = full path, anchor in root | ✅ |
| `lib/new/dir/foo.rb` (intermediates missing) | walks up to `@root/lib`, anchor in root | ✅ returns intended new path |
| `lib/../../etc/passwd` (`..` escape) | cleanpath → `/home/etc/passwd`, walks to `/home`, anchor outside root | Error |
| `link/foo.rb` where `@root/link → /etc` (symlink escape) | existing = `@root/link`, anchor.realpath = `/etc`, outside root | Error |

Lexical-only (`cleanpath` + prefix check) would miss the symlink-escape
case. The walk-up step adds five lines and closes that gap.

**Single error class with descriptive messages**, not a hierarchy.
Tools `rescue Tool::Workspace::Error => e` and emit `"Error: #{e.message}"`.

**`~` expansion: not handled.** Either it lexically becomes `@root/~/...`
(file-not-found) or, if we expanded, resolves to `$HOME/...` (outside
workspace). Same outcome both ways; simpler to skip the expansion.

**Out of scope for v1**, worth naming so we don't drift:
- `Tool::Workspace::ALLOW_ALL` (Docker mode). No call site in v1 —
  yolo mode only swaps the confirmer. Document as a future extension
  point in the YARD header; do not ship a dead `AllowAll` class.
- `.env` / `.git/` / secrets filtering. Needs the permission system.
- Hardlink detection. Can't, generally.
- Windows path handling. Pikuri targets Linux.

Decisions left for the session:

- Visual layout of the `Cwd` impl: tiny `def resolve_for_read = resolve(...)`
  one-liners plus a private `#resolve`, or inline both? Recommend the
  one-liners — makes the read/write asymmetry visible at the public
  surface for future readers.
- YARD wording for the "not yet shipped" `ALLOW_ALL` extension point.
- Spec setup: `Dir.mktmpdir` for the root, one symlink-out + one
  symlink-in for the security tests, one non-existent-intermediate
  for the Write case.

### Step 3 — Subprocess manager (`Pikuri::Subprocess`)

Build the chokepoint for all subprocess spawning in pikuri. Lands as
`lib/pikuri/subprocess.rb`. The Bash tool depends on this; vector DB /
Docker workers in v2 will too.

**Namespacing — temporary inconsistency, deliberate direction:** this
is the first pikuri class actually under the `Pikuri::` namespace.
Existing domain classes (`Tool`, `Agent`, `URLCache`) are top-level.
We're starting a convention: **library-level infrastructure under
`Pikuri::`; domain objects stay flat for now**, with the eventual
direction being `Pikuri::Tool` / `Pikuri::Agent` (separate refactor,
not part of this work). Documented in `CLAUDE.md` (Step 13).

**Locked-in design** (the session implements; doesn't re-design):

```ruby
module Pikuri
  # All subprocess spawning in pikuri goes through here. Forces a new
  # process group, tracks pgids for at_exit cleanup, captures combined
  # stdout+stderr (the model can suppress either side in shell with
  # `2>/dev/null` etc.). Timeout is the caller's job — wrap the argv
  # with coreutils' `timeout` binary if you want one.
  #
  # State is process-global (one Set, one at_exit). Single-threaded
  # REPL today; the mutex is cheap insurance for the at_exit / register
  # race more than for current callers.
  class Subprocess
    Result = Data.define(:output, :status)

    @active = Set.new
    @mutex  = Mutex.new

    # @param argv [Array<String>] command and args. Caller does shell
    #   wrapping when shell interpretation is wanted
    #   (e.g., 'bash', '-c', cmd).
    # @param chdir [String, Pathname] working directory
    # @return [Subprocess] handle — call #wait to block for completion
    def self.spawn(*argv, chdir:)
      stdin, io, wait_thr = Open3.popen2e(*argv, chdir: chdir.to_s, pgroup: true)
      stdin.close
      register(wait_thr.pid)
      new(io: io, wait_thr: wait_thr)
    end

    attr_reader :pid, :pgid, :io
    def initialize(io:, wait_thr:)
      @io       = io
      @wait_thr = wait_thr
      @pid      = wait_thr.pid
      @pgid     = wait_thr.pid  # pgroup:true → pgid == pid
    end

    # Block until exit, read remaining output, return Result.
    # @return [Result]
    def wait
      output = @io.read
      @io.close
      Result.new(output: output, status: @wait_thr.value)
    ensure
      self.class.send(:prune, @pgid)
    end

    class << self
      # Live tracked pgroups (side-effect: prunes dead ones).
      # @return [Array<Integer>]
      def active
        @mutex.synchronize do
          @active.delete_if { |g| !alive?(g) }
          @active.to_a
        end
      end

      # SIGTERM every tracked pgroup. Best-effort; ignores errors.
      # Used by at_exit (production) and `after` blocks (specs).
      def cleanup!
        @mutex.synchronize do
          @active.each { |g| Process.kill('-TERM', g) rescue nil }
          @active.clear
        end
      end

      private

      def register(pgid)
        @mutex.synchronize { @active << pgid }
      end

      def prune(pgid)
        @mutex.synchronize { @active.delete(pgid) unless alive?(pgid) }
      end

      def alive?(pgid)
        Process.kill(0, -pgid); true
      rescue Errno::ESRCH
        false
      end
    end
  end
end

at_exit { Pikuri::Subprocess.cleanup! }
```

**Why `Open3.popen2e`:** stdlib helper that combines stdout+stderr
onto one pipe (the `e` in `2e`), gives back a wait thread (auto-reaps),
and accepts `pgroup:`. ~5 lines vs ~25 hand-rolled.

**Why blocking `.wait`, not implementing timeout in Ruby:** the caller
wraps argv with coreutils' `timeout` binary. When `timeout` and all
its FD-inheriting children die, the pipe closes, `io.read` returns.
No Ruby `Timeout.timeout` (which can't kill subprocesses), no
`IO.select` loop. The cost: timeout machinery lives in the Bash
call site, not here — which is correct, since other future callers
(vector DB, Docker) may not want a timeout at all.

**Why `.spawn` returning a handle, not blocking `.run`:** the `io`
attribute is the seam for future live streaming. v1 callers do
`Pikuri::Subprocess.spawn(...).wait` one-liner. A v2 TUI listener can
read `sp.io` in chunks before calling `sp.wait`. Costs nothing extra
to admit the future.

**Backgrounded subprocesses:** the pgid stays in `@active` after our
direct child exits if any process in the group is still alive
(`#prune` checks via `Process.kill(0, -pgid)`). On pikuri exit, `at_exit`
SIGTERMs the group. Model can opt out via `nohup` or `setsid` in
the shell command — both detach from our pgroup.

**Discipline / seam rule (codify in `CLAUDE.md`):**
**All subprocess spawning in `lib/` goes through `Pikuri::Subprocess.spawn`.**
Direct `Process.spawn` / `Open3.*` / `system` / backticks anywhere in
`lib/` are bugs. Easy to grep-enforce:
`grep -rn 'Process\.spawn\|Open3\|system\|backtick' lib/` should only
hit `lib/pikuri/subprocess.rb`.

**Test discipline:** each spec calls `Pikuri::Subprocess.cleanup!` in
`after` to SIGTERM any leaked subprocesses from the spec. Cleaner than
a `_for_test!` private method — same API, same shape as production.

**Out of scope for v1:**
- Live streaming consumer (the seam exists; no caller).
- `stdin:` kwarg (callers can extend the API when needed).
- Between-turn reporting of active subprocesses + `/bg` REPL command.
  Hooks exist (`Pikuri::Subprocess.active`); UI doesn't.
- SIGKILL escalation after at_exit SIGTERM. Pikuri is exiting anyway;
  surviving group members will be reparented to init.

Decisions left for the session:
- File header YARD: include the seam-rule note and the temporary
  namespacing inconsistency note pointing at the future `Pikuri::Tool` /
  `Pikuri::Agent` direction.
- Spec setup: how to spawn cheap subprocesses for testing (`'sleep', '5'`
  to test the `active` tracking; `'echo', 'hi'` for happy-path).
- Whether `Subprocess.active` should sort by pgid for stable output
  (matters once a `/bg` command exists; ignorable today).

### Step 4 — Read tool

`Tool::Read.new(workspace:)`. Constant export not viable because of the
workspace capture; `bin/pikuri-code` instantiates it. Internally calls
`workspace.resolve_for_read(path)`.

Decisions for the session:

- Output format. opencode uses `<line>: <content>`. Claude Code uses
  cat-n (`     1\tcontent`). Pick one — opencode's is cheaper to parse
  but the LLM is more familiar with cat-n.
- Defaults: `offset` default 1, `limit` default 2000? Cap at 2000?
- Line-length truncation: opencode truncates lines > 2000 chars with a
  marker. Adopt verbatim.
- Image/PDF handling: out of scope for v1. Refuse with "Error: image
  reading not supported" or fall through to raw bytes?
- Description: opencode's `read.txt` is the model. Adapt to pikuri's
  heredoc + `Usage:` shape.

### Step 5 — Write tool

`Tool::Write.new(workspace:, confirmer:)`. Calls
`workspace.resolve_for_write(path)`. Confirmer is needed because
overwrite of an existing file requires confirmation (see policy below).

**Policy** (locked in — adjust only with a counter-proposal):

1. **New file** (path doesn't exist) → write, no prompt.
2. **Existing file, identical content** (`File.read(path) == content`)
   → return `"Error: <path> already contains exactly this content — no
   write needed. If you intended a change, re-read the file and try
   again."`. *Before* the confirmation prompt — don't ask the user to
   confirm a no-op.
3. **Existing file, content differs** → confirm with prompt
   `"OK to overwrite <path>: <old_size> bytes → <new_size> bytes?"`.
   On yes: write. On no: return decline-Error.

Why this asymmetry with Edit (which doesn't confirm): Edit's
`old_string` argument is an implicit read-check — the model can't write
a correct `old_string` without having read the file, so blast radius is
bounded by the model's actual knowledge of file state. Write has no such
check, so a hallucinated 500-line `content` can clobber unread work.
Confirmation guards exactly the gap Edit's argument shape already
covers.

Decisions for the session:

- "Differs only in trailing newline" — treat as identical (friendlier;
  LLMs forget the trailing newline) or strict bytes (simpler)?
- Existing-but-unreadable file (permissions): can't read for the
  identical-content check, can't show old size. Return
  `"Error: ..."` observation; don't crash.
- Path display in the prompt: echo the path *as the model sent it*
  (relative or absolute) so the terminal echo matches the tool-call
  line the user just saw above.
- **Parent directory creation: locked in — Write does `mkdir_p`.**
  The workspace's `resolve_for_write` already tolerates non-existent
  intermediates and returns a valid Pathname; Write then
  `FileUtils.mkdir_p(resolved.dirname)` before `File.write`. Matches
  the `git add lib/new/dir/foo.rb` mental model. Edge case: mkdir
  succeeds, write fails — empty dir is left behind. Accept the
  artifact for v1.

### Step 6 — Edit tool

`Tool::Edit.new(workspace:)`. Calls `workspace.resolve_for_write(path)`
(Edit modifies, so it uses the write-set even though it doesn't create
files). Exact-string replacement, uniqueness required unless
`replace_all`.

Decisions for the session:

- "Must read first" invariant — see Decision 4. Punt to v2.
- **No-op Edit** (`old_string == new_string`): return
  `"Error: old_string and new_string are identical — this edit is a
  no-op."`. Cheap syntactic check, no state needed; same "be loud
  about no-ops" principle that drives the identical-content Write
  error in Step 5.
- Behavior when `old_string` not found: error.
- Behavior when `old_string` found multiple times and `replace_all=false`:
  error with a hint to add more context or use `replace_all`.
- Whitespace / newline normalization: refuse to normalize. opencode is
  strict here; the model has to send exact bytes.
- Description heredoc — model after opencode's `edit.txt`.

### Step 7 — Bash tool

`Tool::Bash.new(workspace:, confirmer:)`. First tool that needs the
confirmer. Bash doesn't path-resolve individual args — the command
string is opaque shell syntax. Shell runs in `workspace.cwd`.

**Locked-in lookup table:**

| Topic | Decision |
|---|---|
| Execution | `Pikuri::Subprocess.spawn('timeout', '--signal=TERM', '--kill-after=5s', "#{timeout}s", 'bash', '-c', command, chdir: workspace.cwd.to_s).wait` |
| Shell | `bash -c`, not `/bin/sh -c`, not `bash -lc` |
| Default timeout | 120s |
| Timeout param range | optional Integer, max 600s |
| Output capture | combined stdout+stderr (Subprocess does this via popen2e) |
| Output truncation | fixed: 15K head + 15K tail with `\n... [N bytes omitted; total was M bytes] ...\n` marker between. No per-call param — both opencode and pi converged on fixed truncation; the model has shell tools (`head`, `tail`, `grep`, `wc`) to control output volume |
| Non-zero exit | normal observation (`<output>\n\nexit status: <N>`); not a tool error |
| Timeout exit (124 / 137) | `"Error: command timed out after Ns (sent SIGTERM, then SIGKILL).\n\n<partial output>"` |
| Confirmation rejection | `"Error: user declined the bash command."` |
| Confirmation prompt format | composed by the tool — see below |
| Startup binary checks | `Tool::Bash#initialize` verifies `bash` and `timeout` on PATH via `system('command -v <bin> > /dev/null 2>&1')`; raises if missing |
| Terminal rendering | Rainbow: bold for the question line, dim for the command echo |
| Backgrounded subprocesses | handled by `Pikuri::Subprocess` — pgid tracked, SIGTERM'd on pikuri exit |
| `command` param | required String; echoed via `visible()` sanitizer (see below) |
| `description` param | optional String; subordinate label, NOT a substitute for the command echo |
| `timeout` param | optional Integer, default 120, max 600 |

**Confirmation prompt format** (composed by `Tool::Bash`):

```
OK to run bash: <description, if present>
$ <visible(command)>
[timeout 300s]            ← only if non-default timeout
(y/n)? 
```

The `description` line is omitted when no description is given. The
`[timeout Ns]` line is omitted at the 120s default. The `$ ` prefix on
the command line is conventional shell-echo and visually distinct from
prose.

**Command echo is mandatory and verbatim.** Security: if we displayed
only `description`, the model could craft `description: "ls cwd"` with
`command: "rm -rf ~/"` and the user would confirm the wrong thing.
Always echo the real command.

**Terminal-escape sanitization** (`visible()` helper):

```ruby
def visible(command)
  command.gsub(/[\x00-\x09\x0b-\x1f\x7f]/) { |c| "\\x%02x" % c.ord }
end
```

Preserves `\n` (multi-line shell commands are normal). Escapes `\r`,
`\x1b` (ESC, the ANSI escape introducer), `\b`, NUL, DEL, etc., so the
model can't smuggle in `\r\033[2K rm -rf ~/` to visually hide the
dangerous part of the command after the echo. The *execution* uses
the raw command; only the *display* goes through `visible()`.

**Observation format on the normal-exit path:**

```
$ <visible(command)>
<combined output, possibly truncated>

exit status: <N>
```

The `$ <command>` echo line at the top helps the model line up the
output against what it asked for. Both opencode and Claude Code do
this (well, Claude Code does; opencode doesn't — mild lean for echo).

**Known limitations to document in the tool description** (heredoc +
`Usage:` bullets):

- No pwd persistence between calls. Use `cd /path && cmd` within one
  command.
- No stdin to the subprocess (closed immediately). Interactive
  commands hang until timeout. The model should use non-interactive
  flags (`apt -y`, `git commit -m`).
- Backgrounded commands (`cmd &`) inherit our combined-output pipe by
  default, which means `#wait` blocks until they exit anyway — `&`
  alone does NOT detach. To genuinely background a command, redirect
  its stdout and stderr away from our pipe: `cmd >/dev/null 2>&1 &`.
  Such commands stay in our pgroup and get SIGTERM on pikuri exit;
  use `nohup` or `setsid` plus redirection to opt out of cleanup and
  survive pikuri exit. (Verified empirically during Subprocess
  implementation — see `spec/pikuri/subprocess_spec.rb` for the
  reproduction.)
- Prefer `Read` / `Write` / `Edit` / `Grep` / `Glob` over `cat` /
  `tee` / `sed` / `rg` / `find`. The dedicated tools are workspace-
  resolved and integrate with the agent's path conventions.

Decisions left for the session:

- Wording of the bash tool's `description` heredoc (the LLM-facing
  string). Adopt the limitations list above as bullets; keep the
  summary one-line.
- Exact text of the truncation marker (`...` vs `…`, whether to
  show byte counts).
- Whether `description` should also appear in the *observation*
  (e.g., echo `# Run tests` above the command on the way back to the
  model), or only in the confirmation prompt. Recommend confirmation
  only — observation should not have model-supplied text the model
  could later confuse for tool output.
- Color/formatting details: which Rainbow effects on which lines.

### Step 8 — Grep tool

`Tool::Grep.new(workspace:)`. Wraps `rg` if present, falls back to a
Ruby implementation. Calls `workspace.resolve_for_read(path)` when a
path arg is provided; default search root is the workspace's read-set.

Decisions for the session:

- Hard or soft dependency on ripgrep? Soft is more portable, hard is
  simpler. Recommendation: try `rg`, error clearly if absent (the
  install hint is one line).
- Args: `pattern`, optional `path`, optional `glob`, optional
  `output_mode` ("files_with_matches" / "content" / "count"), optional
  `case_insensitive`. Match opencode's surface.
- Output truncation — cap at N matches or N lines.

### Step 9 — Glob tool

`Tool::Glob.new(workspace:)`. `Dir.glob` with `FNM_PATHNAME` semantics.
Calls `workspace.resolve_for_read(path)` for an optional path arg;
default search root is the workspace's read-set.

Decisions for the session:

- Args: `pattern`, optional `path`.
- Sort by mtime (Claude Code does this) or alphabetically?
- Excludes: respect `.gitignore`? Probably out of scope for v1.
- Cap on result count.

### Step 10 — Coding system prompt

Write `coding-system-prompt.txt` for `bin/pikuri-code`. Read opencode's
prompts under `packages/opencode/src/session/prompt/` (or wherever they
live in the clone) as the template.

Decisions for the session:

- Persona / tone (terse / action-oriented vs. exploratory).
- Tool-use guidance: when to read vs. grep vs. glob; how to chain.
- Universal error-recovery rule (the smolagents prompt has this; carry
  over the wording).
- "Make minimal changes; don't refactor unprompted" — adopt from
  CLAUDE.md "Doing tasks" section's spirit.
- Whether to include any "Final answer:" template or let the model
  speak Markdown freely. The smolagents prompt's Final-answer template
  is research-shaped; a coding agent's last turn is usually a summary
  of the diff and what to do next. Probably no template.

### Step 11 — `bin/pikuri-code`

Entry point, modelled on `bin/pikuri-chat`. Self-bootstraps via Bundler,
configures the same llama.cpp endpoint, builds the agent with the new
tool set + existing tools + sub-agents, REPLs until Ctrl+C / Ctrl+D.

**`--yolo` flag** (locked in): `bin/pikuri-code --yolo` swaps
`Tool::Confirmer::TERMINAL` for `Tool::Confirmer::AUTO_APPROVE`. Parse
with a one-liner (`yolo = ARGV.delete('--yolo')`) before forwarding
remaining ARGV as the first user message. The banner gets an extra
line in yolo mode (`"YOLO mode: confirmations auto-approved. Use only
inside a docker / dev-container sandbox."`) so the user can't forget
the flag is on.

Decisions for the session:

- Workspace construction: `Tool::Workspace::Cwd.new(root: Dir.pwd)` at
  startup, shared across all file-touching tools.
- Banner: "Pikuri Coding Agent. Working in <CWD>. Press Ctrl+C or
  Ctrl+D to quit." (+ the yolo-mode line when applicable).
- Step budget — coding turns chain more tool calls than chat turns; 20
  is probably too low. 40? 50? Settle in the session.
- Reuse the boot wiring with `bin/pikuri-chat`? Both share
  `RubyLLM.configure`, the llama_probe_url derivation, the rescue for
  `ContextLengthExceededError`. Worth extracting a small helper into
  `lib/`, or duplicate? Recommendation: duplicate for now (2 sites,
  each ~10 lines); extract on the third binary.

### Step 12 — Specs

Each new tool gets a spec under `spec/tool/` following the existing
`spec/tool/calculator_spec.rb` style (rspec-core + minitest asserts).
The workspace, confirmer, and subprocess manager each get their own
specs. Tool specs use `Tool::Confirmer::AUTO_APPROVE` and
`Tool::Workspace::Cwd.new(root: Dir.mktmpdir)`.

`Tool::Confirmer::Terminal` specs stub `$stdin` / `$stdout` — pattern
is `StringIO` reassignment in `before`, restore in `after` (same
shape as `RubyLLM.chat` stubbing in `spec/agent_spec.rb`).

`Tool::Workspace::Cwd` specs need:
- `Dir.mktmpdir` for the root.
- One symlink-out test (workspace blocks `link/foo.rb` when `link → /etc`).
- One symlink-in test (workspace allows `link/foo.rb` when `link → sub/`).
- One non-existent-intermediate test (Write case: `a/b/c.rb` where `a/`
  doesn't exist — resolves cleanly inside).
- One `..`-escape test (`lib/../../etc/passwd` blocked).

`Pikuri::Subprocess` specs:
- Every spec calls `Pikuri::Subprocess.cleanup!` in `after` to SIGTERM
  any survivors. Same API as the production `at_exit` cleanup — no
  separate `_for_test!` method needed.
- Use cheap test commands: `'sleep', '5'` for tracking-while-alive tests,
  `'echo', 'hi'` for the happy-path Result-shape tests.
- Pgroup tracking: spawn `'bash', '-c', 'sleep 5 & wait'`, then after
  `.wait` returns, assert the pgid is still in `.active` (the
  backgrounded sleep is still alive). Then `.cleanup!` clears it.

Decisions for the session:

- Stub `Open3.capture3` for bash specs or run real commands inside a
  tmpdir?
- Are there integration specs that run the whole `bin/pikuri-code`
  loop? Probably out of scope — the existing `integration_spec.rb`
  pattern can extend later if needed.

### Step 13 — CLAUDE.md updates

Once the binary lands, update `CLAUDE.md`:

- "What this project is" mentions two binaries (chat + code).
- "Layout" gets the new files (each tool file, the confirmer, the
  workspace, `lib/pikuri/subprocess.rb`, the new prompt,
  `bin/pikuri-code`).
- "Conventions" gets three new rules under a new "Coding tools"
  subsection:
  1. **Confirmer-as-seam.** Tools that need user confirmation take a
     `Tool::Confirmer` via constructor; never call `gets` / `puts`
     directly.
  2. **Workspace.** Tools that touch files take a `Tool::Workspace`
     via constructor and resolve all paths through
     `resolve_for_read` / `resolve_for_write`.
  3. **Subprocess seam.** All subprocess spawning in `lib/` goes
     through `Pikuri::Subprocess.spawn`. Direct `Process.spawn` /
     `Open3.*` / `system` / backticks anywhere in `lib/` are bugs.
     Grep-enforceable.
- **Namespacing direction.** Library-level infrastructure (new code)
  lives under `Pikuri::` (current example: `Pikuri::Subprocess`).
  Domain classes (`Tool`, `Agent`, `URLCache`) remain top-level for
  now as a legacy convention; an eventual refactor moves them under
  `Pikuri::` too. Until then, new infrastructure starts at
  `Pikuri::Whatever` from the outset.
- Update `COMPARISON.md`'s "Available tools" row for pikuri.

## Out of scope for v1

- Permission system (opencode's allow/deny/ask glob rules). Defer until
  pikuri-code has lived a while and we know where the friction is.
- `.gitignore` respect in grep/glob.
- Image / PDF in Read.
- LSP tool.
- TODO/plan tools.
- Streaming output from bash (tools return a single observation; live
  output stays on the listener stream once we add a TUI).
- Session persistence / resumable sub-agents.
- Multi-file Edit (one `old_string` → one `new_string` per call).
