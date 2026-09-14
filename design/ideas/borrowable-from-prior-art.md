# Borrowable from prior art

The ranked shortlist that used to close the prior-art survey, kept here because it is about
*pikuri*, not about the harnesses: `design/research.md` records what the others do, and this file
records what might be worth doing about it. Sorted by fit, from "do this now" to "out of scope".
**DONE** has shipped; **FREE NOW** needs nothing more than wiring through a ruby_llm primitive.
Graduate an item the moment it is acted on — into a `D_` entry, a convention line, or nothing — and
delete this file once the live items are gone.

## A-tier — high fit, low cost

1. **Bring all tool descriptions up to the opencode bar** — **DONE**. All bundled tools use the
   heredoc summary + `Usage:` bullets shape, with universal `Error: ...` recovery factored into each
   binary's system prompt rather than restated per tool. Convention documented in `AGENTS.md`.
2. **Examples in parameter descriptions** — **DONE**. Every string parameter carries an inline
   `e.g. "..."`; integer parameters describe default and cap. Codified in `AGENTS.md`.
3. **Unicode confusable handling in `Edit`** (grok-build). Smart quotes, em-dashes, ellipses and
   non-breaking spaces pasted in from a chat app or a doc render identically to ASCII in `Read`, so
   the model's ASCII `old_string` never matches and the edit fails for a reason the model cannot see.
   Take the *diagnosis*, not grok-build's repair: on a zero-match, retry against a
   confusable-normalized copy and, if it matches, name the offending codepoint and line instead of
   editing. Repair would need a byte-offset remap, because `Edit`'s whole-file CRLF normalization
   would otherwise rewrite every smart quote in the file behind a "1 occurrence" confirmation. Keep
   the map narrow either way — grok-build excludes `U+2212 MINUS` and `U+00D7 MULTIPLICATION`
   because they carry meaning — and keep it separate from `Sanitizer`, whose set is about deception,
   not accident. See `design/ideas/grok-build-cheap-borrows.md`, `R_available_tools`.
4. **Sparse line-number anchors in `Read`** (grok-build) — **REJECTED**, listed so it is not
   re-proposed. Cheaper per read, but pikuri already chose `cat -n` for training-data familiarity and
   had that confirmed by an outside-model review; `R_available_tools` carries the
   vendor-can-tune-the-model / harness-cannot test that kills it.
5. **Interpolate caps from the constant that enforces them** (grok-build). The portable half of the
   description-template machinery, minus the machinery — already the in-tree convention for `bash`,
   the three `thunderbird_*` searches, both `fileindex_*` tools and `read`. Three tools still type
   the number by hand: `fetch` and `web_scrape` restate constants that already exist and are already
   what `.clamp` enforces, and `web_search` states a cap ("most providers cap this at 20") that
   nothing enforces and pikuri cannot verify.
6. **Deliver every mid-conversation injection as a user turn with an XML envelope** (grok-build,
   Claude Code) — **DONE**, shipped as `Agent#append_reference_block`. See
   `D_reference_text_as_user_turn` and `book/wire.md`.
7. **Tool-emitted `:halt` signal** — **FREE NOW**. ruby_llm's `RubyLLM::Tool::Halt` lets a tool
   short-circuit: returning `halt("done")` from `execute` ends the chat without a follow-up model
   call. Pikuri's synthetic-tool factory already passes any return value through verbatim, so the
   only thing missing is a helper or convention in pikuri's API and a doc note in
   `pikuri-core/lib/pikuri/tool.rb`.

## B-tier — worth it but more invasive

8. **Over-cap tool output: truncate the middle, spill to disk** (PI, opencode, grok-build). Per-tool
   byte caps already exist in `Bash` / `Read` / `WebScrape`; the missing pieces are writing the
   overflow to a `Paths.new_temp` file and returning the path so the model can `grep` it, and
   keeping the **tail** as well as the head — a build's error summary lives at the end, so head-only
   truncation discards the answer. Cross-cutting version in
   `design/ideas/security-open-questions.md` §"Output-size DoS and cost".
