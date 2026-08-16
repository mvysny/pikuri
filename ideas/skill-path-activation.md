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
    @ext.announce(newly, path)   # inject_system_message + emit Skill::Promoted
  end
end
```

Four constraints the sketch encodes:

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
- **The gate belongs to the render and the tool — never to `Catalog#get`.**
  This is the one place a careless implementation reproduces the
  behaviour `D-skill-path-activation` decision 7 deliberately refuses.
  Today `SkillTool.new(catalog:)` and `schedule_load_skill` share a
  single unfiltered lookup (`extension.rb:109`), so the obvious way to
  implement decision 5 — filter `Catalog#get` — silently gates the
  operator along with the model, which is precisely Claude Code's bug.
  Instead `Skill::Extension` constructs the activation tracker and hands
  it to **both** the listener and the `SkillTool`; the tool consults it,
  `schedule_load_skill` does not, and the renderer skips gated entries.
  Note what already works unchanged and must keep working:
  `bin/pikuri-code:495-497` prints every catalog name at startup off
  `catalog.list`, which is an operator surface the gate must not reach.
- **Two events fire, and they mark different moments.** The injection
  emits `Event::SystemInjected` unconditionally (`agent.rb:701`) — its
  contract is that the stream mirrors log growth, so it must not be
  suppressed. Alongside it goes a *domain* event, since core's `Event::`
  is sealed for loop narration and gems emit their own via
  `ctx.emit_event` (`event.rb:9-14`):

  ```ruby
  # pikuri-skills/lib/pikuri/skill/promoted.rb
  Promoted = Data.define(:skills, :path) do
    def to_s = "skills available: #{skills.map(&:name).join(', ')} (matched #{path})"
  end
  ```

  Modelled on {Pikuri::Code::PlanModeChanged}, whose `to_s` exists so
  `Listener::Terminal`'s `else` branch (`terminal.rb:110-114`) renders it
  legibly while a real TUI pattern-matches it. `path:` is load-bearing:
  the decision *accepts* over-firing as the safe direction, so the human
  will sometimes see a skill appear for no visible reason, and without
  the trigger path diagnosing that means guessing which glob matched.
  Two accepted costs: `SystemInjected` re-renders the same promotion as
  a dim text block (a pre-existing `Terminal` wart — it truncates
  `ToolResult` but not `SystemInjected`, so a long `recall` injection has
  it too), and the domain event lands *between* the tool call and its
  result, since the listener enqueues at `before_tool_call` while the
  interloper drains at `after_tool_result`. Both accepted 2026-08-16;
  "we decided" and "the model saw it" genuinely are different moments.


## What the decision did not settle

1. **How many activations does a real session fire?** Reopen criterion 2
   on the decision, and the only number that prices the Anthropic
   prefix-rewrite trade: 1–3 is noise, fifteen is a net loss there.
   Measurable today with a throwaway listener over `Event::ToolCall`,
   before any of this ships. One free data point: Claude Code fired
   `paths:` twice across ~8 tool calls in a session that read two `.rb`
   files — consistent with noise.

That is the whole remainder. The announcement channel, the sub-agent
scope question and the what-if-no-glob-ever-fires question all closed on
2026-08-16 — the last of them dissolved rather than answered, since a
fully-withheld skill costs nothing while it waits.


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
- `Skill::Promoted` and the two-events-two-moments rationale go to that
  class's own yardoc when it lands; `PlanModeChanged` is the model for
  how much to say.
- The one open measurement either confirms the accepted Anthropic trade
  or trips reopen criterion 2 on the decision, which is edited in place
  (entries are mutable) rather than opening a second entry.
- **This note is deleted when the mechanism ships** — nothing in it is
  meant to outlive the code it describes.
