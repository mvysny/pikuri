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
- `DECISIONS.md` `D-skill-path-activation` — the matcher mechanism,
  **shipped 2026-08-17**: a `paths:` skill is withheld until a touched file
  fires it. Its build note is gone; the code is `Pikuri::Skill::Activation`
  + `PathActivationListener`.
- `DECISIONS.md` `D-slash-commands` — the other surface, **shipped
  2026-08-16**: a skill that costs resident tokens to say "ignore me" is
  a bundle filed in the wrong place, and `Command::Registry` is where it
  belongs. Nothing here needs to price that case any more.


## Owed regardless of the `paths:` work

1. ~~**Enum-constrain `SkillTool`'s `name`.**~~ **Dropped 2026-08-16** —
   `D-skill-path-activation` decision 5 makes a gated skill refuse by
   name until its path fires, and an enum of only the *active* set would
   have to be rebuilt on every promotion, churning the tool schema
   mid-session. Both surveyed harnesses agree by construction: the one
   that hides skills is the one that takes a free-form name. The
   leniency reversal it dragged along (`validate_name`'s warn-and-
   continue) is dropped with it — a lenient name now reaches only a
   prompt block, never a tool schema, which is the position the current
   posture was written for.

2. ~~**Scan skill descriptions for injection, at MCP parity.**~~ **Moved
   2026-08-16**, twice. The is-this-bundle-trusted axis it belonged to
   shipped as `DECISIONS.md` `D-bundle-trust-grading` — which *reports*
   the exposure (a base nobody vouched for lights the untrusted leg) and
   deliberately does not defend against it. The scan itself is one
   possible defense, and now lives with the other unbuilt ones in
   [`security-open-questions.md`](security-open-questions.md) §Trifecta.

3. ~~**Fix `SkillTool`'s description, which lies to a sub-agent.**~~
   **Done 2026-08-16.** The description no longer asserts that
   `<available_skills>` is in the prompt — false for any persona naming
   `skill` in `tool_names:`, which inherits the tool but not the
   `Extension` that contributes the block. Recovery now leans on the
   not-found error, which enumerates the catalog and works for both agent
   kinds. `skill-cost-model.md` cheap borrow 3 (the stale "opencode is
   the outlier" sentence) landed in the same pass, opencode v2 having
   moved its inventory into the prompt too.


## The one fork `D-skill-path-activation` did not touch

4. **Where does the baseline live — system-prompt block, or tool
   description + enum?** The decision settled what the baseline
   *contains*, not where it *lives*. Against the move: the `SkillTool`
   header's convention argument (PI and Claude Code put the inventory in
   the prompt) is real and needs rebutting rather than ignoring, and
   opencode v2 moved *to* the prompt, not away. For it: a persona replaces
   the system prompt but inherits the tool verbatim, so the tool is the
   only home correct for both agent kinds — it would have fixed item
   3's bug by construction rather than by editing a string. **That
   argument has since weakened** (2026-08-17): item 3 *was* fixed by
   editing a string, and `SkillTool`'s class header now spells out the
   convention rebuttal this item asked for — so what is left for the
   move is structural tidiness, not a live bug.

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
   reopen criterion 2 on the decision, and measurable with a throwaway
   listener over `Event::ToolCall`. The mechanism shipped 2026-08-17, so
   this is now a measurement *on the shipped thing* rather than a
   pre-flight one — cheaper, not harder. **First datapoint** (2026-08-17):
   one `read` fired two promotions, of which one (`tuile`, globbing
   `**/*.rb`) was irrelevant to the task — the deliberate over-firing
   {Pikuri::Skill::Promoted} documents, and the model did decline to load
   it. Counting needs no listener now: `Listener::Terminal` prints
   `Promoted` through its generic arm, so a transcript is the measurement.

6. ~~**Is a bare name a strong enough recall cue, on a *local* model?**~~
   **Moot 2026-08-16** — there is no name-only tier any more; a gated
   skill is withheld outright. What survives is the sharper half of the
   same worry, and it is now the *only* thing standing between the
   mechanism and being useless on pikuri's default backend: **does a
   local model act on a description that arrived mid-turn**, rather than
   in the system prompt it was primed on? Every number and anecdote
   behind this family of notes came from Claude Code over a catalog
   authored for Claude Code — none of it is evidence about llama.cpp.
   **Answered 2026-08-17**, in four stages, on
   `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` against a scratch repo holding one
   deliberately badly-documented Ruby file:

   - *Delivered* ✓ — but only after a real bug. Qwen3.6's template ate
     every mid-conversation `:system` message; `D-reference-text-as-user-turn`
     fixed it (`book/wire.md` tells it).
   - *Attended* ✓ — the model named the promoted skill in its own reasoning,
     which it could only have learned from the injected block.
   - *Invoked* ✗ **→** ✓ — first run it resolved to load, then read a
     neighbouring source file instead and imitated it. Cause: the promotion
     announced mere availability while the resident catalog carried an
     imperative. Fixed in `Renderer.format_promotion`; two runs since load
     the skill unprompted and decline the irrelevant co-promoted one.
   - *Applied* ~50%, and the **shape of the miss is the finding**. Sorted by
     what each rule asks: additive rules ("lead with an example", "name a
     concrete type") landed 2/2; subtractive rules ("omit the tautology",
     "no referrer lists", "cut the wall") landed 1/5. The single subtractive
     win was the only one stated as a *literal* banned string ("Not
     thread-safe" is noise); the four losses are *categorical* and need the
     model to classify its own output as an instance.

   So the mechanism is sound and nothing further in pikuri can move this —
   the residual is model capability plus skill authoring, and it graduates
   to the two book bullets below rather than to code.

7. **Does a trigger-first description fire without a nudge?** Running
   *observationally* rather than as a formal experiment, because it no
   longer gates a decision. `writing-rdoc` was rewritten trigger-first;
   both doc nudges
   were removed from the author's global CLAUDE.md (`dotfiles-claude`
   `ff8e41c`, revert to restore) — that half still holds. **The control
   is gone, though** (noticed 2026-08-17): `writing-javadoc` no longer
   keeps the old content-summary shape — it now carries the same
   `TRIGGER —` prefix, its own `paths:` and a `when-to-use:` block,
   exactly like `writing-rdoc`. There is no A/B left to compromise;
   both arms are the treatment. What is worth watching in normal work:
   whether
   `writing-rdoc` gets loaded when Ruby docs are written, now that
   `paths:` puts its description in front of the model at the right moment
   and nothing else asks for it. **Partly answered by item 6's runs**: a
   trigger-first description does fire without a nudge on a local model —
   but only once the promotion block carries the load instruction. With
   the availability-only wording it did not, so "trigger-first" was never
   the binding variable it looked like.


