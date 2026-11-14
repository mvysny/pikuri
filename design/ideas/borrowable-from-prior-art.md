# Borrowable from prior art

The ranked shortlist that used to close the prior-art survey, kept here because it is about
*pikuri*, not about the harnesses: `design/research.md` records what the others do, and this file
records what might be worth doing about it. Sorted by fit, from "do this now" to "out of scope".
The items about the shell, skills, permissions, MCP and memory moved with those gems to
`pikuri-workshop:design/ideas/borrowable-from-prior-art.md`. Graduate an item the moment it is
acted on — into a `D_` entry, a convention line, or nothing — and delete this file once the live
items are gone.

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
   not accident. See `design/ideas/grok-build-cheap-borrows.md`,
   `R_available_tools`.
2. **Interpolate caps from the constant that enforces them** (grok-build). The portable half of the
   description-template machinery, minus the machinery — already the in-tree convention for the
   three `thunderbird_*` searches, both `fileindex_*` tools and `read` (and the workshop's `bash`).
   Three tools still type the number by hand: `fetch` and `web_scrape` restate constants that
   already exist and are already what `.clamp` enforces, and `web_search` states a cap ("most
   providers cap this at 20") that nothing enforces and pikuri cannot verify.

## B-tier — worth it but more invasive

3. **Over-cap tool output: truncate the middle, spill to disk** (PI, opencode, grok-build). Per-tool
   byte caps already exist in `Read` / `WebScrape` (and the workshop's `Bash`); the missing pieces
   are writing the overflow to a `Paths.new_temp` file and returning the path so the model can
   `grep` it, and keeping the **tail** as well as the head — a build's error summary lives at the
   end, so head-only truncation discards the answer. Cross-cutting version in
   `design/ideas/security-open-questions.md` §"Output-size DoS and cost".
4. **Tool dependency expressions** (grok-build's `requires_expr`). A tool declares which other tools
   it needs, and the registry validates it when the toolset is finalized. Pikuri has no guard on an
   incoherent `Persona#tool_names` or `bin/pikuri-*` wiring; the failure surfaces as model confusion
   at runtime instead.
5. **Method-signature introspection as a Parameters fallback** (ruby_llm). When a tool's `execute`
   Proc has typed kwargs, derive the schema automatically. Descriptions still need to live
   somewhere, so this saves typing only for the dumbest tools; keep the explicit builder primary.
6. **Tool descriptions in separate `.txt` files** (opencode). Easier to iterate on a multi-paragraph
   description without touching Ruby. Wait until a description gets awkward in a heredoc.
7. **One-class-many-functions tools** (langchainrb's `define_function`). Reduces boilerplate when
   one capability really does have several operations. Today pikuri's file tools each have their
   own class; bundling them would lose the per-tool workspace/confirmer wiring, but might be worth
   revisiting for tightly-coupled families.

## Out of scope

8. **Effect-based service architecture** (opencode). Massively too heavy for a project this size.
9. **Steering / follow-up message queues** (pi). `Control::Interloper` already covers the
   mid-loop-injection case that motivated it; a richer queue model is unmotivated today.
