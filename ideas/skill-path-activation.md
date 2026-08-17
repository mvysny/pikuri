# Path-triggered skill activation — the build sketch

Status: **decided, half-built.** The design, the measurements and the
roads not taken are `DECISIONS.md` `D-skill-path-activation` (accepted
2026-08-16); the prior-art read is `COMPARISON.md` (*Skills →
Frontmatter*, *→ How grok-build's conditional activation actually
works*). What is left here is what neither owns: **how the mechanism
wires into pikuri**, and the question the decision did not settle.

**Landed (2026-08-17), inert:** `Skill::PathSpec` (the `paths:` parse +
normalization), `Catalog::Skill#paths` / `#when_to_use` / `#gated?`,
`Skill::Trigger` (the description ↔ `when-to-use` de-duplication), and
`Skill::Activation` (the once-per-conversation announcement state,
cleared by `Skill::Extension#on_conversation_reset`).
`Skill::Extension.new` now also takes `root:` (an absolute `Pathname`),
the anchor the matcher will resolve a model-supplied path against.
Nothing consults any of it yet — no matcher, no listener, and every gate
surface is still open. **Still to build:** §2's matcher, the
`TOUCH_TOOLS` listener, `Skill::Promoted`, and the three gate surfaces.

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
c.add_listener(PathActivationListener.new(activation: @activation, root: @root, ext: self))

# in the listener
TOUCH_TOOLS = { 'read' => :path, 'write' => :path, 'edit' => :path }.freeze

def on_event(event)
  return unless event.is_a?(Pikuri::Agent::Event::ToolCall)

  key = TOUCH_TOOLS[event.name] or return
  path = event.arguments[key] or return
  newly = @activation.activate(match(path))   # returns only what is new
  @ext.announce(newly, path) unless newly.empty?   # inject_system_message + emit Skill::Promoted
end
```

Two constraints the sketch still encodes (the once-per-conversation rule
and the state-off-the-frozen-catalog one graduated into
`Skill::Activation`'s yardoc, and `Event::Reset` is no longer the
listener's business — `Extension#on_conversation_reset` clears the
tracker):

- **The render must stay at baseline — ungated only — and never consult
  the tracker.** `clear_conversation` re-assembles the system prompt
  *before* it calls `on_conversation_reset` (`agent.rb:342` vs `:349`),
  so a snippet built from the activation set would rebuild carrying the
  stale activations and then have them cleared out from under it: the
  prompt would advertise a skill the tool refuses. Promotions live in the
  log, not the prompt, which makes the ordering moot.
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
- **The gate belongs to the callers, never to `Catalog#get`.** Both
  invocation routes go through one unfiltered lookup today
  (`SkillTool.new(catalog:)` and `schedule_load_skill` → `Catalog#get`,
  `extension.rb:109`), and both must refuse a pending skill per
  `D-skill-path-activation` decisions 5 and 7 — so filtering `Catalog#get`
  looks like the one-line fix. It is the wrong one: the catalog is
  frozen, session-less and shared, and a filtered `get` would also lie to
  the renderer, to `bin/pikuri-code:495-497`'s installed-skills banner,
  and to any future picker. `Skill::Extension` owns the activation
  tracker and hands it to the listener, the `SkillTool` *and*
  `schedule_load_skill`; the catalog keeps telling the truth.
- **`SkillTool` has two gates to fit, not one — and the second is the
  one that gets missed.** Its `execute` lambda resolves `catalog.get(name)`
  and then, on a miss, enumerates `catalog.list` into the error string
  (`skill_tool.rb:57-59`). Gating only the lookup leaves the refusal
  reciting every gated name, so `skill(name: "anything")` becomes a
  one-call catalog dump and decision 2 is undone by its own error
  message. The enumeration must come from the same filtered view the
  render uses. Note this got *more* load-bearing on 2026-08-16: the
  not-found error is now the documented recovery path for a persona
  whose prompt carries no catalog at all, so it cannot simply be
  emptied — it has to list the ungated names and only those.
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


## The exact algorithm to reimplement

