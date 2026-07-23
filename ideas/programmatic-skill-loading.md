# Programmatic (host-driven) skill loading

**Goal.** Let a UI host (TUI / web) load a skill into the agent's context
window *on the host's initiative* — the same body the `skill` tool would
inject, but triggered by a UI affordance (a "load skill" menu / slash
command), not by the LLM deciding to call the tool. The UX MV wants (and
misses from Claude CLI): load a skill and have the agent *say something*.

Status: **brainstorm, converged; ready to build.** No code yet. The
load-bearing ruby_llm question is resolved (see *ruby_llm findings*); only
a minor role residual remains, noted-not-blocking.

## The design

`Skill::Extension#schedule_load_skill(name)` — on the extension the host
already constructs and keeps. **Schedule**, not do: it only *enqueues*.

```ruby
ext   = Pikuri::Skill::Extension.new(catalog: catalog)
agent = Pikuri::Agent.new(..., interloper: interloper) { |c| c.add_extension(ext) }

ext.schedule_load_skill('how-to-bake-a-cookie')   # enqueue only — nothing runs yet
agent.<run>(user_message)                          # host drives the loop; skill lands here
agent.<run>(nil)                                   # or: no user message → bare skill turn
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
  skill = catalog.get(name) or raise KeyError   # UI enumerates catalog ⇒ miss is a host bug
  interloper.inject_skill(render(skill))         # typed :system item; returns nothing runnable
  skill
```

- **Miss → raise `KeyError`.** Loud-errors ethos; the UI only offers
  names from `catalog.list`.
- **Fidelity: exactly as if `skill` was called.** `render(skill)` is
  **byte-identical** to `SkillTool`'s output (`<skill name= location=>`
  wrapper + "sidecar paths are relative to …" note + body). That string
  is inline today in `SkillTool#execute` (`skill_tool.rb:58-64`); extract
  it to a shared formatter both call — `Skill#to_context_block` /
  `Catalog#render(skill)`. (COP: one box owns the render; neither caller
  clones it.) Injected as `role: :system` — faking a synthetic
  tool_use/tool_result pair to match the *role* literally is brittle
  (providers validate the pairing) and the framing carries the meaning,
  not the role.

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

**Run entry with no user message — the guard (MV's instinct, made
provider-safe).** `run(message = nil)`:
1. drain pending injections;
2. if `message` is `nil` **and** the conversation still has **no
   non-system message** to complete against → **return `false`** (nothing
   done). This covers both "nil message + empty interloper" *and* the
   fresh-conversation skill-only case that would otherwise 400 on
   Anthropic (see findings). Bare-load mid-conversation proceeds normally
   — there are real turns in the array.

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

Residual decision (minor): the Anthropic stickiness means a
programmatically-loaded skill persists in the system prompt for the rest
of the conversation. If that ever proves wrong, the lever is the role —
`:user` would keep it positional + non-sticky everywhere but frames
trusted-but-not-user skill text as user input. Not worth it now; noted.

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
