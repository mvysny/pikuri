# Architecture

The bird's-eye map of the code as it is: the major pieces, how they are wired, and the flows that
cross several of them. **The code and its yardoc are the authority; this file describes them.**
When they disagree, fix this file.

Keep it short. Anything true of one class belongs in that symbol's yardoc; a gem's *internal*
cross-symbol picture belongs in its own `<gem>/design/architecture.md`; the map of which gem is
which is `../AGENTS.md`'s, because an agent needs it on every turn. This file starts where those
stop — how the gems work together in one process: dependency direction, the lifecycle and
threading story, and where a newcomer should start reading. Cite `R_` for what must hold and `D_`
for why; argue nothing here. **The first entry in each section is the ruler** — later entries are
trimmed to its length, never the other way round.

---

## Wiring

- Dependencies point **toward data, never toward the loop**. The gem graph is a DAG rooted at
  `pikuri-core`, which depends on no sibling; a few gems stack on each other besides
  (`rag` → `vectordb`, `os` → `code`, `code` → `workspace` + `subagents` + `tasks`). A tool, a
  listener or an extension names `Pikuri::Agent`; `Agent` names none of them, which is why a new
  gem is additive and core never learns about it.
- `Pikuri::Agent.new(transport:, system_prompt:) { |c| … }` is the only construction path. The
  block is handed a {Pikuri::Agent::Configurator}, which collects tools, listeners, `on_close`
  handlers and {Pikuri::Agent::Extension} instances; `#initialize` drains it into the agent's
  wiring and discards it. An `Extension#configure(c)` takes that same Configurator, so a host's
  block and a gem's extension share one API.
- Two seams meet on the `Agent`, pointing in opposite directions. **Listeners** are pure consumers
  of the {Pikuri::Agent::Event} stream and never write back; **Controls**
  ({Pikuri::Agent::Control::Cancellable}, `Control::Interloper`) are host-facing signal holders the
  agent reads at fixed boundaries. A live `Agent` reference is read-only — everything that *acts*
  on a wired agent is on {Pikuri::Agent::ExtensionContext}, handed only to `Extension#bind`.
- `ruby_llm` sits under `Agent` and nowhere else. A connection rides an
  {Pikuri::Agent::ChatTransport} → a per-chat `RubyLLM::Context`, never a process-global
  `RubyLLM.configure`, so N agents in one VM can hold N different models.
- Three process-global registries are the exceptions to "everything hangs off an agent", each
  because the resource is genuinely per-process: {Pikuri::Finalizers} (one `at_exit`),
  {Pikuri::Agent::ServerPermits} (one permit pool per inference *server*), {Pikuri::Paths}
  (one temp root, reaped at exit).
- Untrusted bytes enter through two chokepoints and nowhere else: {Pikuri::Extractor}'s registry
  for format→text conversion, and {Pikuri::Subprocess.spawn} for anything that runs
  (`R_subprocess_chokepoint`). Paths that reach the model are filtered on the way out
  (`R_walked_path_denylist`).

## Flows

**A turn** ({Pikuri::Agent#run_loop}, one thread, unbounded in tool calls):

1. `run_loop` resets `Cancellable`, drains any queued `Interloper` message, appends the user turn
   itself and only then calls `RubyLLM::Chat#complete` — never `#ask`, which bundles append and
   complete atomically and leaves no seam to inject between. ruby_llm owns the iteration from
   here (`D_no_step_limit`).
2. ruby_llm's three callbacks fire back into the agent — `after_message`, `before_tool_call`
   (which is where `Cancellable#check!` runs) and `after_tool_result` — and each emits an `Event`
   on the listener list. That wiring, at construction, is the whole extension surface.
3. A tool runs, composes its own three display strings at `execute` time, and answers a
   {Pikuri::Tool::Result} — always, no other return type.
4. Once the tool *batch* is complete (not per result — the result message does not exist yet at
   `after_tool_result`), the interloper drains again and a pending mid-turn message is delivered.
5. On the way out, an `ensure` answers every tool call left unanswered by an unwinding batch, so
   the next turn cannot post a malformed one (`D_unwound_batch_repair`).

**Boot** (`bin/pikuri-*`, and every real host):

1. The binary builds a `ChatTransport`, reads its config, and calls `Agent.new` with a block.
2. Inside the block each gem's extension calls `c.add_tool` / `c.add_listener` / `c.add_extension`;
   `Finalizers.register` is armed *before* the build phase, so a mid-construction raise still
   fires whatever cleanup was already declared.
3. The agent pulls `system_prompt_snippets` from every extension and assembles the system prompt —
   the one and only `:system` message it will ever hold (`R_no_system_role`).
4. `ContextWindowDetector` probes the server's `/props` unless both its facts are already known,
   memoizing through the same `ServerPermits` registry that rations requests.

## Where to start reading

`pikuri-core/lib/pikuri/agent.rb` — its class header states the two seams, the threading
guarantee and why the loop is unbounded; then `pikuri-core/lib/pikuri/tool.rb` for the shape every
gem's tools take, and any `bin/pikuri-*` for forty lines that wire a whole agent.
