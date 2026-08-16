# What the skill catalog advertises — the open remainder

Status: **the trigger axis is settled and has graduated.** The decision,
its measurements and its roads not taken live in `DECISIONS.md`
`D-skill-path-activation`; the prior-art survey lives in `COMPARISON.md`
(*Skills → Frontmatter*, *→ How grok-build's conditional activation
actually works*). What is left here is the remainder: items owed
regardless of that decision, one genuine fork it did not touch, and the
measurements nobody has taken.

This note used to carry the whole argument — ten rounds of it, including a
decision to build nothing that was reversed the same day. That history is
in git (`6c902ea` and its parents) and is not worth re-reading; the parts
that survived are in the two durable homes above.

**Scope.** *What a resident entry contains* — names vs. descriptions, how
long a description should be, and who gets to see the list at all
(including sub-agents).

Related:

- [`skill-cost-model.md`](skill-cost-model.md) — the tier measurements and
  the cheap-borrow list items 1 and 4 below come from.
- [`skill-path-activation.md`](skill-path-activation.md) — the matcher
  mechanism `D-skill-path-activation` now commits to building.
- [`slash-commands.md`](slash-commands.md) — the other surface; a skill
  that costs resident tokens to say "ignore me" is a bundle filed in the
  wrong place.


## Owed regardless of the `paths:` work

1. **Enum-constrain `SkillTool`'s `name`, and price in the leniency
   reversal.** `skill-cost-model.md` cheap borrow 1. Constraint from the
   old observation 3, which still holds under the shipped design: the enum
   must list **every** skill including the `paths:`-gated ones, or a
   promoted skill is un-callable — the model reads the injected
   description, calls `skill(name: "tuile")`, and the schema rejects it.
   Stated positively, that is what lets the two mechanisms compose: the
   enum is stable for the whole session and only descriptions move, so the
   cached prefix never churns.

   The catch is that this is **not** the advertised one-liner.
   `Catalog::Bundled#validate_name` already checks the standard's shape
   (`/\A[a-z0-9-]+\z/`, the 64-char cap, leading/trailing hyphen, `--`)
   and merely warns. An enum built from leniently-validated names puts
   arbitrary text in the *tool schema*, which is a worse position than a
   prompt block — so `warn` → skip must land in the same commit. That is a
   documented-posture reversal and needs its own `DECISIONS.md` line.
   Open: skip the skill entirely, or load it and omit it from the enum
   (unreachable but visible in logs)?

2. **Scan skill descriptions for injection, at MCP parity — and decide
   where the scan lives.** Live asymmetry today: `<available_mcps>`
   descriptions get `Mcp::Verifier` before they reach the LLM (on by
   default, `verify_mcp_servers: true`); `<available_skills>` descriptions
   get nothing, though both are `untrusted: :hard` text in the same
   position. `Renderer.escape_xml` is tag-forgery defense, not instruction
   defense, and nothing above should be read as claiming otherwise.

   The structural problem: the MCP verifier is an **LLM pass** wired at
   `Agent#initialize` with a transport in hand, whereas `Catalog::Bundled`
   is constructed *before* the agent, is pure, takes no transport, and
   deep-freezes itself. Parity is not a copy-paste. Options: move the scan
   to `Skill::Extension#configure` (has the agent, but the catalog is
   already built and shared); a cheaper static tripwire
   (`ideas/injection-tripwire.md`); or accept the asymmetry and document
   why. `D-skill-path-activation` raises the stakes slightly — a promoted
   description lands in `payload[:system]` on Anthropic, a *more* trusted
   slot than the block it was withheld from.

3. **Fix `SkillTool`'s description, which lies to a sub-agent.** It says
   three times that the inventory is "in your system prompt under
   `<available_skills>`" — false for any persona that lists `skill` in
   `tool_names:`, whose prompt carries no such block. Independent of
   everything else, and it pairs with `skill-cost-model.md` cheap borrow 3
   (the stale "opencode is the outlier" sentence in the same class
   header). One pass, one commit.


## The one fork `D-skill-path-activation` did not touch

4. **Where does the baseline live — system-prompt block, or tool
   description + enum?** The decision settled what the baseline
   *contains*, not where it *lives*. Against the move: the `SkillTool`
   header's convention argument (PI and Claude Code put the inventory in
   the prompt) is real and needs rebutting rather than ignoring, and
   opencode v2 moved *to* the prompt, not away. For it: a persona replaces
   the system prompt but inherits the tool verbatim, so the tool is the
   only home correct for both agent kinds — it fixes item 3's bug by
   construction rather than by editing a string.

   Two caveats: a tool description is built once at `configure` time, so
   it cannot host promotions any better than a prompt can (those stay
   injections either way); and it makes a persona's skill access
   all-or-nothing on `tool_names:`, which is fine until someone wants a
   subset. It is also the cheapest thing on this list — moving a string.

   Note the third option `COMPARISON.md` records but pikuri declined:
   grok-build puts its baseline in the **first user message**. That is a
   better position on two counts (no prefix mutation, untrusted text in a
   data position) and `D-skill-path-activation` lists it as the first
   thing to revisit.


## Measurements nobody has taken

5. **How many activations does a real session fire?** Decides whether the
   Anthropic prefix-rewrite trade is noise (1–3) or real (fifteen). It is
   reopen criterion 2 on the decision, and measurable today with a
   throwaway listener over `Event::ToolCall` — before any of it ships.

