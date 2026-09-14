# Architecture

How the gems compose in one process — what no single symbol can say and what would be expensive to
overturn: wiring and dependency direction, the lifecycle and threading story, the flows a newcomer
needs, where to start reading. **Normative: the code conforms.** Change this file first, then the
code.

Not here: why (`decisions.md` — cite the `D_`), what upstream does (`research.md` — cite the `R_`),
one symbol's behaviour (its yardoc), the module map (`../AGENTS.md`), a gem's *internal*
cross-symbol picture (its own `<gem>/design/architecture.md`). Only the sections with content; the
first entry in each is the ruler. Cap 12 KB — over it, research or yardoc content has crept in.

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
  for format→text conversion, and {Pikuri::Subprocess.spawn} for anything that runs. Paths that
  reach the model are filtered on the way out ({Pikuri::Workspace::Filesystem#denied?}), which is
  what keeps the **Privacy first** promise at the file boundary.

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
   the one and only `:system` message it will ever hold (`D_reference_text_as_user_turn`).
4. `ContextWindowDetector` probes the server's `/props` unless both its facts are already known,
   memoizing through the same `ServerPermits` registry that rations requests.

## Where to start reading

`pikuri-core/lib/pikuri/agent.rb` — its class header states the two seams, the threading
guarantee and why the loop is unbounded; then `pikuri-core/lib/pikuri/tool.rb` for the shape every
gem's tools take, and any `bin/pikuri-*` for forty lines that wire a whole agent.

## What is deliberately absent

- **No provider abstraction of our own** — multi-provider config, vision/audio and embeddings are ruby_llm's (`bin/pikuri-corpus` already uses its `embed`).
- **No context compaction** — the `bin/` scripts `exit 1` on overflow, a demo shortcut rather than a library position (`design/ideas/context-overflow-behavior.md`).
- **No step cap on the loop**, at any depth (`D_no_step_limit`).
- **No batch or patch edit tool**, and no fuzzy edit addressing (`D_single_hunk_edit`).
- **No session store**, so no resumable or worktree-isolated sub-agents.
