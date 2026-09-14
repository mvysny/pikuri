# pikuri-subagents — AGENTS.md

The `agent` tool, the `Persona` record, the bundled personas and
`bin/pikuri-minions`. Owns what a child agent inherits and what it deliberately does not; a child is
an ordinary `Pikuri::Agent`, so the loop and the tool contract stay `pikuri-core`'s.

## Invariants

- **Sub-agent propagation.** Listeners and tools travel through `for_sub_agent` (root protocol); controls don't — the child shares the parent's `Cancellable` by reference so one Ctrl+C stops the tree. A child inherits **no extensions** (each persona owns its toolset + prompt verbatim) and **no skills** — the persona's prompt is its complete brief. See {Pikuri::SubAgent::SubAgentTool}, {Pikuri::SubAgent::Persona}, `design/decisions.md` `D_no_skills_in_sub_agents`.
- **Consumed seams.** `agent` is network-dispatching, so it takes a `Workspace::Confirmer` (**Confirmer seam**, `../pikuri-workspace/AGENTS.md`). A child's loop is as unbounded as the parent's, and a permit is held per *request*, never per turn — otherwise the parent deadlocks against the child (root **Request-permit seam**, **The loop is unbounded**).
- **Persona prompts (`prompts/persona-*.txt`) may name their tools** — the one carve-out from the root's no-tool-names convention, because `tool_names:` + `system_prompt:` are co-located.

Maintenance: the root `AGENTS.md`'s rules; cap 10 KB.
