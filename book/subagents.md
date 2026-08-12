# Sub-agents

This chapter introduces exactly one new concept on top of the
first-conversation chapter: **delegation**. Letting the model
spawn a fresh agent — with
its own narrow toolset and its own focused system prompt — to
handle a self-contained side-quest, and absorbing only the final
summary back into the parent conversation. It's the smallest
extension you can wire onto a `Pikuri::Agent`, and the demo binary
makes the fan-out shape concrete.

By the end of this chapter you'll know what a *persona* is, what a
*pikuri extension* looks like (the `configure` + `bind` dance
you'll see again in the MCP chapter with MCP and the coding-agent chapter with the
file/shell stack), and what gets inherited vs. owned when a
parent spawns a child.

The defaults — local llama, no tools that could send your data
out, verified MCPs — are designed to be safe even with real data;
[the security chapter](security.md) explains why. Sub-agents are actually
where the privacy story starts to *do work*: the persona system
in this chapter is also pikuri's main privilege-separation
mechanism, and the security chapter will name it as the cheapest line in
the defense kit.

## Prerequisites

You've finished [the first-conversation chapter](chat.md), `llama-server` is still
running on `localhost:8080`, and `bundle install` has been done
since you cloned. If those are true, you're ready.

## 1. Run the minions demo

`bin/pikuri-minions` is a "boss + minions" binary: the boss agent
has the four network/arithmetic tools from the first-conversation chapter *plus* the
`agent` tool, and one persona — `RESEARCHER` — is wired in as a
delegate.

```sh
./pikuri-subagents/bin/pikuri-minions
```

You'll get the same `>` prompt as `pikuri-chat`. Try the example
the binary prints on startup:

```
> Plan a 2-day trip to Reykjavik — weather, three sights, two restaurants.
```

What you should see: the boss reasons about the question, then
emits **three `agent` tool calls in a single turn** — one for each
independent sub-question (weather, sights, restaurants). Pikuri
spins up three `researcher` minions in parallel, each on a clean
conversation with only `web_search` / `web_scrape` / `fetch` and
the researcher's focused system prompt. Each minion does its
lookups and replies with one paragraph plus source URLs. The boss
receives the three replies as observations and weaves them into a
single coherent trip plan.

The terminal listener prefixes each minion's output with its id
(`researcher 0`, `researcher 1`, `researcher 2`) so you can tell
the fan-out apart from the boss's own work.

## How delegation looks on the wire

From the model's perspective, delegation is *just another tool
call*. The Thought → Tool-call → Observation loop is the same loop
from the first-conversation chapter; the `agent` tool happens to spawn a fresh
`Pikuri::Agent` instead of computing arithmetic or hitting Brave
Search.

What pikuri actually does when the boss calls
`agent(name: "researcher", task: "...")`:

1. Look up the persona named `"researcher"` (it's `RESEARCHER`,
   the one bundled persona pikuri-subagents ships).
2. Mint a fresh `Pikuri::Agent` configured per that persona: its
   `system_prompt` replaces the boss's; its tools are the subset
   of the boss's tools the persona named
   (`web_search` / `web_scrape` / `fetch`); its step budget is a
   fresh `StepLimit` at the persona's `max_steps` (20).
3. Run the new agent's Thought → Tool-call → Observation loop on
   a clean message history — the `task` string is the entire user
   message the child sees.
4. When that loop terminates with a final assistant answer, return
   *only that text* to the boss as the next observation.

The child runs the same loop `pikuri-chat` does, with the same
`Pikuri::Tool` instances the parent owns (same `web_search`, with
whatever rate-limiting and provider cascade you configured). All
persona-level isolation is on which tools the child can *see*, not
on what those tools do.

## The Persona record

A persona is a five-field value object — `Pikuri::SubAgent::Persona`:

```ruby
Persona.new(
  name:          'researcher',
  description:   'Focused web research with web_search, web_scrape, fetch. ...',
  tool_names:    %w[web_search web_scrape fetch],
  system_prompt: Pikuri.prompt('persona-researcher'),
  max_steps:     20
)
```

