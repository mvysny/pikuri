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

## Workspace modes

The persona record today has a narrow `needs_temp_workspace:` boolean
(used by `Pikuri::Code::GIT_REPO_RESEARCHER`) but no broader
`workspace_mode:` field. File-miner and Researcher work fine on
`inherit` semantics — child reuses parent's `Filesystem`-bound tool
instances by reference, no reconstruction. The interesting modes
from the original proposal stay queued:

- `inherit` — current behavior; what's implicit when the field is
  absent.
- `readonly` — derived `Filesystem` where every parent root is
  readable, none writable. No clones, no extracts.
- `readonly_with_temp` — same plus a fresh `temp:` scratchpad as the
  only writable spot (git-clone / unzip / `mvn dependency:sources`).
  Generalizes `needs_temp_workspace: true` from a single-purpose
  boolean to a composable mode — `GIT_REPO_RESEARCHER` becomes the
  first user once this lands and stops being a special case.

Adding these means promoting `needs_temp_workspace:` to a
`workspace_mode:` enum on the `Persona` record (default
`:inherit`) and a
`Pikuri::Workspace::Filesystem.scoped_readonly_from(parent, with_temp:)`
primitive in `pikuri-workspace`. The fs-touching tools all take
`Filesystem` via constructor today, so the reconstruction is
mechanical — but `bash` would also need `Confirmer::AUTO_APPROVE`
in those modes (the user already approved by picking the persona;
every command still flows through `Event::ToolCall` for audit).
fs-readonly doesn't stop network exfil or fork bombs, so a
`sandbox:` frontmatter key composing with `Code::Bash::Sandbox::Bubblewrap`
is the eventual follow-up.

## Persona-owned tools

Letting a `Persona` carry its own tool *instances*, rather than naming ones
the host registered. Deferred, and **not** the fix for the quarantined-corpus
wiring it was long blamed for: `add_sub_agent_tool` already hides a tool from
the parent's LLM while a persona's `tool_names` still reaches it
(`sub_agent_tool.rb:91`), which is all that case needs — see
[`vectordb-deferrals.md`](vectordb-deferrals.md).

What would earn this is a child needing a tool **configured differently**
from the parent's, not merely hidden from it: a `Read` over a narrower
`Filesystem`, a `Bash` with a tighter sandbox. That is the workspace-modes
item above wanting per-persona reconstruction, so the two land together or
not at all.

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
