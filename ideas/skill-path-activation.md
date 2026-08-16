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

### 1. Parsing `paths:` — `discovery.rs:226–254`

```
coerce_path_list(value):        # accepts a scalar OR a sequence
  String   -> split_top_level(s, '{', '}', false)   # comma-split, brace groups protected
  Sequence -> each string, same split, flattened
  other    -> nil

normalize_skill_paths(patterns):
  patterns.map  { |p| p.delete_suffix('/**') }      # `src/**` -> `src`
          .reject(&:empty?)
  return nil if cleaned.empty? || cleaned.all? { |p| p == '**' }
  cleaned
```

`nil` out of this pipeline *is* the internal spelling of "unconditional".
Both `paths: []` and `paths: ["**"]` therefore mean **always advertised**,
which is the inversion trap: an author writing "this skill matches no
paths" gets the opposite. Keep the trailing-`/**` strip — gitignore
semantics match a directory and its contents either way, so `src` and
`src/**` are the same matcher, and normalizing makes the two spellings
compare equal.

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

### 3. Rendering the promotion — `listing.rs`

Only relevant because decision 4 says a promotion carries description
(+ `when-to-use`), so pikuri needs the same de-duplication logic the
moment it honours both fields. **Two different helpers, matching two
different ways** — the distinction is easy to get wrong:

**`extract_trigger_suffix` (`listing.rs:431`) — substring search, tail
cut.** Used via `SkillEntry#func_desc` (`listing.rs:71`) and applied
**only when `when-to-use:` is present**, to cut the duplicated trigger
back out of the description:

- Ten connectives, stored pre-lowercased (`listing.rs:26–38`):
  `use this skill when`, `use when`, `auto-invoke when`, `invoke when`,
  `triggers on`, `trigger on`, `called when`, `must trigger when`,
  `must invoke when`, `must be invoked when`.
- Plain `find` over the ASCII-downcased description — **a substring match
  anywhere**, not anchored to either end. The **earliest position** wins
  across all ten (not the longest match, not list order).
- The removed part is always **the whole tail**: `description[pos..]`,
  connective included. So: a substring *search* that only ever performs an
  end-cut — text is never excised mid-string.
- **No word-boundary guard on this side.** `use when` matches inside
  `use whenever`, `trigger on` inside `triggers onboarding`. (The guard
  exists only in the other helper — an asymmetry worth preserving or
  deliberately fixing, not copying by accident.)
- The kept half is `trim_end`ed, then **one** trailing `.` is stripped;
  nothing is trimmed off its front.
- Returns nothing when either half would be empty — so a description that
  *opens* with a connective is left whole. That is why real skills written
  as `description: Use when …` render intact while one with a mid-sentence
  `Use when …` gets cut.
- Whitespace is **literal**: single ASCII spaces inside each connective, so
  `use  when` or a newline between the two words fails to match. YAML `>-`
  folding is safe (newlines become single spaces); a `|` literal block is
  not. Case-insensitive but **ASCII-only** (`to_ascii_lowercase`), which is
  also what keeps the byte offsets valid on the original string.

**`strip_leading_trigger_prefix` (`listing.rs:468`) — prefix-anchored.**
Applied to the `when-to-use:` *value* so the renderer's own `Use when:`
label is not doubled into `Use when: Use when …`:

- `strip_prefix` after `trim_start` — **start-anchored only**, never a
  substring search; a connective mid-value is left alone.
- **Word-boundary guarded**: reject the match if the next char is
  alphanumeric, so `Use whenever you need X` and `Triggers onboarding
  flow` survive. Punctuation or space is a valid boundary.
- Then eat a run of `:`, `,` and whitespace — `Use when: doing X` →
  `doing X`.
- List order decides (`use this skill when` precedes `use when`), and a
  value that is *only* a connective is returned unchanged.

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
  into the *specs* (a case per rule: the `paths: []` inversion, the
  bare-directory parent walk, the opens-with-a-connective no-op, the
  `use whenever` asymmetry) plus a short yardoc note on each helper. Do
  not copy it into yardoc wholesale; a prose restatement of ten
  connectives rots the day the list changes, while a spec fails loudly.
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
