# IDEAS.md

Things pikuri considered, scoped, and deliberately deferred — recorded
here so a future contributor doesn't read the absence as oversight.
Promote into a real plan when the friction shows up.

Related but different: `COMPARISON.md` "Ideas to borrow" is the
externally-sourced version — "opencode/pi do X, should we?" This file
is the internally-sourced version — "we considered X for pikuri and
punted, here's why."

## Coding-agent deferrals

Carried over from the v1 plan once `bin/pikuri-code` shipped. Each was
in scope of the design exercise, considered, and left out on purpose.

- **Permission system.** opencode's three-action `allow` / `deny` /
  `ask` glob rules. v1 ships with two coarse modes (interactive
  `Tool::Confirmer::TERMINAL` on `Write` / `Bash`; `--yolo` swaps in
  `AUTO_APPROVE`). Revisit once `bin/pikuri-code` has lived a while
  and we know where the friction is. Where things are headed:
  yolo-in-docker, or ClaudeCode's agentic review of the command + automatic approval/denial.
- **Image / PDF in `Tool::Read`.** Read refuses binaries today
  (`lib/tool/read.rb` rejects on a null-byte heuristic). Multimodal
  Read needs vision-capable models and the streaming/encoding path
  ruby_llm exposes but we haven't wired.
- **LSP tool.** opencode wires an LSP client for hover / definition /
  diagnostics. Big-ticket feature; deferred until there's a concrete
  use case beyond "opencode has one."
- **TODO / plan tools.** opencode and Claude Code both maintain a
  per-session todo list the model can edit. Useful, but it's
  session-state machinery pikuri doesn't have today — same blocker as
  resumable sub-agents below.
- **Streaming output from bash.** `Tool::Bash` returns a single
  observation `String`. Live process output is meant to stay on the
  listener stream once we add a TUI; meanwhile callers bound wall time
  with coreutils' `timeout`.
- **Session persistence / resumable sub-agents.** opencode's `task`
  tool persists sub-sessions; `Tool::SubAgent` doesn't. Worth doing
  the day we have any other reason to introduce a session store
  (todo/plan tools being the obvious second customer).
- **Multi-file / multi-hunk Edit.** `Tool::Edit` takes one
  `old_string` → `new_string` per call. opencode bundles batch edits.
  Wait until the cost of separate calls becomes obvious in practice.

## MCP support

Researched in depth, deliberately deferred. Capturing everything so the
next round doesn't have to redo the analysis.

### Does pikuri need MCP at all?

Two answers depending on which binary:

