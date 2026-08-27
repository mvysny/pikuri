# Round-tripping the conversation history (`export_history` / `load_history!`)

Status: **idea, not built.** Origin: [issue #1](https://codeberg.org/mvysny/pikuri/issues/1)
("Agent: round-trip the conversation history"), filed for two downstream
shells — **pikuri-web** (multiple conversations, disk persistence,
sidebar picker) and **pikuri-tui** (`/resume`).

**Correction to the issue, from reading both shells (2026-08-27):** the
`agent.instance_variable_get(:@chat).messages` reach-through **does not
exist in either repo today** — no `instance_variable_get(:@chat)`, no
`@chat.messages`, and no `RubyLLM::Message`/`Content`/`ToolCall`
reference anywhere in either `lib/`. It is *planned*, and named as a
thing never to merge, in
`pikuri-web/ideas/multiple-conversations.md:83` ("the only local route…
never merge it — the whole reason for the ticket is that a store full of
`RubyLLM::Message` objects breaks [its pikuri-free-core
decision]"). **That file is
the upstream of this one** and is much further along than issue #1
suggests: it already carries the two-method API, the system-prompt
exclusion, three ruby_llm sharp edges, and a set of `Q_*` open
questions. Read it before implementing anything here.

Two more corrections worth having on the record:
- **pikuri-web persists nothing today.** `PikuriWeb::Transcript` is an
  in-memory mutex-guarded array of *rendered HTML blocks*; restart and
  the conversation is gone (its single-shared-conversation decision).
  So there is
  no existing format to stay compatible with — v1 is genuinely greenfield.
- **pikuri-tui does not mention `/resume` anywhere** — no `ideas/`, no
  `DECISIONS.md`, no grep hit. The TUI half of the issue is the author's
  inference, not an attested requirement. Design for pikuri-web; let the
  TUI confirm later.

The issue proposes the minimal shape:

```ruby
agent.export_history          # => [Hash, ...] JSON-safe, ordered
agent.load_history!(array)    # replaces history, keeps wiring
```

This note argues for **more than that**, along the line the author drew
when filing it: an exported history is *stored on disk*, so it is a
**file format**, not a return value. A bag of hashes whose shape is
"whatever ruby_llm's `Message#to_h` happened to emit that week" is a
format nobody wrote down, versioned, or validated — and the first shell
that reads back a year-old conversation finds out. So: a typed,
versioned, self-validating value object that *has* a JSON rendering,
with pikuri owning both directions.

Everything below is grounded in ruby_llm 1.16.0 (the pinned version) —
paths are `~/.gem/.../ruby_llm-1.16.0/lib/ruby_llm/`.


## What the shells actually need

Worth separating, because the issue's two methods serve three different
appetites and only two are pikuri's job:

1. **Continue a conversation** — restore enough that the *next*
   `run_loop` is indistinguishable from one that never stopped. This is
   the load-bearing one, and the only one with a hard correctness bar
   (the round-trip property below).
2. **Render a conversation** — a web sidebar showing "3 messages ago you
   asked about X". Needs role + text + ordering, and specifically does
   *not* need thinking signatures or token counts.
3. **Archive a conversation** — read it in five years, diff two runs,
   feed it to an eval. Needs stability above all else.

(1) and (3) push the same way: a written-down format. (2) looked like it
came for free from any readable JSON — and that was wrong.

### (2) is not a subset of (1): the render/replay fork

Reading the shells settles this, and it is the single most structural
finding in the survey so far. Both render the **`Agent::Event` stream**,
not the message list, through near-identical listeners
(`pikuri-web/lib/pikuri_web/sse_listener.rb:65`,
`pikuri-tui/lib/shared/conversation_window.rb:452`) — and what they
display is *lossy on purpose*:

- tool results are **truncated to 200 chars** with a byte-count suffix
  (`sse_listener.rb:225`, `MAX_TOOL_RESULT_CHARS = 200`);
- a `SystemInjected` block is **collapsed to a one-liner** (`⊕ loaded
  skill: <name>`) or dropped entirely;
- streaming deltas are preview-only, replaced by the finalized content;
- `Tokens` / `ContextCap` render as **nothing** — they feed the status bar.

So the rendered transcript cannot be reconstructed from the message
history (the events aren't in it), and the message history cannot be
reconstructed from the rendered transcript (it's truncated and
collapsed). **Neither derives from the other** — pikuri-web's note
reaches the same conclusion independently and calls it "the real fork"
(`multiple-conversations.md:89`), planning a *third* artifact: an
append-only `log.jsonl` of events, replayed through the real listener
with the broadcaster swapped for a null sink, alongside a
`messages.json` rewritten per turn.

The consequence for this note is clarifying, not complicating:

> **`export_history` owns the model-facing half and only that half.**
> The event log is the *shell's* artifact, because the truncation policy
> is the shell's (200 chars is a pikuri-web number, and pikuri-tui
> having the same one is duplication between two shells, not a pikuri
> API). The format's job is fidelity to what the *model* saw; fidelity
> to what the *human* saw is a separate artifact with a separate owner.

Worth stating in the yardoc, because "why doesn't the export contain the
tool output I saw on screen?" is otherwise a reasonable question with a
non-obvious answer — and because a host that persists only the history
and expects to re-render from it will build the wrong thing.


## Thesis: a typed envelope, not `[Hash, ...]`

Sketch (names are up for grabs; `Pikuri::Agent::History` sits naturally
next to `Agent::Event` / `Agent::Control`, and nesting the leaf Data
classes in the one file matches `Lsp::Registry::StdioEntry`):

```ruby
History = Data.define(:version, :messages) do
  CURRENT_VERSION = 1

  def self.parse(json)          # String  -> History, raises on anything wrong
  def self.from_h(hash)         # Hash    -> History, raises on anything wrong
  def to_h                      # -> JSON-safe Hash, string keys
  def to_json(*)                # -> String
end

History::Message = Data.define(
  :id,            # local identifier, minted at creation — see below
  :role,          # "user" | "assistant" | "tool"  (never "system")
  :kind,          # "user" | "reference" — local only, never sent

  :content,       # String, or History::Content when attachments are in play
  :tool_calls,    # [History::ToolCall], ordered — [] when none
  :tool_call_id,  # String on a :tool message, nil otherwise
  :model_id,      # String, nil for user turns
  :thinking,      # History::Thinking or nil
  :tokens         # History::Tokens or nil
)
History::ToolCall = Data.define(:id, :name, :arguments, :thought_signature)
History::Thinking = Data.define(:text, :signature)
History::Tokens   = Data.define(:input, :output, :cached, :cache_creation, :thinking)
```

Why a Data class rather than the issue's plain array of hashes:

- **The class *is* the schema.** "What's in an exported history?" is
  answered by reading one file with yardoc on every field, not by
  exporting a conversation and squinting at the JSON.
- **Validation has somewhere to live.** `from_h` is the one gate; every
  reader gets it. With bare hashes, each shell re-derives its own
  half-validation and they disagree.
- **It decouples the on-disk format from ruby_llm's internals.** This is
  the real prize — see the next section. If ruby_llm 1.17 renames
  `Thinking#signature`, that is a change to *one* mapping function, not
  a silent change to a format sitting in thousands of files on disk.
- **`Data` is already the house value-object** (CLAUDE.md → Conventions),
  frozen, `==`-comparable — which makes the round-trip test one line.

The mapping to/from ruby_llm stays private to `Agent` (or to a
`History.from_chat(messages)` / `#apply_to(chat)` pair). The seam:
**`History` never references `RubyLLM::` in its own fields** — it is a
transport-independent record of a conversation, which is exactly what
makes it safe to write to disk.


## Ground truth: what ruby_llm 1.16 gives us, and where it bites

The issue's "implementation challenges" section is right; here is the
detail, which mostly reinforces *don't build on `Message#to_h`*.

**`Message#to_h` is not a serializer** (`message.rb:87`). It emits
`{role:, content:, model_id:, tool_calls:, tool_call_id:, thinking:,
thinking_signature:}` merged with `tokens.to_h`, `.compact`ed — but
`tool_calls` passes through as the live `Hash{String => RubyLLM::ToolCall}`
and `content` passes through as a live `RubyLLM::Content` whenever
attachments are present. `to_json` on that yields object `to_s` garbage.
It exists for Rails/ActiveRecord persistence, not for us.

**`to_h` and `Message.new` are not inverses.** `to_h` flattens thinking
into two sibling keys (`thinking:`, `thinking_signature:`), while
`Message.new` takes `thinking:` as a `RubyLLM::Thinking` *object*
(`message.rb:26`). Tokens are asymmetric the same way — out as
`input_tokens:`/`output_tokens:`/…, in as either those kwargs *or* a
`tokens:` object (`message.rb:17`). So even the "just use ruby_llm's
own hash" shortcut needs a hand-written load half. Once you're writing
one direction by hand, write both and own the shape.

**`tool_calls` is a `Hash` keyed by id, not an array** — every provider
builds it that way (`providers/openai/tools.rb:91`,
`anthropic/tools.rb:116`, `gemini/tools.rb:81`, `bedrock/chat.rb:385`).
JSON objects don't guarantee key order, and the id is already inside
each `ToolCall`, so **export an ordered array and rebuild the hash on
load** (`h = calls.to_h { |c| [c.id, to_ruby_llm(c)] }`). This is one of
the places where a written-down format is strictly better than the
in-memory shape.

**`ToolCall#arguments` is a bare Hash** whose key types vary by
provider (OpenAI `JSON.parse`s → string keys; others hand-build). A JSON
round trip turns any symbol key into a string, so a naive
`export == reimport` assertion fails on a Gemini conversation while
passing on an OpenAI one. Either normalize to string keys at export
(recommended — it is what the JSON can represent anyway) or accept that
the round-trip property is about the *rendered wire request*, not object
identity. Probably both.

**`Content` may be `String`, `Content`, `Content::Raw`, or `Hash`**
(`message.rb:113` `normalize_content`). Two traps:
- `Content.new` **raises** when text and attachments are both nil
  (`content.rb:14`), but an assistant tool-call turn legitimately has no
  text — `normalize_content` special-cases it to `''` (`message.rb:114`).
  A loader that goes through `Content.new` directly will blow up on
  exactly the message the export exists to preserve.
- `Content::Raw` wraps a provider-specific payload verbatim. Nothing in
  pikuri produces one today; the format should decide whether it is
  representable at all (I'd say **no** — refuse at export with a loud
  raise rather than invent an encoding for an opaque provider blob).

**Attachments are the genuinely hard case.** `Workspace::Read` returns
`RubyLLM::Content.new(note, [resolved.to_s])` for images
(`pikuri-workspace/lib/pikuri/workspace/read.rb:~297`), so a *tool
result* message can carry an attachment whose source is a **workspace
path**, base64-encoded lazily at format time. Three options were on the
table:
- **(a) Path reference.** Small file, but the bytes are re-read at load:
  a resumed conversation can show the model a *different image* than the
  transcript says it saw, or `ENOENT` if the file moved. Silently
  wrong is the worst failure mode we have.
- **(b) Inline base64.** Faithful and self-contained; a handful of
  screenshots turn a 20 KB JSON into megabytes. `MAX_IMAGE_BYTES`
  already caps each one, so the blow-up is bounded but real.
- **(c) Degrade to the note.** Export keeps the `"Read image: … (N bytes,
  image/png)"` text and drops the attachment. Cheap, honest, and *breaks
  the round-trip property* — a resumed vision conversation is missing
  the picture it is discussing.

**Settled (author, 2026-08-27): two encodings, one value — see
*Attachments: two modes* below.** (a) stays rejected outright; the
invisible-failure argument holds and nothing changed it.

**Provider-opaque tokens must survive verbatim.** `Thinking#signature`
(Anthropic) and `ToolCall#thought_signature` (Gemini) are cryptographic
attestations the provider validates on the *next* turn. Drop or mangle
one and a resumed thinking-enabled conversation gets a 400 from the API,
not a graceful degradation. They are load-bearing bytes: export them,
never "normalize" them, never truncate them for display.

**…but a signature is scoped to the model that made it.** This is the
half I missed, and opencode handles it explicitly: on resume under a
*different* model it degrades the reasoning part to plain text and drops
the provider metadata (`message-v2.ts:362`), because the signature only
validates for the producing model/provider. Replaying a Claude signature
into a request to a local llama.cpp — or to a different Claude — is a
400 waiting to happen, and pikuri makes this *likely*, not exotic:
`ModelSwitched` is a shipped feature, `bin/pikuri-chat` has a model
picker, and the whole point of resume is that time passed.

So the rule has a second clause: **export the signature verbatim; on
load, keep it only if the message's `model_id` matches the agent's
current model, else drop it and keep the thinking text.** We already
carry `model_id` per message (ruby_llm populates it), so the check is
free — this is exactly the field earning its place in the format.
opencode also documents a related trap worth knowing before we meet it:
it deliberately preserves an *empty-text* separator part because
dropping it "shifts signed thinking positions" for Anthropic adaptive
thinking (`message-v2.ts:262`) — i.e. the signature can cover position,
not just content.

**`Message#raw`** — the whole provider response object — is deliberately
excluded from `Message#instance_variables` (`message.rb:99`) and from
`to_h`. Keep it out of the format too. It is unbounded, provider-shaped,
and the thing most likely to contain something we didn't mean to write
to disk.


## Do tool calls need preserving? Yes, and they're not optional

The question in the prompt has a sharp answer: **an assistant
`tool_calls` turn and the `:tool` messages answering it are one indivisible
unit on the wire**, and dropping either half produces a history that
providers *reject*, not one that merely reads oddly:

- A `:tool` message with a `tool_call_id` no assistant turn issued → hard
  400 on OpenAI ("tool_call_id did not have a corresponding tool_call")
  and on Anthropic (`tool_result` without `tool_use`).
- An assistant turn with `tool_calls` and no answering `:tool` message →
  the mirror-image 400.

This is the same wire-format constraint CLAUDE.md already records for the
**interloper injection seam** ("an assistant message carrying `tool_calls`
plus the `:tool` messages answering it are one unit on the wire, and
anything appended between them is rejected"). `run_loop` already respects
it mid-turn; a history format must respect it across a *save/load*
boundary, and it is the strongest argument for validation-on-load:

> **Referential integrity is part of the schema.** Every `tool_call_id`
> on a `:tool` message must match a `ToolCall#id` in the nearest
> preceding assistant message, and every issued call must be answered.
> `History.from_h` raises on a violation, naming the offending id.

Something has to enforce this because *hosts will hand-edit these files*
(that is half the point of readable JSON) and because a truncating
"keep the last N messages" context strategy in a shell will cheerfully
slice a batch in half. Better a raise at load than a 400 three turns
later that reads like a provider outage.

### The interrupted batch — opencode has a better answer than mine

The awkward case: the assistant asked for 3 calls and the process died
after 1. My first instinct was "the export refuses, or it drops the
unanswered assistant turn". opencode does neither, and its approach is
better:

**Leave the stored record alone; synthesize the missing result at the
boundary.** Any tool part still `pending`/`running` when the history is
converted into a request becomes a synthetic error result — the stored
row is never rewritten:

```ts
// Handle pending/running tool calls to prevent dangling tool_use blocks
// Anthropic/Claude APIs require every tool_use to have a corresponding tool_result
if (part.state.status === "pending" || part.state.status === "running")
  assistantMessage.parts.push({
    type: ("tool-" + part.tool), state: "output-error",
    toolCallId: part.callID, input: part.state.input,
    errorText: "[Tool execution was interrupted]", ...
  })
```
(`session/message-v2.ts:349`)

Two reasons this beats dropping:

- **It preserves what the model intended.** Dropping the assistant turn
  erases the fact that it decided to call those tools; the resumed model
  re-derives the decision from scratch. Synthesizing an interrupted
  result tells it *"you tried, it didn't finish"* — strictly more
  information, and it happens to be true.
- **It needs no crash-time cleanup.** opencode explicitly does *not*
  reconcile at boot after a SIGKILL; the rule is applied at read time,
  every time. That is sound precisely because the provider constraint
  ("every `tool_use` needs a `tool_result`") is enforced on *every*
  request regardless of what is on disk — so the read-time rule is
  provably sufficient and a storage-repair pass is redundant.

**Where pikuri puts it differs.** opencode patches when building the
wire payload; pikuri doesn't build that (ruby_llm does), so the
equivalent boundary is **`load_history!`**: synthesize a `:tool` message
carrying `"[interrupted]"` for every unanswered call as the history goes
in. Same rule, moved to the seam we own — and it keeps the invariant
"the `Chat` never holds a broken batch" true at all times, rather than
relying on a patch at send.

Which leaves the export side pleasantly dumb: **export whatever is
there, including a dangling batch.** The file is a faithful record; the
repair is a load-time policy. (An in-process `export_history` can't
usually produce one anyway — `run_loop` only returns between batches.
The realistic producer is a crashed process or a hand-edited file, which
are exactly the cases where "record faithfully, repair on load" is the
right split.)

**This is the one thing all four harnesses agree on**, which is worth
noting because nothing else in the survey was unanimous:

| | where the repair happens | what it writes |
|---|---|---|
| opencode | building the wire payload, every time | synthetic `output-error`, storage untouched |
| grok-build | `repair_dangling_tool_calls` on the derived cache | synthetic result, *"cancelled by the user (tool `X` was not executed)"* |
| hermes-agent | `repair_message_sequence` at replay | drops the orphan, transcript untouched |
| PI (in-flight) | restart, from a pre-committed intent record | synthetic `"interrupted"` under a pre-reserved id |

Every one of them repairs on the way *out* and leaves the stored record
alone. That settles the shape; the only open bit is which boundary,
and for pikuri that's `load_history!`.

Two refinements worth stealing from the ends of that table:

- **grok-build also handles the opposite race**: a cancelled call whose
  real result arrives late, giving *two* results for one id
  (`dedup_duplicate_tool_results` — keep the last). So the referential
  check is bidirectional: every call answered, and **answered at most
  once**. Cheap to add to the validator; annoying to discover later.
- **PI classifies tool calls by replay safety** — its `ToolStartedRecord`
  carries `replay: "never" | "safe"`, committed *before* the effect runs,
  so a restart either re-executes a read-only call with the persisted
  arguments or synthesizes an interrupted result for anything that might
  have side effects (`session/types.ts:150`). That is a genuinely nicer
  answer than a blanket "[interrupted]" — but it needs intent journalled
  at call time, which is a live-agent durability feature, not something a
  history format can retrofit. Out of scope here; worth remembering if
  pikuri ever wants crash-resume rather than clean-exit resume.


## Message IDs: local-only, and ours to mint

Settled (author, 2026-08-27): **v1 is a flat list, but every message
carries an `id`.** The wire question that prompted it has a clean answer,
verified against ruby_llm 1.16 rather than recalled.

**Why a list, given that the survey found trees.** Claude Code and PI
both store a real tree (`parentUuid` / `parentId`), with branch points
common in practice — that is what supports edit-a-message-and-regenerate
without rewriting history. pikuri has no consumer asking for it:
pikuri-web wants switching *between* conversations, not rewind *within*
one, and nothing in either shell mentions branching. So a list is the
honest v1. The migration out stays cheap **because of the ids**: a flat
history's implied tree is a linked list, so `parent_id` can be
backfilled on read from position, and a v2 that grows branches doesn't
have to invent identity for records that never had it. Without ids that
backfill is guesswork; with them it is a loop.

### Nothing puts a message id on the wire

- OpenAI's formatter emits exactly `{role, content, tool_calls,
  tool_call_id}` plus thinking fields (`providers/openai/chat.rb:124`).
- Anthropic's emits `{role, content: [blocks]}`; the only ids anywhere
  are `tool_use.id` inside the blocks (`providers/anthropic/chat.rb:164`).
- The `id` on a *response* (`chatcmpl-…`, `msg_…`) identifies the HTTP
  response, not a message you may send back.

**The only wire-carried identifiers are tool-call ids** —
`tool_calls[].id` ↔ `tool_call_id` — which the format already treats as
load-bearing. Everything else is local bookkeeping.

**The exception exists, but not here.** OpenAI's *Responses* API does
carry per-item ids that must be replayed; grok-build stores one for
exactly that reason (`ReasoningContent.id` — *"Original reasoning item ID
from the Responses API. Required when replaying reasoning items in
subsequent turns"*, `conversation.rs:428`). ruby_llm 1.16 has **no**
Responses provider — no `previous_response_id`, no `/responses` across
any of its thirteen providers — so this cannot bite until ruby_llm grows
one. Worth re-checking on a ruby_llm upgrade; it would make an id
suddenly load-bearing.

**And there is no ruby_llm id to preserve.** `Message`'s attributes are
`role, model_id, tool_calls, tool_call_id, raw, thinking, tokens`
(`message.rb:8`) — no `id`. So the question isn't whether ruby_llm keeps
one; it's whether we mint one.

### Why mint one anyway

The reason is the render/replay fork, not the wire. The shell keeps an
event log alongside the message list, and **without ids there is no way
to say "this rendered block corresponds to that message"** — array
indices stop being an answer the moment anything is appended, and
pikuri-web's planned layout has exactly these two artifacts side by
side. Secondary payoffs: it makes a later flat→tree migration free
rather than derivable-on-read, and every id-addressed host API in the
survey needs it (PI's `getEntry(id)`, `setLabel(targetId, …)`).

### The trap: mint at creation, never at export

Two exports of one conversation must produce the **same** ids, or a host
that stored a reference silently loses it. That rules out the obvious
shortcut of generating them in `export_history`. Two workable
mechanisms:

- **A side table on `Agent`**, index-aligned with `@chat.messages`,
  appended wherever a message enters. Two paths cover it today:
  ruby_llm's `after_message` fires for assistant messages (`chat.rb:230`)
  *and* tool results (`chat.rb:385`), while user turns come through
  `agent.rb`'s own `add_message` calls (`:317`, `:679`). Fragile in one
  specific way: if ruby_llm ever adds a message by a third path, the
  array desynchronizes from `messages` **silently**, which is the worst
  failure shape available. Needs an assertion that the lengths match at
  export.
- **Deterministic content-hash ids** (role + content + tool calls +
  index). No side table, nothing to desync, stable across exports of an
  unchanged conversation — but every stored reference silently changes
  the day we change what goes into the hash, i.e. on a pikuri upgrade.

**Lean: minted-and-stored.** References here cross artifacts (event log
↔ history) and persist on disk, so a reference that quietly changes
meaning across a version bump is worse than a length assertion.

**Shape: monotonic and lexicographically sortable** (ULID / UUIDv7),
following opencode — ordering falls out of the id itself with no
sequence column, and imported records keep their own ids without a
rewrite (`identifier.ts:6`). For a flat array ordering is already
positional, so this is belt-and-braces; it costs nothing and it is
precisely what a tree migration would otherwise have to invent.

**Validation:** ids are unique and non-empty within a history. That is a
`from_h` check like any other — and unlike the tool-call referential
check, a duplicate id is harmless to the *model*, so this one exists
purely to keep hosts honest.


## Attachments: two modes, one in-memory value

Two encodings the client picks between:

```ruby
history.to_json               # self-contained: attachments inline, base64
History.parse(json)           # its inverse

history.save(dir)             # dir/history.json + dir/attachments/<name>
History.load(dir)             # its inverse
```

The governing rule, and the thing that keeps this from becoming two
formats: **there is exactly one in-memory `History`, and these are two
encodings of it.** Which implies the property test

```ruby
History.load(dir) == History.parse(json)   # same conversation, either way in
```

so the modes cannot drift apart silently. Both are `version: 1`; the
folder *layout* is part of the format and versioned by the same field.

Why both earn their keep: `to_json` is one pasteable, mailable,
diffable, self-contained artifact (an eval fixture, an attachment on a
bug report). `save(dir)` is what a real host wants — a folder a human
can open and look at, and files a web server can serve without decoding
base64 per render.

**But do not lean on that last argument.** It was claimed here as a
concrete pikuri-web advantage, and checking the repo demoted it to
hypothetical: pikuri-web has four routes (`GET /`, `GET /events`,
`POST /messages`, `POST /cancel`), no `send_file`, no upload, and its
four wired tools (calculator, web_search, web_scrape, fetch) are all
text-only — there is no `read`, so a PNG cannot reach a pikuri-web
transcript at all today. **No shipped consumer produces an attachment.**
Which means the whole attachment question is currently
forward-looking, and the two-mode design has to justify itself on
fidelity and ergonomics, not on a serving path that does not exist.
(It still does: `save(dir)` is the right default regardless. But it is
one mode's *convenience*, not a measured requirement, and the honest
version of "the sensible client picks `save`" is "the sensible client
will, once it has attachments to pick over.")

### The union shape

An attachment in the JSON is a tagged union, never "sometimes a string,
sometimes an object":

```json
{"kind": "inline", "mime": "image/png", "filename": "shot.png", "bytes": "<base64>"}
{"kind": "file",   "mime": "image/png", "filename": "shot.png",
 "file": "3f9a1c8e2b-shot.png"}
```

`filename` is the *original* name (what the model was told); `file` is
where this export put the bytes. Keeping them separate is what lets the
stored name be machine-chosen without lying about provenance.

### What the second mode drags in — five things to decide

1. **`parse` cannot resolve a `file:` ref.** A String has no base
   directory. So `History.parse` **raises a named error** on hitting one
   ("history references external attachments; use `History.load(dir)`")
   rather than silently yielding a History with holes. Loud, per the
   errors-are-loud convention, and it means each door in has exactly one
   job.
2. **`load(dir)` reads a filename out of untrusted JSON**, so a shared or
   downloaded conversation whose `file` is `../../.ssh/id_ed25519` would
   otherwise be a read primitive pointed at the user's home directory.

   **The rule (author, 2026-08-27): `save(dir)` writes every attachment
   into that one folder, no exceptions; `load` refuses any attachment
   reference that is not in that same folder, and raises.** No
   sanitizing, no rewriting a bad path into a good one, no "outside the
   folder" escape hatch for a big file. The folder is the unit, and an
   attachment either lives in it or the history does not load.

   That is better than the sanitize-the-name approach it replaces,
   because it is a property of the *result* rather than of the input
   string: there is no clever encoding to get past, and the check is one
   comparison anyone can verify. It is the same shape as
   `Filesystem#resolve_for_read` — confine, then compare — and it fails
   closed.

   Two mechanical notes so the rule actually holds:
   - **Compare the resolved real path, not the string.** A file sitting
     *in* the folder that is a **symlink** to `~/.ssh/id_ed25519` passes
     any textual check; `realpath` it and confirm the parent is the
     folder. This is precisely the case the rule exists to stop, so it
     is the one that must not be skipped.
   - **The reference is a bare basename**, resolved against the folder —
     never a path, not even a relative one. A separator, a `..`, a
     drive letter or a leading `/` is a refusal, not something to
     normalize.

   Given that, **content-addressed names** (`<sha256-prefix>-<slug>.<ext>`)
   stop being a security measure and become plain convenience — no
   collisions, no name to sanitize, the same image stored once however
   often it was read, and a free integrity check at load. Worth keeping
   for those reasons alone.

   *(Sub-question, cosmetic only: "the same folder" flat, or a fixed
   `attachments/` segment inside it? The invariant is identical — one
   fixed location, resolved-and-compared. Flat keeps `ls` honest for a
   two-image conversation; a subdir keeps `history.json` findable when
   there are fifty. Either is fine; pick when writing it.)*
3. **`save` is not atomic.** Crash between files and you have a JSON
   pointing at bytes that aren't there. **Attachments first, `history.json`
   last** — the JSON is the commit point, so a torn save leaves unreferenced
   garbage (harmless) rather than a dangling reference (broken). Load
   raises on a missing or digest-mismatched file; it never degrades to
   "attachment omitted".
4. **Re-saving.** A host that saves after every turn re-saves the whole
   conversation each time. Content-addressing makes that idempotent —
   skip any file already present with the right digest. Open: does `save`
   *sweep* attachments no longer referenced? Lean **no** — pikuri writes
   into the folder, it doesn't own everything in it, and deleting files
   a user may have dropped there is a worse failure than leaving an
   orphan. Say so in yardoc.
5. **In-memory: eager bytes, always.** `History::Attachment` holds the
   actual bytes, whichever door it came in through. The tempting
   alternative — a `History` loaded from a folder holding lazy
   *references* — reintroduces exactly the (a) failure this design
   rejected (the folder can change or vanish under you), and breaks `==`
   and the convergence property above. Cost is memory bounded by
   `MAX_IMAGE_BYTES` × count; a conversation with fifty screenshots is a
   real problem, and going lazy is still the wrong fix for it.

### Symmetry note

`save`/`load` put filesystem access on what is otherwise a pure value
object. That's tolerable — it's the format's own serializer, the same
way `to_json` is — but if it starts accreting (permissions, locking,
a `.tmp` dance, an index), that's the signal to give the folder layout
its own home (`History::Folder.save(history, dir)`) and leave `History`
a value. Not worth pre-splitting for two methods.


## What is NOT in the history, and why that matters more than it looks

`load_history!` restores messages. It does not restore the *out-of-band
state those messages imply*, and every one of these is a live foot-gun:

- **The read-before-edit gate.** `Workspace#mark_read` /`#read?`
  (`pikuri-workspace/.../workspace.rb:60`) is in-memory. Resume a coding
  conversation and the transcript says the model read `foo.rb` — but the
  workspace has no mark, so the next `edit` is refused with "read it
  first". Confusing, though **failing closed, which is the right
  direction** (the file may well have changed while the conversation was
  on disk — arguably the model *should* re-read).
- **Skill path activation.** `Skill::Activation` holds the
  per-conversation promoted set. A resumed conversation whose skill was
  promoted mid-flight comes back with the skill un-promoted while the
  transcript shows it in use.
- **Task list** (`pikuri-tasks`, in-memory per agent) — the transcript
  shows six completed tasks; the tool reports an empty list.
- **`max_steps`** — reset, per the issue's "controls reset identically to
  `clear_conversation`". Correct: a resumed conversation gets a fresh
  budget.
- **The context readout.** `TokenLog` derives its snapshot purely from
  `Event::Tokens` and zeroes on `Event::Reset` (`token_log.rb:137`). After
  a load, the status line reads `ctx=0.0k/32.0k` on a conversation
  holding 40k of history, until the next assistant reply corrects it.
  This is the issue's third bullet, and it has a cheap fix: since the
  export carries per-message `tokens`, `load_history!` can seed the
  snapshot from the last assistant message's counts (a new
  `Event::HistoryLoaded` carrying them, which listeners no-op on by
  default per the listener contract). pikuri-web reached the same
  conclusion independently (`Q_token_readout`,
  `multiple-conversations.md:272`) — which makes per-message `tokens:` in
  the export the one field justified purely by a *downstream* need, since
  neither shell renders a per-message count today.

The honest framing: **a history round-trip restores the *conversation*,
not the *session*.** PI is independent confirmation that this is a
normal place to stand rather than a shortcut: its shipped session model
persists the conversation and its cost, and has **no** todo, permission,
file-read or skill state at all — a genuine absence, not something the
survey failed to find.

### Where extension state goes: a real three-way fork

I wrote this up as "settled — it doesn't go in the history". The survey
does **not** support that; the three harnesses give three answers:

- **grok-build: separate file per subsystem.** `goal/state.json`,
  `plan.json`, `signals.json`, `announcement_state.json`, each in the
  session dir, none of them in the append-only transcript. And folder
  trust isn't even session-scoped — it's a global `trusted_folders.toml`
  keyed by path.
- **PI: an opaque slot *inside* the transcript.** `CustomEntry` /
  `CustomMessageEntry` are documented in as many words as the extension
  escape hatch — *"Persist extension state across session reloads"*
  (`session-manager.ts:104`).
- **opencode: typed columns on the session row** — `permission`
  (a granted/denied ruleset), `todo` in its own table, `directory`,
  `agent`, `model`.

The synthesis that makes all three coherent, and which I think is the
actual rule: **state whose lifecycle matches the conversation may ride
in the conversation; state with a different lifecycle must not.** Folder
trust is the clinching example — a trust decision must outlive any one
session, so putting it in a session file would be a category error, and
grok-build puts it in a global TOML. Whereas a task list *is* per
conversation, and PI's custom entries are a perfectly reasonable home
for that shape.

Applied to pikuri's four gaps: the task list and skill activation are
conversation-scoped (they could ride along); the workspace read-marks
are arguably *shorter*-lived than the conversation (the file may have
changed on disk while it sat there, so re-reading is correct); and
nothing here is global.

Lean unchanged, but now for a better reason: **document the gaps in v1,
don't build `Extension#export_state` yet** — not because extension state
doesn't belong, but because we can't yet tell which of these is
conversation-scoped enough to be worth the protocol, and PI ships
happily with none of it. The envelope must leave room (a `messages:` key
can grow an `extensions:` key; a top-level *array* — the issue's shape —
cannot). **That alone settles envelope-vs-array.**


## Container: one JSON object, not JSONL — yet

Settled (author, 2026-08-27). The question was whether to write JSONL
from the start so that v2 can simply append instead of overwriting.

**First, the measurement that removes the pressure.** Whole-file
rewrite, `JSON.generate` plus temp-file-and-rename, mean of ten:

| conversation | file | per turn |
|---|---|---|
| 200 messages @ 1.8 KB | 0.39 MB | **1.9 ms** |
| 2000 messages @ 1.8 KB | 3.86 MB | **15.7 ms** |

Against a turn that spends seconds on the model, that is 0.05–0.5%. The
write-often/read-rarely instinct is right about the access *pattern* and
wrong about the constant. And 2000 messages is already well past where
context management forces a compaction, so the second row is a
worst-case that shouldn't occur.

**Rejected outright: "store the whole history as one line, so it's
trivially JSONL too."** It is valid JSONL, but its record type is *an
entire history*. The first append makes line 1 an
envelope-containing-every-message and lines 2..N bare messages — the
file is permanently bimodal, every reader handles both record types
forever, and the property that makes JSONL worth having (one line, one
record) never holds. It also costs diffability *today*: a single-line
blob is one wholly-changed line in `git diff`, where pretty JSON and
real JSONL both show a turn as added lines.

**Deferred, not rejected: real JSONL** (a header record, then one record
per message — PI's `SessionHeader` shape, grok-build's
`SessionUpdateEnvelope`). It costs ~25 lines of writer + reader and buys
a v2 append that changes nothing about the format. The reason to wait is
that a single JSON object keeps **`History` ↔ file 1:1**: `to_json` and
`parse` are literal inverses, the round-trip test is
`parse(to_json) == history`, and the golden fixture *is* the format.
Header-plus-records makes the file an *encoding* of the value, owned by
a writer and a reader that can each be wrong on their own. For a v1
whose whole thesis is a small auditable value type, not having that
layer is the feature.

**The escape hatch, which is why deferring is safe.** Going to JSONL
later is **not** a version bump and **not** a migration — it is a sniff:

> if the whole file parses as a single JSON object, it is the v1
> container; otherwise read it as JSONL.

Three lines, no rewrite of anything on disk, every file ever written
stays readable. That is what makes this a reversible decision rather
than a bet, and it is the condition under which "don't build it yet"
is actually correct rather than merely cheap.

**If append does become real, the rules are already known** — write
them down here so nobody re-derives the segmented-array idea from
scratch:

- **It is JSONL, not numbered `1.json` / `2.json` segments.** Each
  segment would be a JSON *array*, so appending to one means either
  rewriting it (defeating the purpose) or omitting the closing `]` and
  repairing on read — which is JSONL, reinvented, plus a rotation
  threshold, a naming scheme, an ordering rule and a which-segment-is-
  current question that JSONL does not have.
- **The reader tolerates a torn last line** (crash mid-append: drop it,
  keep everything before) and the writer appends whole lines. PI's
  pattern (`jsonl/storage.ts:84`), and the reason it needs one.
- **Note what is lost.** Whole-file rewrite plus atomic rename
  guarantees the file on disk is *always* a complete valid history;
  there is no torn state to detect. Append trades that guarantee for
  O(1) writes. For a **derived** artifact — which this is, see below —
  always-consistent is worth more than always-cheap.

**And the deeper reason the pressure is misplaced.** grok-build's
finding was that the append-only log is *ground truth* and the
model-facing transcript is a rebuildable cache; pikuri-web independently
planned the same split (`log.jsonl` for events beside `messages.json`
rewritten per turn). The append-log the instinct is reaching for already
exists — one layer up, owned by the shell, carrying events. `History` is
the derived snapshot, and a derived snapshot *wants* wholesale rewrite,
because that is what keeps it consistent with itself.

Write amplification, meanwhile, is already handled where it actually
mattered: the expensive bytes are attachments, and content-addressed
sidecars mean an unchanged image is skipped rather than re-encoded.
Re-serializing 400 KB of text per turn is noise; re-encoding 5 MB of
base64 per turn would not have been.


## Stability: what "the format doesn't change" has to mean

Writing `version: 1` is the easy part. The policy is the part that
actually has to be decided, because it constrains every future change:

- **Additive changes keep the version.** A new optional key is readable
  by an old reader (which ignores it) and writable by a new one. This
  requires the validator to *ignore unknown keys*, not reject them —
  the opposite of the strictness we want elsewhere. Deliberate call:
  unknown *keys* are ignored, malformed *known* keys raise.
  (Tension: the "invalid JSON raises" instinct argues for rejecting
  unknown keys too. It loses — forward compatibility is worth more than
  catching a typo'd key, and typo'd keys surface as a missing required
  key anyway.)

  **The survey says this is not merely *a* policy, it is the only one
  anyone actually practises.** opencode has *no* per-record schema
  version at all — evolution is additive JSON fields plus whole-database
  SQL migrations, and grepping all 30 of its migrations for
  `json_set`/`json_remove`/`json_insert` finds none: the blob's shape has
  only ever grown. grok-build is the same by construction —
  `#[serde(default)]` on every post-v1 field, with doc comments spelling
  out the intent (*"`None` for sessions created before this field was
  added"*), and `deny_unknown_fields` deliberately **never** applied to
  any session/transcript type (it is reserved for tool-argument schemas
  and wire protocols, where a typo should hard-fail). Two independent
  harnesses, same answer.
- **So the "one migration function per version bump" plan is probably
  over-engineering, and I'd now start without it.** Neither harness has
  ever needed a content-shape rewrite. Keep the `version:` field — it is
  free, and it is what lets a future reader *refuse* — but expect it to
  stay `1`, and treat a bump as the alarm it should be rather than a
  routine event budgeted for in advance.
- **Steal grok-build's forward-compat idiom for enums**, which is the
  one piece of this that is genuinely subtle: an unrecognized enum value
  written by a newer binary decodes to a **fail-safe** variant rather
  than erroring (`#[serde(other)]`, or a custom `Deserialize`). Their
  `GoalStatus` maps anything unrecognized to `UserPaused`, with the
  rationale stated in the doc comment: *"a corrupt or forward-version
  snapshot can never resurrect as a self-driving goal"*
  (`goal_tracker.rs:8`). The general rule — **an unknown value must
  decode to the inert/restrictive option, never the active/permissive
  one** — is exactly pikuri's house instinct about failing closed, and it
  is the thing to remember if this format ever carries anything
  resembling a mode, a grant or a flag.
- **A version bump, if it ever comes, means the loader carries an
  upgrade path** (`from_h` dispatching on `version`), kept forever.
- **Refuse the future.** `version: 2` in a v1 binary raises a named error
  ("history version 2 is newer than this pikuri understands"), never a
  best-effort partial load. Ties into the "errors are loud" convention.
  grok-build does exactly this for its compaction checkpoints
  (`replay.rs:380`) and PI's v4 design states the policy in three lines
  (*"version > current → refuse to open (older binary, newer session)"*,
  `harness.md:2734`). Neither of the *shipped* formats has a refusal
  path, which reads as an oversight in a local single-binary CLI rather
  than a considered choice.

### Strict-on-load: PI reversed itself, in the same repo

The strongest evidence in the survey for failing loud, because it is one
project's own before-and-after. PI's **shipped** loader silently skips
unparseable lines — `parseSessionEntries` try/catches each line with the
comment *"Skip malformed lines"* (`session-manager.ts:299`), and a
second comment concedes the liability outright: *"Session files are
parsed without validation; old versions, forks, or hand-edited files can
contain messages with null/missing content"* (`:386`). Its **in-flight
rewrite** takes the opposite posture: strict field-by-field decoding
(`requireString`, `requireTimestamp`, type allowlists — `jsonl/codec.ts`),
a `JsonlDecodeError` on any bad record, and **the whole session fails to
load**.

So: silent-skip loses history invisibly, and the project that shipped it
is walking it back. Our raise-on-invalid instinct survives contact with
prior art.

**With one carve-out worth stealing wholesale** — the *torn last line*.
A crash mid-append leaves a partial final record, which is a normal
event, not corruption, and PI treats it as such: detect it and
atomically truncate to the last valid line (`jsonl/storage.ts:84`),
while interior corruption still throws. Paired with the write side —
`publishFileAtomically`, temp file plus atomic rename (`:33`) — that is
a small, well-tested crash-safety pattern, and it is the same
"attachments first, JSON last" reasoning generalized. Note the carve-out
only applies to an append-only line format; our single `history.json` is
written whole, so atomic-rename alone covers it and there is no torn
tail to repair. Worth knowing if the format ever grows an append mode.
- **The format is a `pikuri-core` public API** — it outlives the process,
  so a breaking change is a CHANGELOG `**Breaking:**` entry with a
  migration sentence, same bar as a renamed public method.

Deliberately *not* the format's job: being a ruby_llm-compatible
serialization, or being importable by another agent framework. Those are
lovely and they are how formats acquire fields nobody uses.


## The round-trip property, and how to actually test it

The issue states it well: "`load_history!(export_history)` produces no
observable change to the model". The word doing the work is
**observable** — and pikuri can test that *literally*, which is much
stronger than asserting object equality:

`Pikuri::Testing`'s fake transport (`D_fake_transport`) already records
outbound request bodies, and `pikuri-core/spec/pikuri/testing_spec.rb`
already pins role names and ordering in them. So:

> Run a conversation through a scripted fake transport (user turn →
> assistant tool_call → tool result → assistant answer). Capture request
> body **B1** for a following turn. Then `agent.load_history!(agent.export_history)`
> and run the same following turn; capture **B2**. Assert `B1 == B2`.

That is the property, tested at the only layer that matters — the bytes
the provider sees — with no network and no live model. It catches
everything the object-level test would (dropped tool call, mangled
signature, symbol-vs-string keys leaking into the rendered arguments)
*plus* the ones it wouldn't (a `Content` that survives as an object but
renders differently). Run it once per provider format that pikuri cares
about, since `format_messages` differs per provider
(`providers/openai/chat.rb:124` vs `anthropic/chat.rb:136`, which prepends
thinking blocks to tool-call turns).

Second test, cheap and worth it: **`History.parse(history.to_json) == history`**,
which is one line given `Data`'s `==`, and pins the JSON layer itself.
Its twin for the folder mode — **`History.load(history.save(dir)) == history`**,
and the cross-mode **`History.load(dir) == History.parse(json)`** — is what
stops the two encodings drifting into two formats.

Third: a **golden file** — a small committed `spec/fixtures/history-v1.json`
covering every branch (user, assistant text, assistant tool_call batch of
two, two tool results, thinking with signature, an attachment). Loading it
must keep working forever; that fixture *is* the format's regression
guard, and its diff is what a version bump has to justify.


## Open questions

- ~~**Attachments: (a) path / (b) inline base64 / (c) drop?**~~ Settled
  2026-08-27: two encodings of one value (`to_json` inline, `save(dir)`
  sidecar files). What's left open is inside that decision — whether
  `save` sweeps unreferenced attachments (lean no), and whether the
  stored-name scheme is content-addressed (lean yes). See *Attachments:
  two modes*.
- **What does `export_history` return** — the `History` object, or its
  `to_h`? Lean: the object (the issue's `[Hash, ...]` is then
  `history.to_h[:messages]`, one call away). And `load_history!` takes a
  `History` *only* — `History.parse` / `.from_h` are the named,
  validating doors in. No polymorphic "accepts a String or Hash or
  History" convenience: one way in means one place where validation can
  be skipped, i.e. none.
- **Is the system prompt really excluded?** The issue says yes, and
  `clear_conversation` re-assembling it (`agent.rb:358`) says yes too.
  But a *resumed* conversation then gets today's prompt over yesterday's
  transcript — right for a memory persona or a re-read `MACHINE.md`,
  wrong for auditing what the model was actually told.

  The survey is near-unanimous on regenerate-don't-replay: PI recomputes
  it per load, grok-build reconstructs from templates (no `System` chunk
  is ever persisted), opencode builds it fresh each turn. Only
  hermes-agent stores it, deduped through a `system_prompts(hash→prompt)`
  table — which is a *storage* trick for auditing, not a replay source.

  **PI has the refinement I was missing**: regenerate the base prompt,
  but persist an explicit *override* when one was set
  (`OperationStartedRecord.intent.systemPromptOverride`). That splits the
  two cases cleanly — dynamic sections stay fresh, while a prompt someone
  deliberately pinned survives. pikuri has the same distinction
  (assembled-from-extensions vs. a host-supplied prompt), so the field to
  reserve is `system_prompt_override:`, not `system_prompt:`. Plus
  hermes' hash trick if archival ever wants the full text.
- **Injected reference blocks** (`append_reference_block`, `agent.rb:674`)
  are ordinary `:user` messages wrapped in `<system-reminder>`, so they
  round-trip for free — but they come back *stale* (yesterday's memory
  prefetch, yesterday's promoted skill).

  **Lean reversed by the survey (2026-08-27).** The earlier lean was
  "leave them opaque; tagging means a field only pikuri understands".
  Claude Code does the opposite and it is clearly better: every
  mid-conversation injection is its own **typed** record —
  `skill_listing`, `task_reminder`, `total_tokens_reminder`,
  `deferred_tools_delta`, `command_permissions`, `edited_text_file`,
  `agent_listing_delta`, `queued_command`. The system prompt is still
  regenerated, but each thing the harness slipped into the conversation
  stays durably logged *and distinguishable* rather than dissolving into
  opaque user text — so a resumed conversation can tell a stale skill
  listing from something the human actually typed, and drop or refresh
  it.

  pikuri already knows the difference at injection time: that is exactly
  what `Event::SystemInjected` reports, and what the interloper's
  `:system` kind means. So the cost is one **non-wire** field on
  `History::Message` — `kind: "user" | "reference"`, never sent to a
  provider, sitting beside `id` as the second field that exists purely
  for local reasoning. Cheap, and it is the difference between a resumed
  conversation that can clean up after itself and one that can't.

  (Whether the *variant* is carried too — memory prefetch vs. promoted
  skill vs. host-loaded reference — is a further step. Claude Code
  carries it; pikuri's `Event::SystemInjected` currently does not, so
  that would need a change upstream of the format. Not v1.)
- ~~**`id` / timestamps / a title.**~~ Settled by the consumer survey:
  **the shell's envelope, not ours.** pikuri-web already plans exactly
  that — a `meta.json` holding title, `created_at`, `updated_at`, model,
  *shell*, tool list and `schema: 1`, deliberately kept out of the
  directory name so a rename doesn't move files
  (`multiple-conversations.md:143,158`). Two of those fields are ones we
  would never have thought to offer: **which shell wrote it** and **which
  tools were wired**, both there to detect drift when a conversation
  whose history references `web_search` is loaded by a shell that
  doesn't wire it (`Q_tool_set_drift`, line 280). That is a real hazard
  for us — a restored history can name tools the agent no longer has —
  and it is worth deciding whether `load_history!` should *warn* on it.
  Cheap version: it already has the tool list and the history; a mismatch
  is a `FallbackNotice`-shaped observation, not a refusal.
- **Must `load_history!` survive being called dozens of times on one
  long-lived agent?** Yes — confirmed, and it is the primary use.
  pikuri-web runs **one process-wide `Agent`** (`bin/pikuri-web-chat:130`;
  its single-shared-conversation decision), and every sidebar click is
  planned as
  `clear_conversation` + `load_history!` on that same object. So the
  method is not a boot-time convenience; it is a hot path that must leave
  no residue across switches (this is the strongest argument for it going
  through `clear_conversation`'s exact reset rather than its own partial
  one). pikuri-tui is the same shape: one Agent per process, model
  switchable, never a second instance.
- **Switching while the agent is mid-turn** is already settled downstream
  and we should not re-litigate it: pikuri-web v1 *refuses* (sidebar rows
  disabled) rather than cancelling the in-flight turn
  (`Q_switch_while_busy`, line 216). That matches the issue's "not
  designed for concurrent `run_loop`" and means `load_history!` may
  document itself as not thread-safe rather than growing a lock.
- **Where does it live** — `Pikuri::Agent::History` in `pikuri-core`,
  next to `Event`/`Control`? Almost certainly yes; it is Agent surface
  and both shells depend on core regardless.
- **Does `load_history!` fire `Event::Reset`?** It resets controls like
  `clear_conversation` does, so listeners must clear display state — but
  `Reset` means "empty conversation" to a listener, which is now a lie.
  Probably `Event::Reset` *then* an `Event::HistoryLoaded(messages:, tokens:)`,
  with the usual no-op-on-unknown-variant contract covering listeners
  that don't care.


## Considered, then set aside

- **Patch `RubyLLM::Message#to_h` in `ruby_llm_patches.rb`** so it
  serializes properly. Rejected: that file is explicitly for *defects on
  the live chat path*, carried until upstream fixes them, each one a
  liability pinned to an upstream issue. `to_h` isn't broken for its
  purpose (Rails persistence) — it is just not our format. And building
  a disk format on a monkey-patched third-party method inverts the whole
  argument of this note: the point is to *stop* depending on ruby_llm's
  internal shape.
- **`Marshal` / a binary format.** Fails (2) and (3) — unreadable,
  version-fragile across Ruby releases, and unhandeditable. Non-starter
  for something whose files outlive the process.
- **Persisting the whole `Chat` object.** Drags `@connection`, `@config`,
  registered tools and callbacks along; ruby_llm already excludes those
  from `instance_variables` (`chat.rb:~178`) precisely because they don't
  belong in a dump.
- **An `Extension#export_state` / `#load_state` protocol** in v1. Real,
  and probably eventually right (see "What is NOT in the history"), but
  a much larger surface with no evidence yet about which gap bites.
  Deferred *on the condition* that the envelope leaves room for it.
- **Making the export the context-compaction primitive too** ("export,
  summarize, reload a shortened history"). Tempting — same machinery —
  but compaction has to slice mid-conversation without breaking tool
  batches, which is a policy question of its own; see
  [`context-overflow-behavior.md`](context-overflow-behavior.md). Keep
  them separate until that note settles, then re-check whether
  `load_history!` is the natural actuator.
