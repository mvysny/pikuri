# Borrowable from prior art

The ranked shortlist that used to close the prior-art survey, kept here because it is about
*pikuri*, not about the harnesses: `design/research.md` records what the others do, and this file
records what might be worth doing about it. Sorted by fit, from "do this now" to "out of scope".
Graduate an item the moment it is acted on — into a `D_` entry, a convention line, or nothing —
and delete this file once the live items are gone.

## A-tier — high fit, low cost

1. **Unicode confusable handling in `Edit`** (grok-build). Smart quotes, em-dashes, ellipses and
   non-breaking spaces pasted in from a chat app or a doc render identically to ASCII in `Read`, so
   the model's ASCII `old_string` never matches and the edit fails for a reason the model cannot see.
   Take the *diagnosis*, not grok-build's repair: on a zero-match, retry against a
   confusable-normalized copy and, if it matches, name the offending codepoint and line instead of
   editing. Repair would need a byte-offset remap, because `Edit`'s whole-file CRLF normalization
   would otherwise rewrite every smart quote in the file behind a "1 occurrence" confirmation. Keep
   the map narrow either way — grok-build excludes `U+2212 MINUS` and `U+00D7 MULTIPLICATION`
   because they carry meaning — and keep it separate from `Sanitizer`, whose set is about deception,
   not accident. See `design/ideas/grok-build-cheap-borrows.md`, `R_available_tools`.
2. **Interpolate caps from the constant that enforces them** (grok-build). The portable half of the
   description-template machinery, minus the machinery — already the in-tree convention for `bash`,
   the three `thunderbird_*` searches, both `fileindex_*` tools and `read`. Three tools still type
   the number by hand: `fetch` and `web_scrape` restate constants that already exist and are already
   what `.clamp` enforces, and `web_search` states a cap ("most providers cap this at 20") that
   nothing enforces and pikuri cannot verify.

## B-tier — worth it but more invasive

3. **Over-cap tool output: truncate the middle, spill to disk** (PI, opencode, grok-build). Per-tool
   byte caps already exist in `Bash` / `Read` / `WebScrape`; the missing pieces are writing the
   overflow to a `Paths.new_temp` file and returning the path so the model can `grep` it, and
   keeping the **tail** as well as the head — a build's error summary lives at the end, so head-only
   truncation discards the answer. Cross-cutting version in
   `design/ideas/security-open-questions.md` §"Output-size DoS and cost".
4. **Tool dependency expressions** (grok-build's `requires_expr`). A tool declares which other tools
   it needs, and the registry validates it when the toolset is finalized. Pikuri has no guard on an
   incoherent `Persona#tool_names` or `bin/pikuri-*` wiring; the failure surfaces as model confusion
   at runtime instead.
5. **Folder-trust gate before repo-supplied config** (grok-build, Claude Code).
   `Skill::Catalog::Bundled` scans `.pikuri/skills`, `.claude/skills` and `.agents/skills` under the
   project root, so a cloned repository's skill names and descriptions reach the system prompt with
   no trust decision. The `skill` tool already classifies a skill body as `untrusted: :hard`; the
   gap is a gate on the *source*, resolved once per workspace. grok-build's refinement worth
   copying: a "there were no repo configs" allow is never cached, so a skill that appears after a
   `git pull` is re-checked.
6. **Per-segment display of chained shell commands in `Confirmer`** (grok-build). Split the command
   on `&&`, `||`, `;`, `|` and newlines and show the human the segments; refuse to split — and say
   so — on subshells, `$(…)`, backticks, or control flow. Pure presentation, lands where
   presentation belongs, and directly serves the anti-fatigue argument in `book/security.md`.
7. **Method-signature introspection as a Parameters fallback** (ruby_llm). When a tool's `execute`
   Proc has typed kwargs, derive the schema automatically. Descriptions still need to live
   somewhere, so this saves typing only for the dumbest tools; keep the explicit builder primary.
8. **Tool descriptions in separate `.txt` files** (opencode). Easier to iterate on a multi-paragraph
   description without touching Ruby. Wait until a description gets awkward in a heredoc.
9. **One-class-many-functions tools** (langchainrb's `define_function`). Reduces boilerplate when
    one capability really does have several operations. Today pikuri's coding tools each have their
    own class; bundling them would lose the per-tool workspace/confirmer wiring, but might be worth
    revisiting for tightly-coupled families.

## C-tier — only when scope changes

10. **Permission system with glob rules** (opencode, grok-build). Pikuri ships `Workspace` +
    `Confirmer` as v1; the three-action `allow` / `deny` / `ask` glob model is the right next step
    once friction shows up. Tracked in `design/ideas/coding-agent.md`. grok-build is the richer
    reference — evaluation by severity rather than by source, per-segment matching, and a curated
    read-only command allowlist whose *exclusions* are the part worth reading before writing any
    auto-approval logic (`R_permissions`).
11. **Deferred MCP tool loading via search** (grok-build's `search_tool` / `use_tool`). Same goal as
    `mcp_connect` with a different lever; scales better when one server exposes a hundred tools.
12. **Markdown-plus-SQLite memory substrate** (grok-build). Arguably the more pikuri-shaped answer on
    privacy and auditability grounds; not worth churning a shipped gem over, but the no-LLM-call
    automatic save and the confirm-before-write review panel are separable and cheap (`R_memory`).
13. **Pluggable Operations interfaces** (pi). Lets a `bash` tool delegate to SSH / sandbox / cloud.
    `Subprocess.spawn` is the seam where this would hook in; today it only spawns local.

## Out of scope

14. **Effect-based service architecture** (opencode). Massively too heavy for a project this size.
15. **Steering / follow-up message queues** (pi). `Control::Interloper` already covers the
    mid-loop-injection case that motivated it; a richer queue model is unmotivated today.
16. **In-process kernel sandbox** (grok-build's Landlock / Seatbelt applied at startup). Strictly
    stronger than bubblewrap-around-`Bash`, but pikuri's file tools run in-process as the real user
    *on purpose*, so `File.writable?` is exact and backs the confirm-writable-writes posture
    (`pikuri-workspace/AGENTS.md`). Adopting it would mean giving that up — a real fork, decided the
    other way.