- **`pikuri-code`: probably no, ever.** The coding-agent surface is
  well-served by skills + CLI tools, which is exactly what
  [PI's "what if you don't need MCP?" post](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/)
  argues for. Zechner's numbers are damning for the coding-agent case:
  Playwright MCP eats 13.7k tokens of schema (6.8% of Claude's window),
  Chrome DevTools MCP 18.0k (9.0%); a 225-token README pointing at a
  CLI script delivers the same capability with 60× less context. MCP
  output also has to round-trip through the agent's context every
  time, so chaining "list emails → grep → extract" pays the tax three
  times where shell pipes pay it once. For files / browsers /
  databases / scrapers, skills win on tokens, composability, and
  maintainability (a CLI tool's surface area is its argv).
- **`pikuri-assistant`: yes, eventually.** OAuth-gated SaaS (Gmail,
  Calendar, GitHub, Slack, Linear, Notion, Drive, …) is where MCP
  genuinely earns its keep. Someone else already did the OAuth
  dance — refresh tokens, consent screens, redirect URIs on 127.0.0.1 —
  and packaged it as tools. Rewriting that per-provider would be a
  different sport from writing a CLI scraper. Zechner's post never
  engages with this category; he picks easy targets (browser
  automation is the *worst* MCP use case and the most
  over-represented).

### Design constraint: don't be eager

Both opencode and Claude Code register every configured MCP's tools at
boot, paying the schema cost for the whole session whether or not the
user invokes them this conversation. That violates pikuri's
"start slowly, surface area grows as you grow into it" pitch the same
way a 13.7k-token Playwright schema would. The synthesis with
Zechner's argument is **skill-gated lazy add**:

- Each MCP server gets a *skill* (we already have the catalog).
  `~/.pikuri/skills/gmail/SKILL.md` describes when Gmail is relevant
  and instructs the LLM to call e.g. `mcp.connect("gmail")` as the
  first step.
- The MCP's tool schemas enter context *only after* the skill is
  invoked. Conversation start: zero MCP tokens. User asks about
  email: pay the Gmail schema cost once. Conversation about pure
  coding: never pay Gmail's cost at all.
- This keeps the OAuth value MCP genuinely provides, reuses the
  skill discovery + catalog mechanism we already built, and means a
  user with 8 configured MCPs doesn't carry 60k tokens of dead
  schema every turn.

### Add yes, remove probably no

`RubyLLM::Chat` supports mid-conversation tool addition via
`#with_tool` (just mutates `@tools`, re-read per request). It does
**not** expose a `remove_tool` method — to remove a tool you have to
rebuild the array via `#with_tools(*remaining, replace: true)`. The
mechanism exists; the question is whether to use it.

Recommendation: **add only, never remove.** The argument for removal
("Gmail tools are now dead weight, let's shrink context") is weaker
than it looks:

- The model retains *memory* of past tool calls. If turn 3 has a
  successful `gmail_search` call in history and we strip Gmail at
  turn 5, the model pattern-matches "I used it before, it worked" and
  tries again at turn 7, gets a tool-not-found error, burns 1–2 steps
  recovering. The model has no signal that the capability was
  *withdrawn* — only that something is broken.
- The token savings are modest. Schemas re-send every turn, so 1.5k
  tokens × 20 turns = 30k cumulative — real, but only for long
  conversations, and those are exactly where step-budget pressure is
  already squeezing.
- There's no good auto-trigger. Any heuristic ("not used in 5 turns")
  fires right before the user wants the tool back. The only safe
  reset boundary is "new conversation," at which point starting fresh
  is cleaner than mid-conversation removal.

If we ever do need removal, wrap it in `Agent#with_tools_excluding(names)`
so the ivar poking stays in one place.

### Federated envelope (alternative pattern, parked)

Instead of registering N gmail tools individually, register one
`mcp_call(server, tool, args)` envelope whose *description* is
dynamic. Adding a server appends to the envelope's description rather
than adding new schemas. Sidesteps the "model remembers past schemas"
problem because there never was a per-tool schema. Trade-offs: weaker
provider-side validation, extra round-trip for the model to learn
each tool's exact args. Probably not v1, but worth keeping in mind if
the per-tool registration approach starts hurting.

### Ruby MCP clients evaluated

Three client gems looked at; popularity and runtime-dep impact as of
this write-up. `fast-mcp` is server-focused and excluded.

| Gem | Total downloads | New runtime deps (over pikuri's current Gemfile) |
|---|---:|---|
| `ruby_llm-mcp` (patvice) | ~99k | **3:** `httpx`, `json-schema`, `json_schemer`. (Also depends on `ruby_llm` and `zeitwerk`, both already in pikuri.) |
| `mcp` (modelcontextprotocol/ruby-sdk, official) | ~5.5M | **1:** `json-schema`. |
| `ruby-mcp-client` (simonx1) | ~233k | **2:** `faraday-follow_redirects`, `faraday-retry`. (`faraday` already in pikuri.) |

Reading the table:

- **`ruby_llm-mcp` is the highest-fit by API shape** — its `client.tools`
  returns RubyLLM-compatible tools that plug straight into
  `chat.with_tools(*client.tools)`. But it brings the most new deps
  (3, including `httpx` which competes with our existing `faraday`),
  and pikuri's `Tool` class isn't a `RubyLLM::Tool` anyway —
  we'd still need an adapter to route MCP tools through pikuri's
  strict-validation seam.
- **`mcp` (official) is the cleanest baseline** — one new dep, official
  spec coverage, and we'd write the pikuri-`Tool` adapter anyway. The
  5.5M download number is partly inflated by the generic gem name
  being a magnet, but it's also the gem the spec maintainers ship, so
  it's the most likely to track changes long-term.
- **`ruby-mcp-client` is a middle ground** — only 2 new deps and they
  reuse `faraday`, but the API is lower-level than `ruby_llm-mcp` and
  it's an independent implementation that may lag the spec.

**Decision: when we build it, use `mcp` (official).** One new
runtime dep, spec authority, and the adapter to pikuri's `Tool` is
shaped the same way `Tool::Skill` and `Tool::SubAgent` are — a small
lib class that hangs off a `Tool` subclass via constructor injection.
The `ruby_llm-mcp` headline integration doesn't actually save us code,
because pikuri's `Tool` isn't a `RubyLLM::Tool` — we'd still write
the adapter ourselves. Trading a small amount of integration code for
a narrower dependency surface and keeping the validation-error
contract pikuri commits to.

## Workspace v2

Plans recorded in `lib/tool/workspace.rb`'s "Future extensions" RDoc
section, summarised here so they show up in a doc-only sweep:

- **Multi-root workspace.** A read-set wider than the write-set —
  e.g. `~/.claude/skills` readable, project CWD writable. The
  `Workspace` abstract base already splits `resolve_for_read` /
  `resolve_for_write` to make this seamless.
- **`Tool::Workspace::ALLOW_ALL`.** Unrestricted reads + writes,
  intended for Docker / dev-container mode where the whole sandbox is
  the workspace. Pairs naturally with `--yolo`.
