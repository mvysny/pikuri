# pikuri-memory

Durable, cross-conversation memory for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit:
facts about the user and their work that persist across
conversations, backed by [mem0](https://github.com/mem0ai/mem0).

Wire it onto a `pikuri-core` agent the same way as `pikuri-tasks` /
`pikuri-vectordb` — `c.add_extension` inside the `Agent.new` block:

```ruby
require 'pikuri-memory'

client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://localhost:8888')

Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension Pikuri::Memory::Extension.new(client: client, user_id: 'martin')
end
```

## What you get

Three retrieval tiers, the same layered shape `pikuri-vectordb`
uses (`vectordb_search` + `vectordb_read`):

1. **Resident persona** — a small always-in-prompt summary of what
   the agent already knows about the user, appended once at
   construction.
2. **Automatic prefetch** — every user turn is embedded and
   searched; a small, high-precision slice is injected as a
   `:system` `<memory-context>` block right after the turn.
3. **`recall` tool** — explicit, topic-driven deepening when the
   agent wants more than the automatic slice surfaced.

Recall is automatic and **synchronous** (a vector search is
milliseconds). Capture is automatic and **asynchronous** — a
background worker drains user turns into mem0's extraction call
(~seconds), so a turn never blocks on "what should I remember?".

## Safety

Automatic capture and recall are safe only on an agent with **no
untrusted ingest and no egress** (pikuri's `@private` member): a
poisoned memory plus an outbound leg is the lethal trifecta. Two
structural defenses keep the capture pipeline honest:

- **Only the user's own words** are fed to extraction — assistant
  turns, tool results, and recalled context are never captured.
- **Recalled context lands as `:system`**, never as a user turn, so
  it cannot be re-extracted into a self-reinforcing feedback loop.

Do not port memory onto an egress-capable agent without re-deriving
the recall-poisoning mitigations.

## Storage: bring your own mem0 (for now)

This release ships the Ruby surface — `Mem0Client`, `Extension`,
`Recorder` (the async capture queue), and the `recall` tool —
against a **bring-your-own** mem0 server you point `Mem0Client` at. The
server must use the **Qdrant** vector backend (the pgvector path has
a top-k inversion bug), a local OpenAI-compatible LLM + embedder
(llama.cpp via `openai_base_url`), and a non-reasoning extraction
model. A self-managed mem0 sidecar supervisor (the `ChromaServer`-style
docker pattern) is a planned follow-on.

## Install

```ruby
# Gemfile
gem 'pikuri-memory'
```

Depends only on `pikuri-core`.
