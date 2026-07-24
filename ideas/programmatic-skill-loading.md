# Programmatic (host-driven) skill loading

**Goal.** Let a UI host (TUI / web) load a skill into the agent's context
window *on the host's initiative* — the same body the `skill` tool would
inject, but triggered by a UI affordance (a "load skill" menu / slash
command), not by the LLM deciding to call the tool. The UX MV wants (and
misses from Claude CLI): load a skill and have the agent *say something*.

Status: **brainstorm, converged; ready to build.** No code yet. The
load-bearing ruby_llm question is resolved (see *ruby_llm findings*); the
role residual is resolved too — go with `:system` (see *Residual decision*
below and [[anthropic-skill-stickiness]]).

## The design

`Skill::Extension#schedule_load_skill(name)` — on the extension the host
already constructs and keeps. **Schedule**, not do: it only *enqueues*.

```ruby
ext   = Pikuri::Skill::Extension.new(catalog: catalog)
agent = Pikuri::Agent.new(..., interloper: interloper) { |c| c.add_extension(ext) }

ext.schedule_load_skill('how-to-bake-a-cookie')   # enqueue only — nothing runs yet
agent.run_loop(user_message: text)                 # host drives the loop; skill lands here
agent.run_loop(user_message: nil)                  # or: no user message → bare skill turn (contract change, below)
```

- **The name + rdoc *are* the contract.** `schedule_load_skill` screams
  in its rdoc: *you MUST run the agentic loop after calling this, or
  nothing happens.* No events, no `on_change` signal, no callback — the
  host already owns the run lifecycle and knows when it just scheduled
  something. Enqueue-only keeps the method non-blocking and thread-safe;
  it never touches the loop or a worker thread.
- **Two UX cases, both the host's choice** (no skill parameters — a
  `/skill args…` grammar reads as arguments *to* the skill; rejected):
  - *bare load* → host runs the loop with **no user message**; the agent
    reacts to the skill alone and says something.
  - *load + message* → host runs the loop with a user message; the skill
    block and the message both land before the model responds.

### `schedule_load_skill` body

```
schedule_load_skill(name):
  skill = catalog.get(name) or raise KeyError        # UI enumerates catalog ⇒ miss is a host bug
  interloper.inject_skill(Renderer.format_skill(skill))  # typed :system item; returns nothing runnable
  skill
```

- **Miss → raise `KeyError`.** Loud-errors ethos; the UI only offers
  names from `catalog.list`.
