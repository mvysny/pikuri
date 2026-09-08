# pikuri-subagents — CLAUDE.md

This gem's must-not-break list, loaded beside the root `../CLAUDE.md`
when work touches this directory. One-line invariants + pointers only;
the truth lives in the cited yardoc, roads not taken in `../DECISIONS.md`.

## Seams (invariants)

- **Sub-agent propagation.** Listeners and tools travel through `for_sub_agent` (root protocol); controls don't — the child shares the parent's `Cancellable` by reference so one Ctrl+C stops the tree. A child inherits **no extensions** (each persona owns its toolset + prompt verbatim) and **no skills** — the persona's prompt is its complete brief. See {Pikuri::SubAgent::SubAgentTool}, {Pikuri::SubAgent::Persona}, `DECISIONS.md` `D_no_skills_in_sub_agents`.
- **Consumed seams.** `agent` is network-dispatching, so it takes a `Workspace::Confirmer` (**Confirmer seam**, `../pikuri-workspace/CLAUDE.md`). A child's loop is as unbounded as the parent's, and a permit is held per *request*, never per turn — otherwise the parent deadlocks against the child (root **Request-permit seam**, **The loop is unbounded**).
- **Persona prompts (`prompts/persona-*.txt`) may name their tools** — the one carve-out from the root's no-tool-names convention, because `tool_names:` + `system_prompt:` are co-located.
