# Path-triggered skill activation — the build sketch

Status: **decided, half-built.** The design, the measurements and the
roads not taken are `DECISIONS.md` `D-skill-path-activation` (accepted
2026-08-16); the prior-art read is `COMPARISON.md` (*Skills →
Frontmatter*, *→ How grok-build's conditional activation actually
works*). What is left here is what neither owns: **how the mechanism
wires into pikuri**, and the question the decision did not settle.

**Landed (2026-08-17), inert:** `Skill::PathMatcher` (the `paths:` parse +
normalization, and the gitignore matcher over a touched path),
`Catalog::Skill#paths` / `#when_to_use` / `#gated?`,
`Skill::Trigger` (the description ↔ `when-to-use` de-duplication),
`Skill::Activation` + `Activation::Sealed` (the once-per-conversation
announcement state, cleared by `Skill::Extension#on_conversation_reset`;
sealed for sub-agents via the tool-level `for_sub_agent` hook, which
`SubAgentTool` now applies), and `Skill::Extension.new(root:)` — an
absolute `Pathname`, the anchor the matcher resolves a model-supplied
path against. Nothing consults any of it yet: no listener, and every gate
surface is still open.

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


## The remaining build, in order

One commit, because a partial flip is the bad state: hiding a skill before
anything can un-hide it strands the five gated skills in the author's own
`~/.claude/skills` with no way back. Everything below lands together.

1. **`Skill::PathActivationListener`.** `TOUCH_TOOLS = read / write / edit`
   — never `grep` / `glob`, whose `:path` is a search *root* (the
   **Denylist seam**'s supplied-vs-walked line, which this listener should
   cross-reference). On `Event::ToolCall`, read the path out of
   `event.arguments` under **both** `'path'` and `:path` (it arrives off
   JSON). Resolve it against `Extension#root` *lexically* —
   `expand_path` then `relative_path_from`, never `realpath`, so a `write`
   to a file that does not exist yet still fires — and **skip** a path that
   lands outside the root rather than raising, since `PathMatcher.match?`
   refuses an absolute one. Then `activation.activate(matches)` and
   announce whatever comes back.
2. **`Skill::Promoted`** — a `Data.define(:skills, :path)` domain event with
   a `to_s`, emitted through `ctx.emit_event`; `Code::PlanModeChanged` is
   the model for how much to say. `path:` is load-bearing: the decision
   accepts over-firing, so a human will see a skill appear for no visible
   reason and needs the trigger to diagnose it.
3. **`Extension#announce`** — `inject_system_message` with the promotion
   render, plus the event. Enqueued at `before_tool_call` and drained at
   `after_tool_result`, so it lands in-turn with no extra round-trip.
4. **`Renderer.format_promotion`** — description + `when-to-use`,
   de-duplicated through `Skill::Trigger` (its first caller).
5. **The three gate surfaces.** `format_catalog` skips a `gated?` skill;
   `SkillTool` swaps its two unfiltered lookups for `activation.get` and
   `activation.names` (the *enumeration* in the not-found error is the one
   that gets missed — leaving it recites every hidden name);
   `schedule_load_skill` refuses a withheld name with the same `KeyError` a
   name that exists nowhere gets.
6. **Docs.** `D-skill-path-activation` status → implemented; CHANGELOG;
   CLAUDE.md's bundle-surface seam gains the gate; **delete this note** —
   its last live remainder is the open measurement below, which belongs to
   the decision's reopen criterion 2.

Deliberately *not* building: the 400-byte promotion budget (descriptions
are capped at 1024 already, and the mechanism exists precisely to spend a
few hundred bytes at the moment it fires — see §3 for the arithmetic if a
fat catalog ever wants it), and a `force:` escape hatch on
`schedule_load_skill`.

**One fork to settle first.** Does the *catalog block* render `when-to-use`
too, or only the promotion? Promotion-only leaves a resident ungated skill
showing its description with the trigger tail intact while a promoted one
shows the tail split out — defensible (grok-build's baseline is a different
render), but visibly inconsistent. Rendering both everywhere is uniform and
costs ~30 % more resident bytes on exactly the half the decision was trying
to shrink. Recommendation: **promotion only**, so this commit does not
quietly answer `skill-catalog-in-context.md`'s open question about what a
resident entry contains.


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
- **Why `SkillTool`'s not-found error is half the gate.** Gating only the
  lookup leaves the refusal reciting every gated name, so
  `skill(name: "anything")` becomes a one-call catalog dump and decision 2
  is undone by its own error message. It cannot simply be emptied either:
  since 2026-08-16 that error is the documented recovery path for a persona
  whose prompt carries no catalog at all, so it has to list the ungated
  names and only those. (The other half of this constraint — that the gate
  lives in the catalog's callers and never in `Catalog#get` — graduated into
  `Skill::Activation`'s yardoc.)
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

Shipped as `Skill::PathMatcher`; the rule table is now
`pikuri-skills/spec/pikuri/skill/path_matcher_spec.rb`, a case per rule, and
the inversion trap is in the module's own yardoc.

### 2. Matching a touched path — graduated

Shipped as `Skill::PathMatcher.match?`: `File.fnmatch?` with
`FNM_PATHNAME | FNM_EXTGLOB | FNM_DOTMATCH` over the touched path **and
each of its ancestors**, which is the ancestor walk grok-build gets from
`matched_path_or_any_parents` and a plain `fnmatch` does not do. No gem —
`pathspec` is git-faithful and so treats `{a,b}` as literal text, which
both harnesses expand. The rule table is
`pikuri-skills/spec/pikuri/skill/path_matcher_spec.rb`, cross-checked
pattern-by-pattern against ripgrep's own gitignore engine, and the
dialect evidence for both harnesses is `COMPARISON.md` finding 4.

What is *not* graduated is the caller's half: the touched path must be
made relative to the workspace root **lexically** (never
`realpath`-first) so a `write` to a not-yet-created file still matches,
and `match?` raises on an absolute path to force that. `Skill::Extension`
already takes the `root:` anchor for it.

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
  loudly. Done for §1 and §3 (`path_matcher_spec.rb`, `trigger_spec.rb`);
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
