# Sub-agent / persona deferrals

Status: **v1 shipped, follow-ups deferred.** The persona-driven `agent`
tool (`RESEARCHER` / `FILE_MINER` / `GIT_REPO_RESEARCHER`) shipped, wired
via `c.add_extension Pikuri::SubAgent::Extension.new(personas: [...])`.
Rationale and the privilege-separation argument live in the YARD on
{Pikuri::SubAgent::SubAgentTool} / {Pikuri::SubAgent::Persona} /
{Pikuri::SubAgent::RESEARCHER} / {Pikuri::SubAgent::FILE_MINER} /
{Pikuri::Code::GIT_REPO_RESEARCHER}; the cross-harness comparison and
bundled-persona inventory live in [`design/research.md`](../research.md)
`R_sub_agents`. Only the deferrals stay here.

Related:

- `book/trifecta-detector.md` — the per-persona toolset is the
  privilege-separation unit the shipped detector measures (one map node per
  persona, via `Extension#trifecta_contribution`).

## Persona-owned tools

Letting a `Persona` carry its own tool *instances*, rather than naming ones
the host registered. Deferred, and **not** the fix for the quarantined-corpus
wiring it was long blamed for: `add_sub_agent_tool` already hides a tool from
the parent's LLM while a persona's `tool_names` still reaches it
(`sub_agent_tool.rb:91`), which is all that case needs — see
[`vectordb-deferrals.md`](vectordb-deferrals.md).

What would earn this is a child needing a tool **configured differently**
from the parent's, not merely hidden from it: a `Read` over a narrower
`Filesystem`, a `Bash` with a tighter sandbox. pikuri-workshop's
`GIT_REPO_RESEARCHER` is that case: its file tools and `git_clone` share a
fresh temp workspace per invocation. pikuri carried a one-purpose version
(`Persona#needs_temp_workspace` plus a `with_workspace` hook on four file
tools) until 2026-11-15, and dropped it because no pikuri persona used it. If
the workshop asks for it back, this is the general shape to build.

## Catalog / `.md` discovery

The current shape ships personas as Ruby constants
(`Pikuri::SubAgent::RESEARCHER`); good enough while we have one. Once we
ship 3+ and users want to author their own, the original proposal
(Markdown + YAML frontmatter, discovery under `.pikuri/personas/*.md` /
`.claude/agents/*.md` / `.agents/personas/*.md`, new `pikuri-personas`
gem with `Catalog` + `Extension`) becomes the natural next step.
Tool-name validation flips from raise → WARN-and-prune at that point so
a persona referencing an unwired tool just disappears.

## Extension re-propagation

Sub-agents no longer inherit extensions (MCP / Skills); `configure` is
called once, on the parent only. If a persona later needs MCP-backed
tools, the redesign starts from scratch — likely a Persona field
declaring which extensions the child also wires in.

## Per-persona `model:`

PI has cheap-model-for-cheap-tasks (haiku for scout, sonnet for
planner). Real efficiency win, requires `ChatTransport` variations per
sub-agent. Deferred.

## LLM-authored personas

Originally floated and deferred; the escape hatch (ship a `general`
persona) still works if it ever matters.

## A child's context overflow ends the parent's turn

`SubAgentTool` lets a child's `RubyLLM::ContextLengthExceededError`
propagate. The parent's `run_loop` `ensure` answers the dangling `agent`
call with `Error: …`, then re-raises, so the whole parent turn dies (and a
`bin/` script exits). Per "errors are loud", a failure the LLM can react
to should come back as a tool error instead, e.g. "the sub-agent ran out
of context before answering; give it a narrower task", and the parent
carries on. This is the one overflow case on pikuri's side; compacting a
child mid-turn is policy and belongs to pikuri-workshop
(`D_compaction_in_place`).
