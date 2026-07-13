# rdoc-trim — handoff note

Transient working note (per the `ideas/*.md` graduation rule): a ruthless pass
over the project's yardoc to make it dense and specific, cutting educational
padding. Delete this file once every gem's `lib/` has been swept.

## Goal

The project is educational **but assumes a competent programmer** (Ruby-fluent,
new to LLMs). Long teaching prose belongs in the book, not the source. rdoc must
be dense and specific like any good API doc — we don't educate on Ruby, threads,
or general CS. The one allowance: a *little* about agents/LLMs/security concepts,
since the book carries the real teaching. This enforces the existing global rdoc
rules (`~/.claude/CLAUDE.md`: "audience is a maintainer, not a student"; "Punchy
or unread"; "No referrer lists"; "One summary sentence") — it is enforcement, not
a doctrine change, so **no CLAUDE.md doctrine edit is needed**.

## The rubric (calibrated across 2 committed gems)

**Cut:**
- **Referrer lists** — "Read by extensions… notably the `agent` tool", "TokenLog
  renders…", "Used by X / Shared by Y". Grep answers *who*.
- **Programmer-101 / general CS** — "Data.define gives value equality for free",
  "matches Ruby `ensure` semantics", "atomic under the GVL" (beyond a one-line
  verdict), thread/queue mechanics a seasoned dev knows.
- **History** — "used to work via X", "was a standalone at_exit", "an earlier
  draft considered…" (keep only the *rejected-alternative* nugget itself if it's
  a live regression guard — see Keep).
- **Repeated emission/wiring narration** — compress "Emitted by Agent's
  after_message wiring" to a clause; state cross-cutting contracts once at
  class level (rule 9), not on every method/variant.
- **Speculation** — "useful for a future /bg command", "a richer host might…".
- **Section headers fronting a one-line contract**; verbose per-`@param` essays.

**Keep (compressed to a nugget):**
- Every **seam contract** CLAUDE.md points at (`see {ClassName}`).
- **Load-bearing gotchas / contracts** — the non-obvious *why*, ordering
  guarantees, "not re-baselined", cache-not-poisoned-on-failure, etc.
- **Regression guards** ("why not the obvious alternative") when the trap is
  invisible in code and silent under test — e.g. no tty-markdown, hand-rolled
  calculator, `--glob` overrides `.gitignore`, VCS-only project-root markers.
- **Concrete types** on every `@param`/`@return`/`@raise` — always.
- **Worked examples** and **construct-and-use snippets**.
- A genuine multi-line thread-safety/architecture story → lead with the verdict
  word (`Thread-safe.` / `<Role>-thread-confined`), keep the detail as
  What+how content (global rule 10, as amended in `~/.claude/CLAUDE.md`).

**Never touch:** LLM-facing `description:` heredocs (they're prompt text, not
rdoc); `prompts/*.txt`; `# frozen_string_literal: true`; any actual code line.

Worked reference: read the committed diffs for the calibrated style —
`git show 19f6737` (pikuri-core) and `git show 70565e5` (pikuri-workspace).
Archetypes: `pikuri-core/lib/pikuri/agent/event.rb` (value objects, 211→94),
`agent.rb` (the big one), `extractor.rb` (registry seam), `sanitizer.rb`
(security prose), `tool/calculator.rb` (regression guards kept).

## Process (per gem — "gem by gem, user drives")

The user reviews each gem's diff before the next. Per gem:

