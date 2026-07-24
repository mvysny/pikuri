# Anthropic stickiness of host-loaded skills — `:system` vs positional

Split out of [[programmatic-skill-loading]] (its "Residual decision
(minor)"). That note settled on injecting a host-loaded skill as a
`role: :system` item. On Anthropic that message is **hoisted** into the
top-level `system` param and re-sent every request — the skill becomes
*sticky*, unlike the `skill` tool's one-time observation. This file asks:
**is the stickiness actually a problem, and does the KV-cache argument
change the role choice?**

Status: **research done, leaning `:system` stays.** No blocker found. One
genuine open call at the bottom.

## What the code actually does (verified against ruby_llm 1.16.0)

- **`skill` tool → tool_result, positional.** `SkillTool#execute`
  (`skill_tool.rb:49-65`) *returns* the `<skill …>` string, so ruby_llm
  appends it as a `:tool` message — an observation **below the tool
  call**. It sits at that spot in the messages array forever; nothing
  moves it. (MV's recollection confirmed.)
- **Anthropic hoists every `:system` message.** `separate_messages`
  (`providers/anthropic/chat.rb`) does `partition { role == :system }`;
  `build_system_content` appends each hoisted block to the `system`
  param, order-preserved, *after* the base system prompt. Position in the
  conversation is irrelevant — a `:system` message never appears in
  `messages`, always in `system`.
- **OpenAI-family / llama.cpp (the default) does NOT hoist.** `:system`
  maps in place, inline, positionally. So on the privacy-first default
  there is no stickiness at all — this is an Anthropic-only question.
- **No `cache_control` is set by anyone.** ruby_llm 1.16.0 never *writes*
  a `cache_control` breakpoint (grep: it only *reads* `cache_*_tokens`
  off responses; `TokenLog` just reports them). So Anthropic's **billed
  prompt cache is currently OFF** — there is no explicit cached prefix to
  invalidate today.
- **pikuri already injects `:system` and accepts the hoisting.**
  `dispatch_ext_on_user_message` (`agent.rb:521-531`) appends recalled
  memory / retrieved snippets as `role: :system` and emits
  `Event::SystemInjected`. Its yardoc even states *why* system: it "tags
  the block as recalled reference, not new input, and keeps it excludable
  from a later extraction pass." So a host-loaded skill as `:system`
  **reuses an established, already-shipped pattern** — it introduces no
  new wart.

## The KV-cache hypothesis, evaluated

> Hoisting invalidates the KV cache, so the model recomputes from the
> start — right?

**Directionally correct, but currently moot, and it's a *one-time* cost —
not the per-request tax the "sticky / re-hoisted every request" wording
implies.**

1. **Prefix caching keys on a stable token prefix, and system is the
   front.** Mutating the front invalidates everything downstream — that's
   the "recompute from start" instinct, and it's true *for the request
   where the change happens*.
2. **But re-hoisting identical bytes is cache-neutral.** Once the skill is
   loaded, the `system` param is the same on every later request
   (base + skill). A prefix cache re-warms on the first post-load request
   and **hits on every one after**. "Sticky" ≠ "recomputed each turn" —
   only the single load transition costs anything.
3. **On Anthropic today it costs nothing**, because no `cache_control` is
   set → there is no explicit cache to break. The penalty only
   materializes *if pikuri later marks the system prompt cacheable* (a
   normal optimization) — then each skill-load busts the system
   breakpoint once.
4. **On the default (llama.cpp) it does not apply.** No hoisting; the
   `:system` skill lands at the tail, and llama.cpp's automatic slot cache
   reuses the whole prefix before it. Positionally optimal already.

**Net:** the KV argument is a *mild, future-conditional, Anthropic-only,
one-time* point against `:system` — not a per-turn drain.

## The three roles

| Role | Anthropic | Default (llama.cpp) | Sticky? | Cache-cost on load |
|---|---|---|---|---|
| `:tool` (what the tool uses) | positional | positional | no | none — but **can't be used** here |
| `:system` (note's choice) | hoisted to front | positional inline | yes (Anthropic) | one-time system-prefix bust *iff* caching on |
| `:user` | positional | positional | no | none (tail-only, like any turn) |

- **`:tool` is off the table.** A tool_result must pair with a preceding
  `tool_use` id; providers validate the pairing. Faking one for a
  host-initiated injection is the brittleness [[programmatic-skill-loading]]
  already rejected. So the positional option is really `:user`, not
  "mirror the tool literally."
- **`:user` — the cache-friendly, non-sticky option.** Sits deep in
  `messages` on *both* providers; never touches the system-prefix cache
  breakpoint; recomputes tail-only like any new turn. Cost: it frames
  trusted, host-controlled skill text as *the user said this* — a
  semantic lie and a faint prompt-injection-shaped smell (not a real
  vuln; the host, not the model, chose to load it).
- **`:system` — the semantically honest, precedented option.** Tags the
  block as trusted background, matches the existing memory-injection path,
  stays excludable from extraction. Cost: Anthropic stickiness + the
  one-time future cache bust above.

## Recommendation

**Keep `:system`.** The cache downside is real but small (one-time,
Anthropic-only, and zero until caching is even enabled), while `:system`
buys semantic honesty *and* consistency with the memory/snippet injection
pikuri already ships. Trading a correct role for a hypothetical one-time
cache save on one provider is a bad deal — and the moment it isn't, the
lever is a one-line role flip, cheap to revisit.

If cache pressure ever becomes real on Anthropic, the cleaner fix is *not*
switching skills to `:user` but **giving all `:system` injections
(memory + skills together) a stable cache_control breakpoint** so the
hoisted block is cached rather than recomputed — solve it once for the
whole `:system`-injection family, since they share the mechanism.

## Open call (the one genuine decision)

Do we mind that a host-loaded skill is **permanent** on Anthropic (stays
in the system prompt for the whole conversation), whereas the same skill
via the `skill` tool is a **one-shot** observation that scrolls into
history and can age out of a truncation window?

- *For sticky:* a deliberately loaded skill is guidance the user wants in
  force for the session; permanence is arguably the desired behavior.
- *Against:* it's an honest semantic divergence between two ways of
  loading "the same" skill, and it's silent (the user can't tell one load
  is sticky and the other isn't). On the default provider neither is
  sticky, so the divergence is Anthropic-only and easy to forget.

Not blocking the build. Flag in the `schedule_load_skill` rdoc either way
so the divergence is documented where a host author will see it.
