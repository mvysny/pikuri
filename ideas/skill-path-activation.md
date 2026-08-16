# Path-triggered skill activation — the build sketch

Status: **decided, not built.** The design, the measurements and the
roads not taken are `DECISIONS.md` `D-skill-path-activation` (accepted
2026-08-16); the prior-art read is `COMPARISON.md` (*Skills →
Frontmatter*, *→ How grok-build's conditional activation actually
works*). What is left here is what neither owns: **how the mechanism
wires into pikuri**, and four questions the decision did not settle.

This note used to argue the case, and carried a REJECTED banner for the
few hours between the author's first verdict and its reversal the same
day. That history is in git (`6c902ea` and its parents); do not
re-litigate it from here.

Related:

- [`skill-catalog-in-context.md`](skill-catalog-in-context.md) — the
  sister note's open remainder: what a resident entry *contains*, and
  who sees the list at all.
- [`skill-cost-model.md`](skill-cost-model.md) — the cost arithmetic and
  the KV-cache analysis behind the decision's Anthropic trade.
- [`tool-list-in-context.md`](tool-list-in-context.md) — the same matcher
  aimed at tool schemas. Shares the machinery, decides separately.


## What pikuri already has — the whole loop, with zero core changes

The user's original read was "we don't have machinery for observing
file-is-touched events." Every piece is in fact already there:

| need | pikuri today |
|---|---|
| see which path a tool is about to touch | `Event::ToolCall = Data.define(:name, :arguments)`, emitted in `before_tool_call` (`agent.rb:453`) with the **model-supplied arguments** |
| act on the agent from an observer | capture the interloper in `Extension#bind`, enqueue with `inject_system_message` — `schedule_load_skill`'s trick, thread-safe by design |
| register the observer | `Configurator#add_listener` from the extension's `configure` |
| land the announcement at the right moment | `drain_interloper` runs at `after_tool_result` (`agent.rb:458`), so an enqueue made at `before_tool_call` lands **immediately after that tool's own result** — in-turn, no extra round-trip |
| reset on `/clear` | `clear_conversation` emits `Event::Reset` *and* calls `ext.on_conversation_reset` (`agent.rb:348-349`) — both reach the listener |

So it builds inside `pikuri-skills`. Sketch:

```ruby
# in Skill::Extension#configure
c.add_listener(PathActivationListener.new(catalog: @catalog, ext: self))

# in the listener
TOUCH_TOOLS = { 'read' => :path, 'write' => :path, 'edit' => :path }.freeze

def on_event(event)
  case event
  when Pikuri::Agent::Event::Reset then @announced.clear
  when Pikuri::Agent::Event::ToolCall
    key = TOUCH_TOOLS[event.name] or return
    path = event.arguments[key] or return
    newly = match(path).reject { |s| @announced.include?(s.name) }  # NOT @catalog — frozen
    return if newly.empty?

    newly.each { |s| @announced << s.name }
    @ext.announce(newly)   # → interloper.inject_system_message
  end
end
```

Three constraints the sketch encodes:

- **The state cannot live on the catalog.** `Catalog::Bundled#initialize`
  ends with `@skills.freeze`, `@list.freeze`, `freeze` (`catalog.rb:121-123`),
  so `@catalog.activate_for_paths` raises `FrozenError`. Listener-owned
  state is the better shape anyway — it keeps the catalog pure
  discovery/validation/holding. Read the deep freeze as a constraint
  worth keeping.
- **Announce once per skill per conversation.** Without `@announced` the
  same description is re-injected on every matching touch — a skill
  re-introduced ten times in one session is the mechanism paying its
  cost ten times for one delivery. The flag is what makes the injection
  idempotent, and `Event::Reset` clearing it is what makes re-hiding
  correct: after `clear_conversation` the log no longer holds the
  announcement, so the next touch must re-announce. (The decision's
  *Ships as one change* bullet carries this as an invariant.)
- **`TOUCH_TOOLS` is a tool allowlist, not an argument convention.**
  pikuri's tools already agree on the argument name — `read`, `write` and
  `edit` all take `:path` (`read.rb:118`, `write.rb:84`, `edit.rb:94`) —
  so there is no `name → path-arg` map to design. What there *is* is a
  discrimination problem: `grep` and `glob` take `:path` too
  (`grep.rb:115`, `glob.rb:101`), but theirs is a search **root**, not a
  touched file. Keying on the argument name alone would let one
  repo-root `grep` activate the whole catalog — which is exactly the
  walked-vs-supplied line the **Denylist seam** already draws, and where
  grok-build lands from the opposite direction (it has typed tool
  outputs and still excludes bash/grep as "unparseable / incidental").
  Cross-reference the seam wherever this lands.


## What the decision did not settle

1. **Announcement channel.** Reusing `:system` + `Event::SystemInjected`
   means listeners render "3 skills became available" as a message. Worth
   a dedicated event so a TUI shows a status line instead? The sister
   note's item 10 raises the stakes: if the hand-off is also *for the
   human* — here's the Tuile manual, now that you're in a Tuile file —
   this stops being a rendering nicety and becomes the selling point.
2. **Activation scope across sub-agents.** Sub-agents don't inherit
   extensions, but they *do* inherit the `skill` tool via the tool
   snapshot, closing over the same catalog — so a sub-agent can load a
   gated skill by name while never seeing a promotion. Per-agent (like
   `add_raw_tool`, which stays out of `Agent#tools` deliberately) or
   catalog-wide? Note the decision's "gated skills stay invocable" makes
   this a pure visibility question, not a capability one.
3. **How many activations does a real session fire?** Reopen criterion 2
   on the decision, and the only number that prices the Anthropic
   prefix-rewrite trade: 1–3 is noise, fifteen is a net loss there.
   Measurable today with a throwaway listener over `Event::ToolCall`,
   before any of this ships. One free data point: Claude Code fired
   `paths:` twice across ~8 tool calls in a session that read two `.rb`
   files — consistent with noise.
4. **Does an unmatched-but-touched path deserve anything?** Not raised
   before. If a session touches fifty files and no glob ever fires, the
   `<contextual_skills>` names sit there paying rent for nothing. Silent
   is probably right; noted so nobody mistakes it for an oversight.


## Graduation

- The wiring map and the `TOUCH_TOOLS` discrimination go to the
  implementation's own yardoc when it lands (the listener's class
  header), plus a cross-reference from the **Denylist seam**, which names
  the same supplied-vs-walked distinction.
- The `mcp_connect` parallel — pikuri already accepts a two-tier
  advertised inventory that mutates mid-conversation, which is what makes
  this feature unsurprising — belongs wherever that pattern gets taught
  once: `COMPARISON.md` or the book's skills material. It is the last
  piece of the original note with no durable home.
- Questions 1–2 edit `D-skill-path-activation` in place (entries are
  mutable) rather than opening a second entry; 3 is a measurement that
  either confirms the accepted trade or trips its reopen criterion.
- **This note is deleted when the mechanism ships** — nothing in it is
  meant to outlive the code it describes.
