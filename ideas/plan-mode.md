# Plan mode: host-owned read-only state, re-asserted per turn

Status: **built.** Landed across pikuri-core (`Control::PlanMode` +
`Agent`/`Configurator` plumbing), pikuri-workspace (the `Write`/`Edit`
read-only gate), and pikuri-code (`EnterPlanMode` / `ExitPlanMode`
tools, the `Extension` wiring, the `PlanModeChanged` event, the
`plan-mode-reminder` prompt, and the `bin/pikuri-code` wiring). The
three forks are decided as recorded below. Remaining: render
`PlanModeChanged` in UI chrome — deferred until a TUI with a status
line exists (the current REPL has none). Still to drain into
`docs/guide/`.

The shape is almost entirely *compositional* — one new core `Control`,
a two-line gate in two existing tools, and a self-contained feature
module in `pikuri-code` that plugs in the same way `pikuri-memory` and
`pikuri-tasks` already do. Nothing in this note asks ruby_llm's loop to
change, and nothing reshapes an existing seam.

Related:

- [`../CLAUDE.md`](../CLAUDE.md) §"Seams" — the **Control seam**
  (`StepLimit` / `Cancellable` / `Interloper`: host-constructed signal
  holders passed to `Agent.new`, read at loop boundaries), the
  **Confirmer seam** (mutation tools route through `confirm?`), and
  the **Extension protocol** (`configure` / `bind` /
  `on_user_message`). Plan mode is a new instance of the first, a
  reuse of the third, and leans on the second for its approval step.
- [`../pikuri-memory/DESIGN.md`](../pikuri-memory/DESIGN.md) — the
  pioneer of the per-turn `on_user_message → :system` injection.
  Plan mode is consumer #2 of that exact mechanism, which is the
  validation that the hook didn't need memory-specific shaping.

## The motivating question

How does a coding agent "know" it is in plan mode when it was the
**human** who engaged it (a keybinding the model never saw)? And how is
read-only actually *enforced*, rather than merely requested of a model
that may ignore it?

Claude Code answers both structurally, and the answer survives
porting onto pikuri's seams:

1. **Mode is host-owned state, not a property of a tool call.** A
   keybinding flips it; a model tool flips it; both write the *same*
   flag. The tool is one transition into the state, never the state
   itself.
2. **The state is re-asserted into context every turn** — not
   remembered from the tool call. That is precisely why a human toggle
   the model never observed works identically: the next turn carries a
   freshly-injected reminder regardless of who flipped the flag.
3. **Read-only is enforced at the tool boundary**, not trusted to the
   model. The model is *told* not to edit (soft), and the edit tools
   *refuse* to edit (hard).

These three map one-to-one onto a Control, the `on_user_message` hook,
and a gate inside the mutation tools.

## Why the Agent loop can't enforce this centrally