- **`name`** — short identifier. The LLM passes it as the `name:`
  arg to the `agent` tool, and it roots the child's listener id
  (`"researcher 0"`, `"researcher 1"`, ...).
- **`description`** — one-liner that shows up in the
  `<available_agents>` block appended to the *parent's* system
  prompt. This is the LLM's only source of "when should I pick
  this persona?" — keep it crisp.
- **`tool_names`** — the names of parent tools the child may use.
  Extension validates at configure-time that every entry resolves;
  at spawn-time the `SubAgentTool` filters `parent.tools` by this
  list.
- **`system_prompt`** — the *entire* system prompt the child runs
  under. No inheritance: the parent's prompt is not visible to the
  child, and the persona's prompt is not appended to anything.
  Hosts typically load this from a `.txt` under their gem's
  `prompts/` via `Pikuri.prompt(name)`.
- **`max_steps`** — per-task step budget. Each invocation gets a
  fresh `StepLimit` at this value, so one minion exhausting its
  budget doesn't reduce the next minion's budget.

The bundled `RESEARCHER` is the one you just saw fan out. Its
prompt lives at `pikuri-subagents/prompts/persona-researcher.txt`
— plain text, audit it if you're curious.

## The Extension protocol (configure + bind)

You met `Pikuri::Agent::Extension` implicitly when you read the
source of `bin/pikuri-minions`:

```ruby
agent = Pikuri::Agent.new(...) do |c|
  c.add_tool Pikuri::Tool::WebSearch.build
  c.add_tool Pikuri::Tool::WEB_SCRAPE
  c.add_tool Pikuri::Tool::FETCH
  c.add_tool Pikuri::Tool::CALCULATOR
  c.add_extension Pikuri::SubAgent::Extension.new(
    personas: [Pikuri::SubAgent::RESEARCHER]
  )
end
```

`add_extension` is the host-facing seam for any package that wants
to add capabilities to an agent. An extension implements a handful
of hooks, all with empty defaults so each extension only writes
the ones it needs:

- **`configure(c)`** — agent-agnostic setup. Runs once during the
  `Agent.new` block, against the `Configurator` itself (the `c`
  yielded into the block). `SubAgent::Extension#configure`
  validates that every persona's `tool_names` resolves against
  tools already on `c.tools` (host-side bug — better to crash at
  boot than at first LLM call).
- **`system_prompt_snippets`** — returns this extension's
  contributions to the system prompt as an array of strings.
  `SubAgent::Extension` returns the `<available_agents>` block here.
  The agent *assembles* the full prompt from its base plus every
  extension's snippets, both at construction and again on
  `clear_conversation` — so a snippet read from live state (a memory
  persona, a notes file) refreshes when the conversation is cleared
  instead of freezing at boot.
- **`bind(ctx)`** — agent-keyed setup. Runs once the agent is
  fully constructed, with the agent's
  `Pikuri::Agent::ExtensionContext` — the capability facade for
  everything that acts on a live agent (the agent itself is
  readable via `ctx.agent`). `SubAgent::Extension#bind` constructs
  the `SubAgentTool` closing over the context (for the parent's
  `transport` / `tools` / `cancellable` / `context_window_cap` /
  `streaming`, plus per-spawn listener derivation), then installs
  it via `ctx.add_raw_tool`. It has to happen here, not in
  `configure`, because the closure needs the *final* parent tool
  list — which is only stable after every other `add_tool` has
  run.

Same shape used by `Pikuri::Skill::Extension` and
`Pikuri::Mcp::Extension`. You'll see it again in the MCP chapter (MCP)
and the coding-agent chapter, where the coding agent wires four extensions at
once.

**Practical implication of the configure/bind split:** call
`c.add_extension` *after* the `c.add_tool` calls the personas
depend on. The `tool_names` validation in `configure` runs against
`c.tools` as of that moment; `add_tool` calls landing later go
unseen.

## What's inherited, what's owned