9. **Tool dependency expressions** (grok-build's `requires_expr`). A tool declares which other tools
   it needs, and the registry validates it when the toolset is finalized. Pikuri has no guard on an
   incoherent `Persona#tool_names` or `bin/pikuri-*` wiring; the failure surfaces as model confusion
   at runtime instead.
10. **Folder-trust gate before repo-supplied config** (grok-build, Claude Code).
    `Skill::Catalog::Bundled` scans `.pikuri/skills`, `.claude/skills` and `.agents/skills` under the
    project root, so a cloned repository's skill names and descriptions reach the system prompt with
    no trust decision. The `skill` tool already classifies a skill body as `untrusted: :hard`; the
    gap is a gate on the *source*, resolved once per workspace. grok-build's refinement worth
    copying: a "there were no repo configs" allow is never cached, so a skill that appears after a
    `git pull` is re-checked.
11. **Per-segment display of chained shell commands in `Confirmer`** (grok-build). Split the command
    on `&&`, `||`, `;`, `|` and newlines and show the human the segments; refuse to split — and say
    so — on subshells, `$(…)`, backticks, or control flow. Pure presentation, lands where
    presentation belongs, and directly serves the anti-fatigue argument in `book/security.md`.
12. **Method-signature introspection as a Parameters fallback** (ruby_llm). When a tool's `execute`
    Proc has typed kwargs, derive the schema automatically. Descriptions still need to live
    somewhere, so this saves typing only for the dumbest tools; keep the explicit builder primary.
13. **Tool descriptions in separate `.txt` files** (opencode). Easier to iterate on a multi-paragraph
    description without touching Ruby. Wait until a description gets awkward in a heredoc.
14. **One-class-many-functions tools** (langchainrb's `define_function`). Reduces boilerplate when
    one capability really does have several operations. Today pikuri's coding tools each have their
    own class; bundling them would lose the per-tool workspace/confirmer wiring, but might be worth
    revisiting for tightly-coupled families.

## C-tier — only when scope changes

15. **Permission system with glob rules** (opencode, grok-build). Pikuri ships `Workspace` +
    `Confirmer` as v1; the three-action `allow` / `deny` / `ask` glob model is the right next step
    once friction shows up. Tracked in `design/ideas/coding-agent.md`. grok-build is the richer
    reference — evaluation by severity rather than by source, per-segment matching, and a curated
    read-only command allowlist whose *exclusions* are the part worth reading before writing any
    auto-approval logic (`R_permissions`).
16. **Stall detection instead of a step count** (grok-build's goal mode). The fingerprint alone is
    the *only* loop guard pikuri would consider: `D_no_step_limit` removed the step budget precisely
    because a count fires on long work and never on looping, and names this shape as the thing to
    reach for if a real loop is ever observed. Needs a real sighting to earn its place.
17. **Content-hash anchors as an edit-addressing arm** (grok-build's `hashline_*`). Rejected for now
    (`D_single_hunk_edit`), and the arm to read first if payload size ever displaces call count as
    the problem — but note grok-build ships the scheme as a *parameter* with a benchmark harness, so
    the question is not settled there either. `R_available_tools` has the collision hazard.
18. **Deferred MCP tool loading via search** (grok-build's `search_tool` / `use_tool`). Same goal as
    `mcp_connect` with a different lever; scales better when one server exposes a hundred tools.
19. **Markdown-plus-SQLite memory substrate** (grok-build). Arguably the more pikuri-shaped answer on
    privacy and auditability grounds; not worth churning a shipped gem over, but the no-LLM-call
    automatic save and the confirm-before-write review panel are separable and cheap (`R_memory`).
20. **Structured event stream** — **DONE**. The `Agent::Event` sealed hierarchy plus four bundled
    listeners; new sinks plug in by subclassing `Listener::Base`.
21. **Streaming deltas** — **DONE**. Opt-in via `Agent.new(streaming: true)`. The bundled `Terminal`
    listener still renders on message bookends; a delta-rendering listener is the straightforward
    next step.
22. **Pluggable Operations interfaces** (pi). Lets a `bash` tool delegate to SSH / sandbox / cloud.
    `Subprocess.spawn` is the seam where this would hook in; today it only spawns local.
23. **Multi-provider abstraction** — **DONE** via the ruby_llm migration. A one-block edit in each
    `bin/pikuri-*`, no library code change.
24. **Vector search / RAG primitives** (langchainrb). Pikuri is an agent, not a RAG framework. If a
    future binary needs RAG, it can compose external vector stores rather than pulling that scope in.

## Out of scope

25. **Effect-based service architecture** (opencode). Massively too heavy for a project this size.
26. **LSP integration** (opencode, grok-build) — **shipped** as `pikuri-lsp`. Two pieces of
    grok-build's variant are still not borrowed: diagnostics riding back as a `<system-reminder>`
    after an edit, and syncing documents from the write path. Both are recorded as deferred in
    `D_lsp_document_sync`.
27. **Steering / follow-up message queues** (pi). `Control::Interloper` already covers the
    mid-loop-injection case that motivated it; a richer queue model is unmotivated today.
28. **Persistent / resumable subagent sessions** (opencode, grok-build). Requires a session store,
    not worth it for one feature. grok-build's git-worktree isolation is the natural companion for a
    child that writes; no pikuri persona writes.
29. **Parallel toolsets as an A/B harness** (grok-build). The right design *if you are tuning a model
    against tool surfaces*. Pikuri is a harness, not a model vendor. `R_tool_abstraction` has the
    three mechanisms from it that *are* worth having on their own.
30. **In-process kernel sandbox** (grok-build's Landlock / Seatbelt applied at startup). Strictly
    stronger than bubblewrap-around-`Bash`, but pikuri's file tools run in-process as the real user
    *on purpose*, so `File.writable?` is exact and backs the confirm-writable-writes posture
    (`pikuri-workspace/AGENTS.md`). Adopting it would mean giving that up — a real fork, decided the
    other way.