- **Fidelity: exactly as if `skill` was called.**
  `Renderer.format_skill(skill)` is **byte-identical** to `SkillTool`'s
  output (`<skill name= location=>` wrapper + "sidecar paths are relative
  to …" note + body). That string is inline today in `SkillTool#execute`
  (`skill_tool.rb:57-64`); extract it to a shared formatter both call —
  see *Render home* below. Injected as `role: :system` — faking a
  synthetic tool_use/tool_result pair to match the *role* literally is
  brittle (providers validate the pairing) and the framing carries the
  meaning, not the role.

### Render home — `Skill::Renderer` (stateless module)

Both the LLM-facing renders move out of `Catalog` (pure discovery /
validation / holding) into a new stateless module, so presentation lives
in one box and `Catalog` stays a data class:

```ruby
module Pikuri::Skill::Renderer
  module_function
  def format_catalog(catalog) # the <available_skills> inventory
  def format_skill(skill)     # the <skill …>body</skill> load block
end
```

- **Why a module, not `SkillTool` or `Catalog`.** The body render has two
  callers — `SkillTool#execute` *and* `Extension#schedule_load_skill` —
  living in different classes whose only shared handle is the `Catalog`
  (the tool captures it in its closure; the Extension stores `@catalog`;
  neither holds the other). A `module_function` taking the data is
  reachable from both with no handle-passing, and keeps rendering off both
  the callable tool and the data class. (Rejected: `format_for_prompt` on
  `Catalog` — mixes presentation into data; on `SkillTool` — its real
  caller is `Extension#system_prompt_snippets`, not the tool, and the
  Extension doesn't retain the tool it builds in `configure`.)
- **Callers after the move:** `Extension#system_prompt_snippets` →
  `Renderer.format_catalog(@catalog)` (was `@catalog.format_for_prompt`,
  `extension.rb:64`); `SkillTool#execute` and `schedule_load_skill` →
  `Renderer.format_skill(skill)`.
- **Bonus fix the extraction carries:** the current inline body wrapper
  interpolates `name=`/`location=` **unescaped** (`skill_tool.rb:59`),
  unlike `format_for_prompt`'s escaped inventory. Fold the one `escape_xml`
  into `Renderer` and both renders escape consistently — closes a latent
  break on a skill name containing `<`/`"`.

## Interloper grows a message *kind*

`Control::Interloper` is already the "host thread → agent, drained at the
`after_tool_result` boundary" mechanism. Today every item drains as
`role: :user` + `Event::UserTurn(mid_loop: true)`. Give it a **kind**:

- Items become typed instead of bare `String` — `Item = Data.define(:kind,
  :content)`, `kind ∈ {:user, :system}`.
- `inject_user_message(content)` stays (kind `:user`); add
  `inject_skill(block)` (kind `:system`).
- `Agent#drain_interloper` dispatches per kind:
  - `:user`   → `add_message(:user)` + `Event::UserTurn(mid_loop:true)` +
    `dispatch_ext_on_user_message` (unchanged).
  - `:system` → `add_message(:system)` + **reuse** `Event::SystemInjected`
    (so the transcript reflects the injected block — no *new* event type,
    honouring "no events to fire") — and **no** `dispatch_ext_on_user_message`
    (that's user-turn semantics), no `UserTurn`.
- Class doc widens from "mid-loop user-input queue" to "mid-loop host→agent
  **injection** queue" — one mechanism, one responsibility, two kinds.

## Two drain points, so a scheduled skill always lands before `complete`

Today the interloper drains only at `after_tool_result`. That's too late
for a freshly scheduled skill on a *fresh* turn — the first `complete`
would miss it. So the run entry must **also drain pending injections at
turn start**, before the first `complete`:

- *Running* (agent mid-loop): scheduled skill drains at the next
  `after_tool_result` — the true "as if the tool was called" case, loop
  already going. Safe on every provider (the array already holds real
  turns).
- *Idle → host runs a turn*: turn-start drain injects the `:system` block
  (ordered before the user message, if any), then `complete`. Bare-load
  turn = no user message appended, just the drained skill + `complete`.

**Run entry with no user message — a contract change to the existing
`run_loop`, not a new method (MV's instinct, made provider-safe).** The
entry is `Agent#run_loop(user_message:, transport: nil)` (`agent.rb:227`).
Today it **rejects** a nil/blank message up front — `ArgumentError`, "an
empty turn poisons history and burns a step on nothing" (`agent.rb:228`,
documented in its yardoc). Bare-load needs that unconditional guard
*relaxed*, not a parallel `run`:
1. drain pending injections first (turn-start drain, below);
2. if `user_message` is nil/blank **and** the conversation still has **no
   non-system message** to complete against → **return `false`** (nothing
   done) instead of raising. This covers both "nil message + empty
   interloper" *and* the fresh-conversation skill-only case that would
   otherwise 400 on Anthropic (see findings);
3. otherwise proceed — append the user turn only if non-blank, then
   `complete`. Bare-load mid-conversation falls here: real turns already
   in the array, just the drained skill + `complete`.

The append/dispatch/complete sequence already lives inline in `run_loop`
(`agent.rb:240-247`, deliberately not `ask`) so the drain + conditional
append slot in there; the `ArgumentError` contract + yardoc `@raise` must
be rewritten to the return-`false` semantics.

## How the extension reaches the interloper

Lean **C1-lite**: `ExtensionContext` exposes the (already thread-safe)
`interloper`; `Skill::Extension#bind(ctx)` captures the handle;
`schedule_load_skill` enqueues on it from any thread. Single owner (the
Agent, via its constructor arg), no double-wiring footgun, and no *new*
thread-safety concept — the interloper is already `Mutex`-guarded. If the
agent was built without an interloper, `bind` sees `nil` and
`schedule_load_skill` raises "no interloper wired — construct the Agent
with `interloper:`". (Alt C2: host passes the same `Interloper` to both
`Agent.new` and the extension ctor — simpler surface, but wires one object
into two places and invites the give-it-to-one-not-the-other bug.)

## ruby_llm findings (checked against ruby_llm 1.16.0)

**`complete` needs no user message.** `Chat#ask` is just
`add_message(:user) + complete`; `complete` sends whatever `@messages`
holds (`chat.rb`). So a `complete` whose tail is `:system` is fine at the
ruby_llm layer — no synthetic user turn required.

**Providers diverge on `:system` messages — this is the load-bearing
fact.**
- *OpenAI-family* (llama.cpp default, ollama, openai, deepseek, mistral,
  xai, …): `format_messages` maps every message **in order**, `:system` →
  `system`/`developer` (`providers/openai/chat.rb`). Trailing system
  stays inline; the model completes against it. Bare-load works.
- *Anthropic*: `render_payload` **partitions every `:system` message out
  of the conversation and hoists it into the top-level `system` param**,
  irrespective of position (`separate_messages` →
  `partition { role == :system }`, `providers/anthropic/chat.rb`). So:
  1. A host-loaded skill injected as `:system` lands in the **system
     prompt**, not as an inline observation — and, staying a `:system`
     message in `@chat.messages`, it is **re-hoisted on every subsequent
     request** (the skill is *sticky*, unlike the `skill` tool's one-time
     `:tool` observation). For skills-as-guidance this is arguably fine,
     even desirable, but it's an honest semantic difference from the tool.
  2. A **bare-load into a fresh conversation** (no prior user/assistant/
     tool turns) leaves the Anthropic `messages` array **empty** → 400.
     Handled by the run-entry guard above (≥1 non-system message, else
     `false`).

**Net:** the `:system` choice stands. Default (llama.cpp) is fully
correct; Anthropic works mid-conversation, differs only in making a
loaded skill sticky, and the one hard edge (fresh-convo skill-only) is
the same no-op the guard already returns. No synthetic user turn, no ugly
fallback needed.

Residual decision (**resolved** — go with the default `:system`): on the
default provider (llama.cpp / OpenAI-family) `:system` is **not hoisted**
— the skill body lands positionally right after the load invocation, the
wanted behavior. Anthropic is the only backend that hoists `:system` into
the top-level system param, making the loaded skill *sticky*; that
divergence was researched and accepted (one-time, cache-cost-free today,
and it reuses the `:system`-injection pattern pikuri already ships for
recalled memory). Full analysis + the one open semantic call (sticky vs
one-shot) live in [[anthropic-skill-stickiness]]. The lever if it ever
proves wrong is the role (`:user` = positional + non-sticky everywhere,
at the cost of framing trusted skill text as user input) — not worth it
now.

## Settled forks (kept for the record)

- **A — branch vs enqueue:** *enqueue-only* won. `schedule_load_skill`
  never branches on agent state; the host drives the loop. Threading
  forced this — `schedule_load_skill` runs on the UI thread and must not
  block or reach into the worker.
- **B — idle UX:** *active* — a bare load runs a real turn and the agent
  responds. That's the wanted UX; the host opts into it by running the
  loop with `nil` message.

## Sub-agent scope

Extensions fire on the parent agent only; sub-agents inherit toolset +
prompt verbatim, not extensions (sub-agent-propagation seam), and the
interloper is already main-agent-only. So `schedule_load_skill` is
main-agent-only. No new decision.
