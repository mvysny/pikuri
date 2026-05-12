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
   Steps 4 (Write) and 5 (Edit).

2. **Path sandbox.** Read/write/edit/grep/glob/bash all need to refuse
   paths outside the working tree. One helper (`Tool::PathSandbox` or
   similar) that takes a `root:` and resolves an input path with
   `Pathname#realpath` (or `realdirpath` for files-to-be-created), then
   verifies the resolved path is `root` or a descendant. Symlinks must
   not let the LLM escape. Failures return `"Error: ..."` so the LLM
   self-corrects. The `root` is captured at `bin/pikuri-code` startup
   (`Dir.pwd`) and threaded into each tool's constructor — not re-read
   per call.

3. **Tool shape: constant vs. constructor.** Tools that need no
   per-session wiring (calculator) stay as `ALL_CAPS` constants. Tools
   that capture session state (the sandbox root, the confirmer, optional
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
   work (Step 9), separate from any single tool.

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
  # (docker / dev-container) plus the --yolo flag (see Step 10).
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

### Step 2 — Path sandbox helper

Build a single helper used by every file-touching tool to resolve and
validate paths against a root. Lands as `lib/tool/path_sandbox.rb` (or
similar — name TBD).

Decisions for the session:

- Class or module? Probably a small value object holding `@root`.
- Method names: `resolve(path)` returning `Pathname`, raising on
  outside-root? Or `resolve_or_error(path)` returning a tagged result?
- How to handle paths to files that don't exist yet (write/edit-create):
  `realpath` fails — use `realdirpath` on the parent, or do the check on
  the parent and then append the basename.
- Symlink policy: follow and verify, or refuse entirely?
- Error message format — the LLM will see this. "Error: path X is
  outside the working tree (root: Y)" or similar.

### Step 3 — Read tool

`Tool::Read.new(sandbox:)`. Constant export not viable because of the
sandbox capture; `bin/pikuri-code` instantiates it.

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

### Step 4 — Write tool

`Tool::Write.new(sandbox:, confirmer:)`. Confirmer is needed because
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
- Directory creation: `mkdir -p` the parent, or refuse?

### Step 5 — Edit tool

`Tool::Edit.new(sandbox:)`. Exact-string replacement, uniqueness
required unless `replace_all`.

Decisions for the session:

- "Must read first" invariant — see Decision 4. Punt to v2.
- **No-op Edit** (`old_string == new_string`): return
  `"Error: old_string and new_string are identical — this edit is a
  no-op."`. Cheap syntactic check, no state needed; same "be loud
  about no-ops" principle that drives the identical-content Write
  error in Step 4.
- Behavior when `old_string` not found: error.
- Behavior when `old_string` found multiple times and `replace_all=false`:
  error with a hint to add more context or use `replace_all`.
- Whitespace / newline normalization: refuse to normalize. opencode is
  strict here; the model has to send exact bytes.
- Description heredoc — model after opencode's `edit.txt`.

### Step 6 — Bash tool

`Tool::Bash.new(sandbox:, confirmer:)`. First tool that needs the
confirmer.

Decisions for the session:

- Execution: `Open3.capture3` for stdout/stderr/status, or
  `Process.spawn` with timeouts?
- Default timeout — 120s? Configurable per-call via parameter?
- Output truncation: total bytes cap (e.g. 30KB) with "[truncated]"
  marker. Same on stderr.
- Working directory: `sandbox.root` always; refuse `cd` semantics for v1
  (model can `cd && cmd` as one command if it wants, but the resulting
  pwd doesn't persist between calls).
- Confirmation prompt format: "OK to run bash <description / command>?".
  Show the command verbatim. The session needs to design this together
  with the `Terminal` listener so the prompt isn't visually buried.
- What's the recoverable-error story? Non-zero exit isn't an internal
  bug — return stdout+stderr+exit status as the observation and let the
  LLM react. Confirmation rejection: return `"Error: user declined the
  command"`.

### Step 7 — Grep tool

`Tool::Grep.new(sandbox:)`. Wraps `rg` if present, falls back to a Ruby
implementation.

Decisions for the session:

- Hard or soft dependency on ripgrep? Soft is more portable, hard is
  simpler. Recommendation: try `rg`, error clearly if absent (the
  install hint is one line).
- Args: `pattern`, optional `path`, optional `glob`, optional
  `output_mode` ("files_with_matches" / "content" / "count"), optional
  `case_insensitive`. Match opencode's surface.
- Output truncation — cap at N matches or N lines.

### Step 8 — Glob tool

`Tool::Glob.new(sandbox:)`. `Dir.glob` with `FNM_PATHNAME` semantics.

Decisions for the session:

- Args: `pattern`, optional `path`.
- Sort by mtime (Claude Code does this) or alphabetically?
- Excludes: respect `.gitignore`? Probably out of scope for v1.
- Cap on result count.

### Step 9 — Coding system prompt

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

### Step 10 — `bin/pikuri-code`

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

- Where is `sandbox.root` captured? `Dir.pwd` at startup is the obvious
  answer.
- Banner: "Pikuri Coding Agent. Working in <CWD>. Press Ctrl+C or
  Ctrl+D to quit." (+ the yolo-mode line when applicable).
- Step budget — coding turns chain more tool calls than chat turns; 20
  is probably too low. 40? 50? Settle in the session.
- Reuse the boot wiring with `bin/pikuri-chat`? Both share
  `RubyLLM.configure`, the llama_probe_url derivation, the rescue for
  `ContextLengthExceededError`. Worth extracting a small helper into
  `lib/`, or duplicate? Recommendation: duplicate for now (2 sites,
  each ~10 lines); extract on the third binary.

### Step 11 — Specs

Each new tool gets a spec under `spec/tool/` following the existing
`spec/tool/calculator_spec.rb` style (rspec-core + minitest asserts).
The sandbox helper and confirmer get their own specs. Use
`Tool::Confirmer::AUTO_APPROVE` and a `Dir.mktmpdir` sandbox root in
tool specs. `Tool::Confirmer::Terminal` specs need to stub `$stdin` /
`$stdout` — pattern is to use `StringIO` and reassign with
`$stdin = StringIO.new("y\n")` in a `before`, restore in `after`
(same shape as `RubyLLM.chat` stubbing in `spec/agent_spec.rb`).

Decisions for the session:

- Stub `Open3.capture3` for bash specs or run real commands inside a
  tmpdir?
- Are there integration specs that run the whole `bin/pikuri-code`
  loop? Probably out of scope — the existing `integration_spec.rb`
  pattern can extend later if needed.

### Step 12 — CLAUDE.md updates

Once the binary lands, update `CLAUDE.md`:

- "What this project is" mentions two binaries (chat + code).
- "Layout" gets the new files (each tool file, the confirmer, the
  sandbox helper, the new prompt, `bin/pikuri-code`).
- "Conventions" gets the confirmer-as-seam rule and the path-sandbox
  rule under a new "Coding tools" subsection.
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