The obvious-looking design — have the `Agent` deny mutating tool calls
at the `before_tool_call` boundary, the way `StepLimit#tick!` and
`Cancellable#check!` already hook there — does **not** work. ruby_llm
owns the loop; `before_tool_call` is a notification callback that
*cannot substitute a result*. To deny a tool call **and** feed the
model an observation explaining why ("blocked — you're in plan mode,
put this in your plan instead"), the refusal has to come from inside
the tool's own `execute`, which is the only place that returns the
next observation.

So enforcement lives in the tools, and the `Control` here is read by
the *tools and the extension*, not by the Agent loop — unlike the
other three controls. That is fine (no rule says a control must be
Agent-read), and it is forced by the loop ownership, not a stylistic
choice.

## The four layers

### 1. State — a new `Control::PlanMode` (pikuri-core)

A thread-safe flag with two writers (host UI thread + model tool
thread), exactly the dual-writer shape of `Control::Cancellable`
(host calls `cancel!` from another thread; the Agent reads it at a
boundary). It carries an `on_change` callback list so a transition can
fan out to the UI.

```ruby
# pikuri-core/lib/pikuri/agent/control/plan_mode.rb
class Control::PlanMode
  def initialize(active: false)
    @mutex = Mutex.new
    @active = active
    @on_change = []
  end

  def active? = @mutex.synchronize { @active }
  def enter! = flip(true)
  def exit!  = flip(false)
  def on_change(&blk) = (@on_change << blk)

  private

  def flip(value)
    changed = @mutex.synchronize { was = @active; @active = value; was != value }
    return unless changed
    now = active?
    @on_change.each { |cb| cb.call(now) }
  end
end
```

`Agent.new(plan_mode:)` accepts it like `cancellable:` / `interloper:`,
and the `Configurator` exposes it as a readable attribute (so the
extension can pick it up in `configure` without the host double-passing
it). This is the **entire** pikuri-core footprint: one primitive, no
policy. Plan mode's *meaning* lives in pikuri-code (layer below).

The `on_change` callbacks run on whichever thread flips the flag — the
host UI thread for a keybinding (updates its own status line), the
agent thread for a model tool (the extension re-emits it as a domain
event, see layer 4).

### 2. Transitions — two writers, one flag

- **Host / UI.** Calls `plan_mode.enter!` / `.exit!` directly,
  out-of-band, the same way the host already calls `cancellable.cancel!`
  from the input thread. The host holds the one `PlanMode` instance for
  exactly this reason.
- **Model.** `enter_plan_mode` and `exit_plan_mode` tools that flip the
  *same* flag. `exit_plan_mode(plan:)` is the substantive one: it
  presents the proposed plan to the user and asks for approval through
  the **Confirmer seam** (`confirm?(request:)`) —
  - approved → `plan_mode.exit!`, observation `"Approved — proceeding."`
  - declined → stay in plan mode, observation carries the user's
    feedback so the model keeps planning.

  Reusing the Confirmer for the approval gate means no new
  human-in-the-loop machinery; it is the same prompt path `Write` and
  `Bash` already use, with a plan-specific `Request`.

### 3. The reminder — `on_user_message`, reused verbatim

The mechanism is *already* general: an `Extension#on_user_message(ctx,
content)` that returns a `String` has it injected as a `:system`
message right behind the user turn (`agent.rb` `dispatch_ext_on_user_message`),
on both initial turns and mid-loop interloper drains. pikuri-memory is
consumer #1; plan mode is consumer #2 — which is the proof the hook
didn't need memory-specific shaping.

```ruby
def on_user_message(_ctx, _content)
  return nil unless @plan_mode.active?
  Pikuri.prompt('plan-mode-reminder')   # a <plan-mode>…</plan-mode> block
end
```

Re-asserted every turn ⇒ the model "knows" it is in plan mode even when
the **human** engaged it and the model never saw a tool call. No new
generalization is required; the seam already is the general mechanism.
Frame the reminder with the same provenance-block style memory uses
(`<memory-context>` → `<plan-mode>`).

### 4. Enforcement — mutation tools consult the control (pikuri-workspace)

`Write` and `Edit` gain an optional `plan_mode:` constructor param (a
`Control::PlanMode`, default nil/inactive) and short-circuit before
touching the filesystem:

```ruby
return "Error: cannot write #{path} — agent is in plan mode (read-only). " \
       "Include this change in your plan; call exit_plan_mode to propose it." \
  if plan_mode&.active?
```

This is a **thin enforcement hook against a core primitive**, not
knowledge of plan mode's semantics. pikuri-workspace stays ignorant of
the reminder, the tools, and the policy; it only asks "are writes
allowed right now?" — the same shape in which it already asks the
Confirmer "is this *specific* write OK?". The nil default leaves
pikuri-chat and every other wiring untouched.

Defense in depth: the reminder (soft) plus the tool gate (hard).

#### Why the `plan_mode:` param beats a plan-aware Confirmer decorator

A tempting alternative is a `Confirmer` decorator that hard-denies in
plan mode — zero changes to tools. It loses on two counts:

1. **`Edit` has no Confirmer** to decorate (only `Write` and `Bash`
   take one; `Edit` mutates user files without a confirm step today).
   We would have to retrofit a Confirmer onto `Edit` *just* for this.
2. **Messaging.** A denying Confirmer maps to `"Error: user declined"`,
   conflating "the human said no to this write" with "plan mode forbids
   all writes." The param path returns a plan-specific, actionable
   message that steers the model back to planning.

## UI visualization — a domain event

`bind` wires `plan_mode.on_change { |active| ctx.emit_event(Plan::Changed.new(active:)) }`,
so listeners (a Terminal status line) render the current mode — the
same `ctx.emit_event` path `pikuri-tasks` uses for `Tasks::ListChanged`.
This is pikuri's answer to "does the TUI visualize the mode": the
chrome shows it continuously, sourced from the host-owned flag, never
inferred by the model.

## Gem layout

- **pikuri-core** — `Control::PlanMode` + the `Agent.new(plan_mode:)` /
  `Configurator` plumbing. (It's a Control; the other three live here.)
- **pikuri-workspace** — the two-line gate in `Write` / `Edit` against
  the core primitive.
- **pikuri-code** — owns everything that *is* plan mode: `Plan::Extension`
  (wires the tools, the `on_change → emit_event` bridge, and the
  per-turn reminder), `Plan::Enter` / `Plan::Exit` tools,
  `Plan::Changed` event, and `prompts/plan-mode-reminder.txt`.

Plan mode is most relevant to a file-editing coding agent, so its home
is `pikuri-code` — the same gem that owns `Bash` and `GIT_REPO_RESEARCHER`.
The split (state in core, enforcement in workspace, semantics in
pikuri-code) keeps each gem's dependency story honest: workspace depends
on core, code depends on both, and nobody learns about plan mode that
doesn't have to.

### Wiring (in `bin/pikuri-code`)

Construct **one** `PlanMode` and thread the same instance into:
`Write.new(plan_mode:)`, `Edit.new(plan_mode:)`,
`Plan::Extension.new(plan_mode)`, and `Agent.new(plan_mode:)`. The host
keeps the reference so the input thread can flip it on a keybinding —
identical discipline to how the host already holds `cancellable` to call
`cancel!`.

## Decisions (the three forks, settled)

1. **Gem layout** — `Control::PlanMode` in pikuri-core; the extension,
   tools, prompts, and event in **pikuri-code** (not a new gem). The
   enforcement gate sits in pikuri-workspace's `Write` / `Edit`.
2. **Enforcement scope** — **Write + Edit only.** `Bash` stays governed
   by its existing Confirmer + Sandbox. Rationale: shell is the agent's
   primary *exploration* tool, and Claude's plan mode blocks edits while
   still allowing read-only exploration; hard-blocking `Bash` would
   lobotomize planning. A user who wants the shell locked composes a
   read-only `Sandbox` instead.
3. **Model entry** — **both `enter_plan_mode` and `exit_plan_mode`.**
   The model can proactively switch into planning for a complex task;
   the host can still enter via UI. (`EnterPlanMode` exists as a real
   tool in Claude Code's wiring even though docs frame entry as
   user-initiated — so offering it is the faithful port.)

## Known scope limits (v1)

- **MCP tools bypass `Pikuri::Tool`** (no Confirmer, no `plan_mode:`
  param) — they cannot be hard-gated by this mechanism. The reminder is
  the only (soft) backstop.
- **Sub-agents do not inherit extensions** (the established no-inherit
  rule), so plan mode does not propagate into a spawned sub-agent. A
  sub-agent the parent spawns during planning is outside the gate.

Both are stated, not solved: plan mode is **first-party-only** in v1,
with the per-turn reminder as the soft defense for everything the hard
gate can't reach. Closing either is a separate note.

## Convention check: tool names in the reminder

The reminder will likely name `exit_plan_mode` ("when ready, call
`exit_plan_mode` to present your plan"). CLAUDE.md's "no tool names in a
main system prompt" rule exempts persona prompts and is grep-enforced
only over `*.txt` main prompts — it does **not** cover runtime-injected
Ruby snippets (e.g. `pikuri-tasks`' `PROMPT_SNIPPET`, the sub-agent
`<available_agents>` snippet). The plan reminder is exactly that shape:
runtime-injected, and tightly co-wired with the very tools it names by
the same extension, so drift risk is persona-low. Treat naming the
tool as allowed here — a conscious call, consistent with the sub-agent
snippet precedent, not an oversight.
