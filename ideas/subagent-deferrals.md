# Sub-agent / persona deferrals

Status: **v1 shipped, follow-ups deferred.** The persona-driven `agent`
tool (`RESEARCHER` / `FILE_MINER` / `GIT_REPO_RESEARCHER`) shipped, wired
via `c.add_extension Pikuri::SubAgent::Extension.new(personas: [...])`.
Rationale and the privilege-separation argument live in the YARD on
{Pikuri::SubAgent::SubAgentTool} / {Pikuri::SubAgent::Persona} /
{Pikuri::SubAgent::RESEARCHER} / {Pikuri::SubAgent::FILE_MINER} /
{Pikuri::Code::GIT_REPO_RESEARCHER}; the cross-harness comparison and
bundled-persona inventory live in [`../COMPARISON.md`](../COMPARISON.md)
§"Sub-agents". Only the deferrals stay here.

Related:

- [`assistant.md`](assistant.md) — the federation reuses `Agent` +
  `Persona` wholesale but human-routes siblings instead of LLM-routing
  children; the "which extensions a child wires" question below is the
  federation's inverse.
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

## Persona-owned tools (and the mediated-recall wiring it's blamed for)

The motivating want: hand the corpus to a `LIBRARIAN` child while the boss
holds no `vectordb_*` tool of its own — the quarantine `pikuri-assistant`
needs, and the reason `book/assistant.md` stays a stub.

**Check the premise before building anything.** That chapter says it is
impossible because "a sub-agent's tools are a strict subset of the parent's",
and that is **not** what the code does: `SubAgentTool#execute` filters
`parent.tools + parent.sub_agent_tools` (`sub_agent_tool.rb:91`), and
`Configurator#add_sub_agent_tool` registers a tool the parent's LLM never
sees. `pikuri-code` already ships exactly this shape for the web tools.

The real blocker is narrower and lives in the *other* gem:
`VectorDb::Extension#configure` hardcodes `c.add_tool` for all three tools
(`extension.rb:103–105`), so a host cannot ask for the mediated wiring. Two
candidate fixes, and the cheap one may be enough — a pool choice on that
extension (`mediated:`-shaped), versus the general "a `Persona` carries its
own tool *instances*", which is only earned if a child needs a tool
configured *differently* from the parent's, not merely hidden from it.

Either way `book/assistant.md`'s prerequisite paragraph needs correcting.

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

Sub-agents no longer inherit extensions (MCP / Skills). Two-phase
`configure`/`bind` collapses to "called once on the parent only." If a
persona later needs MCP-backed tools, the redesign starts from scratch —
likely a Persona field declaring which extensions the child also wires
in, plus rebuilding the two-phase split.

## Per-persona `model:`

PI has cheap-model-for-cheap-tasks (haiku for scout, sonnet for
planner). Real efficiency win, requires `ChatTransport` variations per
sub-agent. Deferred.

## LLM-authored personas

Originally floated and deferred; the escape hatch (ship a `general`
persona) still works if it ever matters.