1. List files: `for f in $(find <gem>/lib -name '*.rb'); do echo "$(grep -cE '^\s*#' "$f") $f"; done | sort -rn`
   (only `lib/` — `bin/` and `spec/` don't need yardoc.)
2. Trim biggest/seam-critical first, via targeted `Edit`s on doc blocks (leaves
   code byte-identical — safer than rewriting the file).
3. Verify **comment-only** (no code changed):
   `git diff <gem>/lib | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-]\s*#' | grep -vE '^[+-]\s*$'`
   → must be empty.
4. Syntax-check: `ruby -c` each file (or `find … -exec ruby -c`).
5. Run the gem's specs: `cd <gem> && bundle exec rspec` → 0 failures.
   (Comment-only edits can't move specs; this proves nothing structural broke.)
6. Present the diff, await sign-off, then commit with:
   `docs(<gem>): trim rdoc to dense reference, drop educational padding`
   + a body naming what was kept, and the trailer:
   `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
   Commit on `master`, no push (project git convention).

Anything book-worthy but of unconfirmed book coverage → jot in
`ideas/rdoc-trim-book-gaps.md` rather than block on book work. (Currently holds
one item: `Event::Tokens`' context-window math.)

## Progress

**Done (committed):**
- `pikuri-core` — 41 files, ~4800→3145 comment lines, −1670 net. Commit 19f6737.
- `pikuri-workspace` — 13 files, −551 net. Commit 70565e5.
- `pikuri-code` — 12 files, 1843→1180 comment lines, −663 net. Kept every
  seam contract (Sandbox threat model incl. container-socket footgun +
  `FullFsNoNet` no-fallback invariant, approver deny-by-default + quote-removal
  soundness + `allow_git:`/PATH residuals, `GIT_HARDENING` RCE, GitClone CVEs +
  4 mitigations, ToolchainPaths credential-exclusion); cut the readable-vs-
  writable history, "same shape as X" preambles, and dmesg/journalctl doc dup.
- `pikuri-vectordb` — 29 files, 2707→1684 comment lines, −1023 net. Kept the
  Backend duck-typed protocol + vector-dim contract, InMemory Monitor/zero-gap
  invariant, Qdrant point-id-UUID + cosine-no-conversion (pgvector cross-ref),
  Chroma non-transactional-replace window, `Tools::Read` trifecta/membership-gate
  + lexical containment, LIBRARIAN privilege-separation, Watcher single-queue +
  teardown-ordering + symlink boundary, DockerContainer 127.0.0.1 bind +
  namespace squat, Qdrant↔Mem0Server image lockstep; cut per-class "two ways to
  get one" preambles, Data.define/testability boilerplate, entry-file double
  overview, and Indexer's method-summaries-concatenated header.
- `pikuri-mcp` — 9 files, 950→587 comment lines, −364 net. Kept the
  subprocess-seam carve-out (stdio-only) in both Servers + ClientWrapper,
  MCP-tools-bypass-`Pikuri::Tool`, two-phase lifecycle + cleanup gap,
  `resolve_description` priority chain, Verifier two-pass + `SUSPICIOUS_UNICODE`
  + injection-not-capability + rejections-not-cached, ClientWrapper
  subprocess-death restart contract, `StdioEntry#env` credential channel +
  cache-fingerprint exclusion; cut the verbatim-duplicated `@param` blocks
  across the Servers/Verifier/Synthesizer constructors, `PROMPT_VERSION`
  history notes, and referrer-map padding. Fixed a few drifted method refs
  while trimming.
- `pikuri-memory` — 7 files, 826→680 comment lines, −146 net. Commit 0bf8b9d.
  Kept the Mem0Server router-relay capability model (socket-file capability,
  rootless host-loopback rationale) + no-Postgres/pgvector-top-k patch +
  fail-loud git apply + 127.0.0.1 bind + Qdrant image lockstep, Mem0Client
  endpoint table + user-role-only write hygiene + errors-are-loud, Extension
  three-tiers + read-sync/write-async + memory-context injection defense +
  safety scope, Recorder per-turn-durability, Record field provenance +
  created_at recency. Fixed drift: Mem0Client claimed no supervisor ships
  yet (Mem0Server now exists).
- `pikuri-os` — 8 files, 621→510 comment lines, −111 net. Commit 95d9c76.
  Kept Extension's confirmation policy (confirm_all_writes + allow_git/
  GIT_HARDENING RCE residual) + FullFsNoNet + degrade-when-no-index, the
  Recoll/LocalSearch duck-typed backend seam + blind spots + check_binaries!/
  available? exit-status guard + recoll config parsing, MachineMemory
  markdown-not-mem0 + fresh-read-on-clear, SystemInfo always-present-primitives
  + dmesg_restrict-not-spawning + read-once memoization. Fixed two drifts
  (recoll "nothing wires it yet", pikuri-os.rb "as the surface lands").
- `pikuri-subagents` — 6 files, 465→262 comment lines, −203 net (~44%).
  Commit 7d590b0. Kept SubAgentTool inherited-vs-owned + no-extension-inherit/
  recursion-impossible + confirmer trifecta gate + always-:synthesize budget +
  cap-inherit-no-reprobe + TEMP_WORKSPACE_READABLE exclusion, Extension
  configure/bind + ordering gotcha + add_raw_tool-late-capture + dup-name
  fail-fast, Persona identity-source-of-truth + tool_names same-instances,
  the personas' privilege-separation + string-name decoupling. Cut the
  "old recursion guard is gone"/"earlier iteration" history + the eager-load
  essay.
- `pikuri-tasks` — 8 files, 320→216 comment lines, −104 net. Commit 2710223.
  Kept List's agent-thread-confined + id-never-reused + clear-rewind-safe +
  render example, Extension's sub-agent-no-inherit + single-owner duplicate
  guard + ListChanged cross-thread path, both reversal regression guards
  (Create JSON-array-not-newline, InProgress numeric-id-not-content) and
  ListChanged's frozen-snapshot + batch-create last-wins. Cut referrer lists,
  DESCRIPTION-restating prose, the Delete/Completed shared-shape re-narration,
  and entry-file Zeitwerk boilerplate.
- `pikuri-extractors` — 2 files, 291→243 comment lines, −48 net. Commit e3e2317.
  Dense reference already, so the cut concentrated in class-header prose. Kept
  the container-first rationale (untrusted-bytes sandbox + pinned-version
  reproducibility) + host-CLI fallback, the explicit-registration seam, the
  pick-one-per-wiring PDF trade-off table (CLAUDE.md points here), and the
  format-detection gotchas.
- `pikuri-skills` — 4 files, 178→143 comment lines, −35 net (~20%).
  Kept Catalog's lenient-validation + first-wins-precedence + subdir-order
  rationale + eager-load-body nugget + roots-feed-readable contract, SkillTool's
  inventory-in-prompt-not-description (PI/Claude-Code precedent) + closure-holds-
  same-catalog, Extension's stateless-no-bind + lstrip-avoids-double-blank gotcha.
  Cut the legacy-skill_catalog transition-layer history, the format_for_prompt
  "historically" note, and entry-file Zeitwerk boilerplate.

All: comment-only, 0 code changes, all specs green (pikuri-skills: 30
examples, 0 failures — every prior gem likewise green).

**Remaining** (comment counts, roughly biggest-impact first):
- `pikuri-pdf` — 107, 2 files (Extractors::PDF).
- `pikuri-assistant` — 8 (binary-only gem; likely nothing to trim).
- `pikuri` (metagem) — 8 (require list; nothing to trim).

Total remaining ≈ 900 comment lines across ~24 files. Cut ratio varies with
bloat: the threat-model-heavy gems settled ~38% (pikuri-code ~36%,
pikuri-vectordb ~38%, pikuri-mcp ~38%); already-dense reference gems trimmed
less (pikuri-memory/-os ~18%); padding-heavy gems more (pikuri-subagents ~44%).

## Note for the fresh session

Suggested opening prompt: *"Continue the rdoc trim from `ideas/rdoc-trim.md`.
Next gem: pikuri-pdf (the last with real yardoc; pikuri-assistant and the
metagem are binary/require-only). Same rubric, gem by gem, comment-only,
verify + specs + commit, pause for my review before the next gem."*
