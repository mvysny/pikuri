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

Both: comment-only, 0 code changes, all specs green (658 + 299).

**Remaining** (comment counts, roughly biggest-impact first):
- `pikuri-vectordb` — 2707 comments, 29 files (has a `DESIGN.md` + threat model;
  the `tools/` dir is its LLM surface; backends InMemory/Qdrant/Chroma, servers,
  indexer/watcher, embedder/reranker/chunker).
- `pikuri-code` — 1843, 12 files. **Heaviest sandbox/threat-model docs** —
  `Bash`, `Bash::Sandbox` (Bubblewrap: ephemeral overlays, container-socket
  footgun, `FullFsNoNet`), `read_only_command_approver`, `ToolchainPaths`,
  `GitClone`. Keep the threat model; cut the padding.
- `pikuri-mcp` — 950, 9 files (Registry, Servers, Verifier/Synthesizer/Thinker,
  Cache, ClientWrapper; note the documented subprocess-seam exception comment).
- `pikuri-memory` — 826, 7 files (has `DESIGN.md` + threat model; mem0 client,
  Recorder, Mem0Server socket-relay, Extension feedback-loop defenses).
- `pikuri-os` — 621, 8 files (Extension, LocalSearch/Recoll, MachineMemory,
  SystemInfo).
- `pikuri-subagents` — 465, 6 files (SubAgentTool, Persona, Extension, personas).
- `pikuri-tasks` — 320, 8 files (List + 4 tools + Extension + ListChanged event).
- `pikuri-extractors` — 291, 2 files (Documents + DOCUMENTS; docker/CLI fallback).
- `pikuri-skills` — 178, 4 files (Catalog, SkillTool, Extension).
- `pikuri-pdf` — 107, 2 files (Extractors::PDF).
- `pikuri-assistant` — 8 (binary-only gem; likely nothing to trim).
- `pikuri` (metagem) — 8 (require list; nothing to trim).

Total remaining ≈ 9200 comment lines across ~90 files; expect a similar ~45–55%
cut where files are bloated (some, like already-disciplined `tool/parameters.rb`
in core, needed almost nothing).

## Note for the fresh session

Suggested opening prompt: *"Continue the rdoc trim from `ideas/rdoc-trim.md`.
Next gem: pikuri-vectordb (or pikuri-code). Same rubric, gem by gem, comment-only,
verify + specs + commit, pause for my review before the next gem."*