6. **Is a bare name a strong enough recall cue, on a *local* model?** More
   relevant now than when tier 0 was the proposal: the shipped design puts
   gated skills in a name-only `<contextual_skills>` section, so the
   question is live for exactly those entries. Every number and anecdote
   behind this family of notes came from Claude Code over a catalog
   authored for Claude Code — all ten skills are `~/.claude/skills`, none
   pikuri-native. pikuri defaults to local llama.cpp, where the prior is
   far weaker. Failure mode to watch: the model ignores the name-only
   entry *and* the injected description, because the latter arrived
   mid-turn rather than in the prompt it was primed on. Cheapest probe:
   hand-render the two-section catalog and try it against the local model.
   No code required.

7. **Does a trigger-first description fire without a nudge?** Running
   *observationally* rather than as a formal experiment, because it no
   longer gates a decision. `writing-rdoc` was rewritten trigger-first;
   `writing-javadoc` keeps the old content-summary shape; both doc nudges
   were removed from the author's global CLAUDE.md (`dotfiles-claude`
   `ff8e41c`, revert to restore). The formal A/B is compromised — the two
   skills are gated on different ecosystems, and the author works in Ruby
   far more than Java, so the control gets a fraction of the treatment's
   opportunities. What is worth watching in normal work: whether
   `writing-rdoc` gets loaded when Ruby docs are written, now that
   `paths:` puts its description in front of the model at the right moment
   and nothing else asks for it.


## Still-open content questions

8. **Should the host-driven load path be built next?** The hand-written
   CLAUDE.md nudges were asking for *deterministic* loading, which is
   {Pikuri::Skill::Extension#schedule_load_skill} — a seam that exists, is
   main-agent-only, and that no bundled `bin/` exposes.
   `D-skill-path-activation` decision 7 makes it the sanctioned home for
   "in a Gradle project, load `gradle`", so it now has three dependents
   (that case, `disable-model-invocation:`, and the deterministic-load
   argument generally). Caveat and the reason it is not already done:
   CLAUDE.md's own rule says a `bin/` demo's shortcut is not evidence
   about the library — so this must be argued as "the library seam is
   under-exercised", not "the demo needs a feature".

9. **Close the direct-read fallback door on purpose.** `skill-cost-model.md`
   cheap borrow 4 (drop `<location>` from the catalog render) removes the
   model's ability to `read` a `SKILL.md` directly if the `skill` tool is
   ever absent, and `Filesystem#readable:` on `catalog.roots` is wired for
   exactly that. The tool is auto-registered whenever the catalog is
   non-empty, so the fallback covers a configuration that cannot occur
   through `Extension` — probably close it. But close it deliberately, in
   one commit, with the coupling recorded, rather than letting it fall out
   of an unrelated optimization.

10. **What does a *human* see?** Being handed the Tuile manual at the
    moment you open a Tuile file is a UX claim, not a token claim, and it
    is the part with no counter-argument. The render must be legible in a
    TUI, not just a model-facing `<system-reminder>` — which turns
    `skill-path-activation.md`'s dedicated-event-vs-`Event::SystemInjected`
    question from a rendering nicety into the feature's selling point. One
    reassurance: **withholding costs the model's view, never the human's**
    — descriptions stay on disk, so a host picker renders the full catalog
    under every design considered.


## Graduation plan for what is left

- Items 1–3 graduate **as fixes**, each with its own commit; item 1 also
  earns a `DECISIONS.md` line for the lenient-validation reversal.
- Item 4, whichever way it lands, edits `D-skill-path-activation` in place
  (entries are mutable) rather than taking a new entry.
- **Two facts outlive every remaining item and should graduate now, since
  they are true today and invisible in the code:**
  - skill descriptions are `untrusted: :hard` text resident in the
    *system prompt*, while the equivalent MCP text gets a pre-flight
    injection scan → a `SECURITY.md` / threat-model fact, not a
    skills-feature fact, live regardless of item 2's outcome;
  - a sub-agent gets skills only if its persona names `skill` in
    `tool_names:`, and no bundled persona does → {Pikuri::SubAgent::Persona}'s
    yardoc, which is currently silent in both directions.
    {Pikuri::SubAgent::SubAgentTool}'s header already carries the general
    form ("one that needs MCP / Skills ships its own wiring"); `Persona`
    is where someone writing one will look.
- The **capability-vs-correction asymmetry** is the one concept worth
  teaching and it has no home yet: an MCP server advertises a *capability*
  the model can feel the lack of, while a skill advertises a *correction*
  the model cannot — which is why skills need a trigger where MCP servers
  do not, and why no amount of description tuning fully closes the gap.
  That belongs in the book's skills material, and in `COMPARISON.md`'s
  reasoning about why every harness surveyed relies on model judgment and
  then adds a nudge mechanism anyway.
- The **authoring guidance** — lead with the trigger, cut the narrative,
  and note that a gated description is paid only on activation (so it can
  afford to be trigger-heavy) while an ungated one is resident forever (so
  it must be tight) — is advice to skill *authors*, so it belongs wherever
  the book teaches skill authoring, not in a yardoc nobody writing a
  `SKILL.md` will read.
- When items 1–4 land and the measurements are taken, **this note is
  deleted** rather than left as a stub.