Read from grok-build's source on 2026-08-16 (`main` at `5163763`), at the
level of detail a Ruby reimplementation actually needs — `COMPARISON.md`
keeps the *prior-art read* (what the mechanism is, who ships it); this is
the *specification* half, and the two divergences at the end are pikuri's
own. Cited as `file:line` so a later sync can re-check them.

### 1. Parsing `paths:` — graduated

Shipped as `Skill::PathSpec`; the rule table is now
`pikuri-skills/spec/pikuri/skill/path_spec_spec.rb`, a case per rule, and
the inversion trap is in the module's own yardoc.

### 2. Matching a touched path — `conditional.rs:96–124`

Gitignore syntax, built relative to cwd, one matcher per skill:

1. Feed every pattern to a `GitignoreBuilder` rooted at cwd (a pattern
   that fails to parse is silently skipped; a builder that fails to build
   makes the skill match nothing).
2. Make the touched path **relative to cwd lexically first**
   (`strip_prefix`) — deliberately *before* any canonicalization, so a
   not-yet-created file (a `write` target) still matches. Only on prefix
   mismatch does it canonicalize and retry, which is the symlinked-cwd
   case.
3. Match with `matched_path_or_any_parents(rel, /* is_dir */ false)` —
   the *or-any-parents* walk is what makes a bare directory pattern
   (`ideas`, `src`) match every file beneath it. A plain `File.fnmatch`
   does **not** do this; Ruby's nearest equivalent is matching the path
   and each of its ancestors in turn.

Activation is sticky and session-scoped: matched skills stay in `held`,
gated by an `activated` set of dedup keys, so a re-seed can re-promote
them; `/clear` → `rehide()` clears `activated` and re-partitions
(`conditional.rs:86`).

### 3. Rendering the promotion — graduated

The two de-duplication helpers shipped as `Skill::Trigger.strip_suffix`
(substring search, always an end-cut, unguarded) and
`.strip_prefix` (start-anchored, word-boundary guarded); the asymmetry
between them, and every rule that used to be listed here, is now a case
in `pikuri-skills/spec/pikuri/skill/trigger_spec.rb`. Nothing calls
either yet — they wait on the promotion render, which is the open half
of `skill-catalog-in-context.md`.

Budgets, if pikuri ever caps a promotion: description + `when-to-use`
share 400 bytes per entry, split proportionally to their lengths with a
20-byte floor each, before falling back to a names-only row
(`listing.rs:19–22`, `:99–115`).

### 4. Two divergences pikuri inherits from its own seams

- **pikuri activates on the tool *call*, grok-build on the tool
  *output*.** `extract_activation_paths` (`reminders/skill_discovery.rs:68`)
  reads paths out of four *output* variants — `ReadFile`, `ListDir`,
  `SearchReplace`, `ApplyPatch` (every file of a multi-file patch, rename
  targets included) — i.e. only touches that **succeeded**. The sketch
  above listens at `before_tool_call`, on **model-supplied arguments**, so
  a read of a nonexistent path or a rejected write still activates. That
  is the safe direction (the decision already accepts over-firing) and it
  is what buys the in-turn landing at `after_tool_result`; record it
  rather than discover it later. The cost is that the path is unvalidated
  model input — normalize it against the workspace root before matching,
  never trust it as relative-to-cwd.
- **`TOUCH_TOOLS` is pikuri's substitute for typed tool outputs.**
  grok-build discriminates by output *variant* and can therefore state
  plainly that *"Bash/grep paths are excluded (unparseable /
  incidental)"*. pikuri has only a name + an argument hash, so the
  allowlist carries that judgement — and `grep`/`glob` taking a `:path`
  that is a search **root** is exactly why keying on the argument name
  alone is wrong (see the four constraints above, and the **Denylist
  seam**'s supplied-vs-walked line).


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

- **The exact-algorithm section is spec, not rationale** — it graduates
  into the *specs* (a case per rule) plus a short yardoc note on each
  helper. Do not copy it into yardoc wholesale; a prose restatement of
  ten connectives rots the day the list changes, while a spec fails
  loudly. Done for §1 and §3 (`path_spec_spec.rb`, `trigger_spec.rb`);
  §2's parent walk is owed by whoever writes the matcher.
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