## Still-open content questions

8. **Should the host-driven load path be built next?** The hand-written
   CLAUDE.md nudges were asking for *deterministic* loading, which is
   {Pikuri::Skill::Extension#schedule_load_skill} — a seam that exists, is
   main-agent-only, and that no bundled `bin/` exposes.
   `D-skill-path-activation` decision 7 makes it the sanctioned home for
   "in a Gradle project, load `gradle`", so it has two dependents (that
   case and the deterministic-load argument generally). It had a third,
   `disable-model-invocation:`, which is gone: a bundle only the human
   fires is a slash command, and those ship (`D-slash-commands`) on a
   surface the model is never told about. It is *not* the escape hatch for a gated skill any more —
   decision 7 now gates this seam too, so the deterministic-load case
   only works for skills their author left ungated, which `gradle` is.
   Caveat and the reason it is not already done:
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
    the shipped two-events design (a `Skill::Promoted` domain event
    alongside `Event::SystemInjected`)
    from a rendering nicety into the feature's selling point. Strike the
    reassurance this item used to carry — *withholding costs the model's
    view, never the human's*. It held under every design **considered**
    and under none **shipped**: both harnesses gate the operator, and
    `D-skill-path-activation` decision 7 now follows them. So the human
    loses the entry too until the glob fires, and the promotion moment is
    the *only* moment they are told the skill exists. That does not
    weaken the UX claim, it sharpens it — the `Skill::Promoted` render is
    now the feature's sole human-facing surface, not a nicer alternative
    to one.

    **Smaller than it reads, as of 2026-08-17.** A human already sees the
    promotion in every bundled binary: `Listener::Terminal`'s generic
    `else` arm renders any gem domain event through its own `to_s`, so
    `Skill::Promoted` prints `· skills available: writing-rdoc (matched
    lib/pikuri/agent.rb)` with no case arm anywhere. So the UX floor is
    met and the open part is only whether a *richer* host — a TUI —
    earns a styled arm of its own. Not nothing, but not the feature's
    missing half either.


## Graduation plan for what is left

- Items 1–3 are closed: 1 dropped (its `DECISIONS.md` line landed as a
  rejected alternative on `D-skill-path-activation`), 2 moved to
  `security-open-questions.md` once `D-bundle-trust-grading` shipped the
  axis it hung off, 3 fixed.
- Item 4, whichever way it lands, edits `D-skill-path-activation` in place
  (entries are mutable) rather than taking a new entry.
- **One fact outlives every remaining item and should graduate now, since
  it is true today and invisible in the code:** a sub-agent gets skills
  only if its persona names `skill` in `tool_names:`, and no bundled
  persona does → {Pikuri::SubAgent::Persona}'s yardoc, which is currently
  silent in both directions. {Pikuri::SubAgent::SubAgentTool}'s header
  already carries the general form ("one that needs MCP / Skills ships
  its own wiring"); `Persona` is where someone writing one will look.
  `SkillTool`'s header now carries the tool-side half of the same fact,
  so the two should read as one story.
- The **capability-vs-correction asymmetry** is the one concept worth
  teaching and it has no home yet: an MCP server advertises a *capability*
  the model can feel the lack of, while a skill advertises a *correction*
  the model cannot — which is why skills need a trigger where MCP servers
  do not, and why no amount of description tuning fully closes the gap.
  **Item 6 sharpened this into something measurable:** a correction is
  overwhelmingly *subtractive* ("delete this", "never write that"), and
  subtractive instructions lose to a concrete exemplar sitting in the same
  context — which is also why imitation can never carry them, since
  **absence is not demonstrable**. You can copy a neighbour's tag style;
  you cannot learn "cut your rationale section" from a file whose author
  already cut theirs.
  That belongs in the book's skills material, and in `COMPARISON.md`'s
  reasoning about why every harness surveyed relies on model judgment and
  then adds a nudge mechanism anyway.
- The **authoring guidance** — lead with the trigger, cut the narrative,
  and note that a gated description is paid only on activation (so it can
  afford to be trigger-heavy) while an ungated one is resident forever (so
  it must be tight) — now has a fourth rule with a measurement behind it:
  **state a ban literally, never categorically.** Item 6's one subtractive
  rule that survived contact with a local model was the one naming the
  exact forbidden string; the four phrased as categories ("a tautology",
  "a referrer list") all lost, because they ask the model to classify its
  own output before it can obey. Prefer "never write `Not thread-safe`"
  over "skip the negative". All of this is advice to skill *authors*, so
  it belongs wherever
  the book teaches skill authoring, not in a yardoc nobody writing a
  `SKILL.md` will read.
- When items 1–4 land and the measurements are taken, **this note is
  deleted** rather than left as a stub.