A sub-agent isn't a clone of its parent. The split:

**Inherited from the parent (shared by reference):**

- **`transport`** — the same `ChatTransport`, so the parent and
  all its children hit the same LLM server with the same model
  identifier. One connection, one bill, one set of rate-limit
  headers.
- **`cancellable`** — the same `Cancellable` flag. One Ctrl+C at
  the boss's prompt cancels the boss *and* every minion below it,
  at the next tool-call boundary.
- **`context_window_cap`** — the cap detected once when the parent
  was constructed (via `llama_probe_url` or ruby_llm's registry).
  Children inherit it rather than re-probing.
- **`streaming`** flag — propagated so the whole tree streams or
  doesn't, consistently.
- **`listeners`** — but routed through
  `ListenerList#for_sub_agent(id:)` first, so the bundled
  `Terminal` listener can pad its prefix with the child's id,
  `TokenLog` can tag the child's per-agent snapshot, and
  `RateLimited` can split its budget. Listeners that want
  sub-agent awareness implement `for_sub_agent`; ones that don't
  fall through to the default.

**Owned by the persona (replaced wholesale):**

- **`system_prompt`** — the persona's, verbatim. Not appended to
  the parent's, not concatenated; the parent's prompt is invisible
  to the child.
- **`tools`** — the subset of `parent.tools` whose `name` appears
  in `persona.tool_names`. Same *instances* the parent uses, so
  any workspace/confirmer wiring already on those tools comes
  along.
- **`step_limit`** — a fresh `StepLimit` at `persona.max_steps`.
  Independent budget per invocation.
- **`interloper`** — `nil`. Sub-agents can't accept mid-loop user
  input; they're driven by the parent.

**Not inherited at all:**

- **Extensions.** The parent's `extensions` list is not threaded
  into the child. If a persona needs MCP or skills, the persona is
  responsible for its own wiring — neither comes free from the
  parent. This is what makes recursion structurally impossible:
  no bundled persona lists `agent` in its `tool_names`, so a child
  has no way to call `agent` again.

If you find that last bullet surprising, it's worth a second look
— it's pikuri's main privilege-separation story.

## Why the no-inheritance rule is the whole point

A `RESEARCHER` spawned from a chatbot is one thing. A `RESEARCHER`
spawned from a *coding agent* with `read`, `write`, `edit`, and
`bash` tools is another: that researcher could in principle
exfiltrate the user's repo over the network if it inherited those
tools.

The persona model rules that out at the structure level rather
than asking the prompt to behave. `RESEARCHER`'s `tool_names`
lists three network-read tools and only those, so even if a
malicious page it scrapes prompt-injects it into "now also call
`bash` to read `~/.ssh/id_ed25519`," the `bash` tool isn't in its
tool list — there is no `bash` to call. The reverse case (a
`FILE_MINER` persona spawned from a chatbot to do code recon) has the
same property in the other direction: it can read files but cannot
reach the network.

[The coding-agent chapter](code.md) makes this concrete: `pikuri-code` wires
`FILE_MINER` (a read-only filesystem-recon persona) so the coding
agent can delegate "find every spec referencing `Foo`" without
polluting its main context, but a prompt-injected `FILE_MINER`
cannot reach `web_search` or `bash` because those aren't in its
`tool_names`.

## What's next

You now know the smallest extension shape (the `configure` +
`bind` pair), and you've seen one persona in action. The next
three chapters — [vectordb](vectordb.md), [memories](memories.md),
and [MCP](mcp.md) — are the buildup toward
`pikuri-assistant`: capabilities that an assistant binary wants
(semantic search over your notes, persistent memories across
conversations, external tool servers). The vector-DB chapter introduces a
second persona — `LIBRARIAN` — and demonstrates the same
privilege-separation argument with the corpus's chunks as the
threat surface. The memories chapter is a stub until that gem lands;
the MCP chapter is the gentle MCP intro using a public book-catalogue
example.

→ Continue to [Agentic search and the vector DB](vectordb.md).
