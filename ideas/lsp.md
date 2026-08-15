# LSP client — language intelligence for the coding agent

Status: **investigated, not built.** Protocol mechanics are settled and
verified against live servers, plus a third pass through a shipped
client (below); the direct-vs-MCP fork is decided in principle; the
tool-surface sketch is the live part, though the static-enum /
gate-at-dispatch question is now settled inside it.

Origin: [`feedback.txt`](feedback.txt) item 2 — "No language
intelligence. For Ruby I'd want go-to-definition and find-references. I
can grep, but `ConfirmerPopup` vs `ask` vs the pikuri `Confirmer`
interface is exactly the kind of thing an LSP hop settles in one call."
That is the concrete use case
[`coding-agent.md`](coding-agent.md)'s LSP bullet was waiting for —
**this note supersedes that bullet** (and the matching one in
[`claude-parity.md`](claude-parity.md)); delete both when this
graduates.

Related:

- [`../DECISIONS.md`](../DECISIONS.md) `D-walked-path-denylist` — every
  LSP result is a *walked* path, so that entry's rule applies verbatim.
  Probably the single most load-bearing constraint here.
- `Pikuri::Mcp::ClientWrapper` — the existing long-lived stdio JSON-RPC
  child, restart-on-death and all. The shape to copy.
- [`../COMPARISON.md`](../COMPARISON.md) §"Available tools" — the LSP
  column is `—` for pikuri, `✅` for opencode and grok-build. Update
  when this ships.

---

## How the protocol actually works

JSON-RPC 2.0 over the child's stdin/stdout, with LSP's own framing:

```
Content-Length: 87\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{…}}
```

Header block, `\r\n\r\n`, then exactly N bytes of JSON. No newline
delimiting — read the header, then `read(n)`.

Three message shapes: **request** (has `id`, expects a response),
**response** (echoes the `id`), **notification** (no `id`). The channel
is bidirectional and asynchronous — the server sends *you* requests
(`window/workDoneProgress/create`, `workspace/configuration`) and can
block waiting for your reply. So the client is a demux loop keyed on
`id`, not a call-and-read-next-message.

Lifecycle: `initialize` (request) → `initialized` (notify) → work →
`shutdown` (request) → `exit` (notify).

The entire non-obvious core, which is also roughly the whole reason a
gem is cheap here:

```ruby
def write(msg)
  body = JSON.generate(msg)
  @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  @stdin.flush
end

def read
  headers = {}
  while (line = @stdout.readline("\r\n").chomp("\r\n")) != ''
    k, v = line.split(': ', 2)
    headers[k.downcase] = v
  end
  JSON.parse(@stdout.read(Integer(headers.fetch('content-length'))))
end

def request(method, params = {})
  write(jsonrpc: '2.0', id: (@id += 1), method:, params:)
  loop do
    msg = read
    return msg if msg['id'] == @id && (msg.key?('result') || msg.key?('error'))

    write(jsonrpc: '2.0', id: msg['id'], result: nil) if msg['id'] && msg['method']
  end
end
```

## Findings from live runs against this repo

Two throwaway clients, one against `rubocop --lsp`, one against
`ruby-lsp` 0.26.10 driving the pikuri monorepo. (The scripts were
scratchpad-only; the findings are the durable part.) Later re-run
through Claude Code's own `LSP` tool against the same repo and the same
`ruby-lsp` 0.26.10 — a third, independent client. Where that run
confirmed or corrected a finding it is marked inline; what it revealed
about *that implementation* is under Prior art below.

**1. Capabilities are computed per workspace, not per binary.**
The killer finding. Same `ruby-lsp` binary, same version:

| capability | `rubocop --lsp` | `ruby-lsp` (in *this* repo) |
| --- | --- | --- |
| `documentFormattingProvider` | ✅ | — |
| `executeCommandProvider` | ✅ | — |
| `codeActionProvider` | ✅ | ✅ |
| `definitionProvider` / `referencesProvider` / `workspaceSymbolProvider` | — | ✅ |
| `hoverProvider` / `completionProvider` / `renameProvider` / `typeHierarchyProvider` / … | — | ✅ (23 total) |

`ruby-lsp` reports **no** formatting capability here purely because
pikuri's `Gemfile`/`Gemfile.lock` contain no rubocop, so it detected no
formatter (`window/logMessage`: "Auto detected formatter: none") and
didn't advertise it. In a rubocop-bundled project that row flips.
Consequence: **capability knowledge must come from the `initialize`
response for *this* workspace**, never from a matrix keyed on which
server binary was spawned.

But that check belongs at **dispatch time, not schema-construction time
— the `operation` enum stays hardcoded.** With several servers
registered (Ruby *and* Java, say) their capability sets differ, and
*which* server applies isn't known until a call names a file; routing is
by extension. A schema computed from capabilities would therefore have
to advertise the union anyway, and would need rebuilding whenever a
server restarts or a workspace gains a formatter — a moving tool
description is worse than a static one the model can learn. So: static
enum (the superset pikuri supports) → route on the file's extension →
consult *that* server's advertised capabilities → clean refusal string
if it lacks the operation. This is the one place `Mcp::Servers`'
synthesize-tools-from-what-the-server-reports shape does *not* transfer:
one MCP server owns its own tool names, whereas here many servers share
one tool and the file picks the server.

**2. Asking before the index is built returns `[]`, not an error.**
My first run fired `textDocument/definition` immediately after
`initialized` and got `{"id":2,"result":[]}` — a *successful* empty
answer, with the `$/progress` `begin` for indexing arriving afterward.
For an agent this is the worst failure mode available: the model
concludes the symbol has no definition and proceeds on a false premise.
The client must block on the indexing-progress `end` notification before
its first query, and should distinguish "not indexed yet" from "no
results" in what it hands the model. Non-uniform per method, too —
`references` *did* return results pre-index in that same run, so gate on
progress rather than trusting any one method.

**3. Definition returns candidates, not an answer — and leaves the
workspace.** Cursor on `workspace.resolve_for_read(path)` at
`pikuri-workspace/lib/pikuri/workspace/read.rb:165`:

```
-> pikuri-workspace/lib/pikuri/workspace/filesystem.rb:218   # Filesystem#resolve_for_read
-> pikuri-workspace/lib/pikuri/workspace/filesystem.rb:415   # AllowAll#resolve_for_read
-> …/gems/pikuri-workspace-0.0.6/lib/pikuri/workspace/filesystem.rb:338
-> …/gems/pikuri-workspace-0.0.6/lib/pikuri/workspace/filesystem.rb:505
```

Ruby dispatch is dynamic, so both overrides come back — present as a
ranked list, never as "the definition". And note hits 3 and 4: ruby-lsp
indexes the *bundle*, and this monorepo's gems are also published gems,
so the agent gets pointed at a **stale released copy of the very file it
is editing**. Those paths were walked to by the server, never supplied
by the model, so they reach no `resolve_for_read` — `D-walked-path-denylist`
territory: results must go through `Filesystem#denied?`, plus almost
certainly a workspace-root confinement on top.

Re-checked with the third client, and worth recording because the
obvious reading of that run is wrong. There, `goToDefinition` on
`resolve_for_read` returned *only* the two in-repo hits — which looks
like root confinement. It isn't: `goToDefinition` on `Faraday` returned
45 locations, every one under `~/.local/share/…/gems/`. The stale
`pikuri-workspace-0.0.6` copies are absent from that run for an
unrelated reason (the top-level `Gemfile` wires siblings via
`gemspec path:`, so the bundle index points at the working tree), and
the released gem is installed either way. Conclusion: **no shipped
client confines results.** Both the `denied?` pass and the root
confinement are ours to write, with no prior art to inherit — which also
removes the last reason to hope a bridge would handle it.

**4. Two response shapes.** ruby-lsp answers with `LocationLink`
(`targetUri` / `targetRange` / `targetSelectionRange`), not plain
`Location` (`uri` / `range`); servers choose based on the `linkSupport`
capability the client declares. Parse both. (My first parser crashed on
exactly this.)

**5. `workspace/symbol` is fuzzy.** Query `resolve_for_read` returned
`resolve_for_write`, `resolve`, and `oversized_root_refusal` — matched on
scattered letters. Any name→position hop must filter for exact-name hits
before feeding positions onward.

**6. `references` is high-volume.** 40 hits for `resolve_for_read`: 4 lib
call sites, 2 declarations, **34 spec hits**. Raw output is a lousy
observation — needs lib/spec grouping and a cap, like `Grep` already does.

The third client reproduced that split to the exact number, uncapped and
ungrouped. And it is not only `references`: `definition` and `hover` on
a **constant** are worse, for a Ruby-specific reason. Every file that
reopens `module Faraday` is a definition of it, so `goToDefinition` on
`Faraday` returned 45 locations and `hover` returned a wall of 45 doc
links *ahead of* the docstring. Capping and grouping must cover all
three operations, and the constant case wants the most aggressive cap —
a reopened namespace's "definitions" are nearly all noise, and the one
the model wants (`faraday.rb`) is not distinguishable by position in the
list.

**7. `positionEncoding` is negotiable.** Offer
`general.positionEncodings: ["utf-8","utf-16"]`; ruby-lsp picks `utf-8`,
which removes the UTF-16-code-unit offset conversion. Fall back to
converting if a server insists on utf-16 (the 3.17 default).

**8. Hover is rich on constants and empty on methods.** `hover` on
`Pikuri::FileType` returned the constant, a definition link, and the
*entire yardoc class comment* — both responsibilities, the two
`Pathname` conveniences, the "Deliberate non-goals" list. `hover` on the
`def resolve_for_read` line returned nothing at all. ruby-lsp resolves
documentation through its constant index; method-level hover is simply
not the same feature. Consequence: hover's value is split down the
middle, and in a codebase whose yardoc *is* the declared source of
truth, the constant half answers "what is this class for?" in one call
without reading a file — a different operation from `read`, not a third
spelling of it.

## There is no Ruby LSP client gem

Checked rubygems:

- **`lsp-client`** (0.0.1) — an *empty gem*. Its `data.tar.gz` is 35
  bytes; zero files, no homepage, no source URI. A name placeholder.
- **`language_server-protocol`** (283M downloads) — the protocol SDK:
  framing + typed structures/constants. Its `Io::Reader` is ~20 lines
  (`gets("\r\n\r\n")`, `read(n)`, `JSON.parse`) and is direction-agnostic,
  so it *works* client-side — but it supplies no lifecycle, no id
  correlation, no capability handling, no spawn, and its reader is a
  blocking whole-stream callback loop shaped for a server main loop.
- Everything else (`language_server`, `ruby_language_server`,
  `yoda-language-server`, `rubocop-language-server`, `solargraph`) is a
  **server**.

Structural reason: LSP clients live in editors, and editors are written
in TypeScript / Rust / Emacs Lisp / Vimscript. Nobody needed a Ruby
client until agents wanted language intelligence.

So we own the client outright — which is fine, it's the ~130 lines
sketched above plus policy, and it suits "readable end-to-end in an
evening". **Don't take the `language_server-protocol` dependency** for
40 lines of framing whose reader shape we'd fight.

## Direct vs MCP bridge — direct

Maintained bridges exist and are real: isaacphi/mcp-language-server,
Tritlo/lsp-mcp, bug-ops/mcpls, ProfessioneIT/lsp-mcp-server. Their pitch
is correct (a semantic answer costs ~50–200 tokens vs. dumping files),
and since `pikuri-mcp` exists, using one would be a *registry entry* —
config, not code. Genuine upside: zero implementation cost, every
language at once, someone else absorbs protocol drift.

Rejected anyway, for four reasons:

1. **The transport isn't the hard part.** Both paths terminate at the
   same `ruby-lsp` process over the same stdio JSON-RPC; MCP just adds a
   hop and a process. The actual difficulties — indexing readiness,
   capability gating, name→position, result capping, coordinate
   conversion — get solved somewhere either way, and via a bridge you
   inherit someone else's answers with no way to correct them.
2. **Two seams can't be delegated.** Findings 3 and 6 above: denylist
   filtering of walked paths, root confinement, and volume capping are
   post-processing we must write regardless — at which point most of the
   client exists anyway, and we're still paying for the extra process.
3. **It inverts the bounded-gem rule.** A direct client has a closeable
   threat model: read-only, no network, one long-lived child, reusing
   `Mcp::ClientWrapper`'s restart discipline. A third-party bridge is an
   opaque Go/TS/Rust binary with its own network posture and supply
   chain — widening the threat model to save ~200 lines of Ruby, in a
   project whose bar is "small enough to audit in an evening", and
   dragging a non-Ruby toolchain into a Ruby monorepo.
4. **Teaching mandate.** A small LSP client is a good book chapter about
   how editors actually work. "Install this Go binary" teaches nothing.

**But use a bridge as a measuring instrument.** Wire
`mcp-language-server` through `pikuri-mcp` for an afternoon and watch
*which operations the model actually reaches for and how it phrases
them* — the one question a design doc can't answer. Then throw it away
and write the direct client informed by that. Ship direct; spike via MCP.

## Prior art: what Claude Code's own LSP tool looks like

Read straight off its tool schema (it went direct too, with servers
registered as *plugins* — `jdtls-lsp`, `kotlin-lsp` — so: direct client,
pluggable server registry):

```
operation: enum[goToDefinition, findReferences, hover, documentSymbol,
                workspaceSymbol, goToImplementation, prepareCallHierarchy,
                incomingCalls, outgoingCalls]
filePath:  string   (required, all operations)
line:      integer  (required, 1-based, "as shown in editors")
character: integer  (required, 1-based, "as shown in editors")
query:     string   (workspaceSymbol only)
```

Run against this repo on the same `ruby-lsp` 0.26.10, it behaves as
follows — the parts worth knowing before copying it:

- **1-based in *and* out, confirmed.** Input `line: 218, character: 11`
  landed on `def resolve_for_read` at a 6-space indent; output reported
  `218:11`, and `415:13` for the 8-space-indented override. The
  translation is symmetric, which is the property that matters — a
  position it prints can be fed straight back in.
- **The degrade string is real.** `goToDefinition` on `CLAUDE.md` →
  `No LSP server available for file type: .md`. So it *does* route on
  extension — the mechanism the multi-server design needs.
- **But there is no capability check on the routed-to server.** Three of
  the nine enum operations are unbacked by ruby-lsp and leak the raw
  protocol error instead of degrading: `goToImplementation` →
  `Method not found: textDocument/implementation`; `prepareCallHierarchy`
  and `incomingCalls` → `Method not found:
  textDocument/prepareCallHierarchy`. Extension routing without the
  capability half. Pikuri should reuse the `.md` refusal's shape here —
  same static enum, one more gate.
- **No indexing gate.** The first `goToDefinition` after startup returned
  `No definition found. This may occur if the cursor is not on a symbol,
  or if the definition is in an external library not indexed…` — finding
  2's false-premise answer, verbatim — while a `hover` issued in the same
  batch correctly failed with `server is starting`. The readiness signal
  exists and one path ignores it. **The single most important thing not
  to copy.**
- **No confinement, no capping.** See findings 3 and 6.

Worth stealing:

- **One tool, an `operation` enum — not nine tools.** Nine `lsp_*`
  entries is a real prompt-budget cost. Tension with the naming
  convention in [`../CLAUDE.md`](../CLAUDE.md) (a `foo_*` prefix marks a
  family sharing one backing resource, which LSP genuinely is); the
  evidence still favours the single tool, and `Tool::Parameters`
  validates enums strictly so nothing is lost on safety. The enum also
  stays **static** — per finding 1, with several servers registered it
  can't track any one server's capabilities anyway.
- **1-based line *and* character.** LSP is 0-based on both; translate at
  the boundary, because the model reads files through `Read`, which
  prints 1-based line numbers. This is the highest-value line of code in
  the whole tool.
- **Clean degrade when no server is configured.** Asked for a `.rb`
  definition on a machine with only Java/Kotlin servers registered, it
  returned `No LSP server available for file type: .rb` — a
  model-readable string, exactly pikuri's "errors the LLM can react to"
  rule.

Worth arguing with:

- ~~`filePath` is required even for `workspaceSymbol`, which takes no
  position in LSP — it's the server-routing selector. Principled, still a
  wart; consider routing on workspace root instead.~~ **Withdrawn.**
  Finding 1's multi-server argument vindicates it: once several servers
  can be registered, *every* operation needs a routing selector, and a
  file path is the only one the model reliably has. Routing on workspace
  root fails precisely in the mixed-language repo that makes a registry
  worth having. Keep it; explain why in the parameter description, since
  a required `filePath` on a workspace-wide query reads as a bug
  otherwise.
- It exposes `workspaceSymbol` raw and lets the model chain it into
  `goToDefinition`. That works because the model is strong. **Pikuri's
  default is local llama.cpp**, and small local models chain multi-call
  sequences unreliably — a real reason for pikuri to collapse the
  name→position hop *inside* the tool where Claude Code doesn't.

## Sketch

- `pikuri-lsp` gem. Name it after what it refuses to become: no
  formatting, no code actions, no diagnostics push, no rename/edit
  application — **read-only navigation**. The moment it applies a
  workspace edit it needs the `Confirmer` seam and stops being closeable.
- `Pikuri::Lsp::Registry::StdioEntry` mirroring
  `Mcp::Registry::StdioEntry` — command, args, env, claimed extensions.
  The claimed-extensions field is load-bearing, not decorative: it is the
  dispatch key that picks the server, per finding 1.
- `Pikuri::Lsp::ClientWrapper` — long-lived child, id demux on a reader
  thread, auto-reply to server→client requests, restart-on-death copied
  from the MCP wrapper. Needs the same documented exception to the
  Subprocess seam (`Subprocess.spawn` is one-shot; this isn't).
- One `lsp` tool, static `operation` enum, 1-based coordinates,
  capability-gated **at dispatch** (route by extension, then refuse
  cleanly if that server lacks the operation), results filtered through
  `Filesystem#denied?` + root-confined + capped/grouped.
- Book chapter when it lands (`book/language-intelligence.md`?) — the
  protocol is genuinely interesting and nothing else in pikuri teaches
  "how does an editor know things".

## Open questions

- **Startup cost vs. session model.** Indexing this repo dominated each
  run's wall time. `bin/pikuri-code` is synchronous and request-scoped —
  do we pay it lazily on first `lsp` call (a multi-second stall mid-loop),
  eagerly at boot (slow start for sessions that never use it), or in
  background at boot and block only on first use? Leaning the third.
- **Does the model actually use it?** The honest risk: `grep` is right
  there and the model is good at it. This is what the MCP spike measures.
- **Multi-language, or Ruby-only first?** Registry design is
  language-agnostic for free; the question is whether to ship any server
  config beyond Ruby before there's a user. Whichever way it goes, the
  *dispatch* path must assume multi-server from day one (finding 1) —
  retrofitting extension routing plus per-server capability checks later
  would touch every operation.
- **Where does workspace-root confinement live** — in the wrapper, or as
  a `Workspace::Filesystem` call in the tool? The latter reuses the seam;
  the former keeps the tool thin.

## Considered, deferred

- **Diagnostics.** `rubocop --lsp` gives them for ~4 capabilities' worth
  of client work, and grok-build/Claude Code surface fresh diagnostics as
  system-reminders appended to tool output. Attractive, but it needs the
  reminder mechanism pikuri doesn't have (see
  [`../COMPARISON.md`](../COMPARISON.md) §system reminders) and it pushes
  the gem from read-only navigation toward lint policy. Separate note if
  it ever gets legs.
- **`rename` / workspace edits.** Needs `Confirmer` + the read-before-edit
  gate; breaks the closeable threat model. Not in v1.
- **Depending on `language_server-protocol`.** See above — 40 lines of
  framing, wrong reader shape.
- **Hover as a `read` replacement.** Deferred as a third way to read code
  alongside `read` and `grep`. Finding 8 weakens that reasoning: on a
  *constant*, one hover returns the whole yardoc class comment, which in
  this codebase is the declared source of truth — a different operation
  from "read the file", not a third spelling of it. Still deferred, but
  the blocker has moved: it is now the volume problem (45 doc links for
  `Faraday`), which is a capping question, not a tool-surface one.

## Graduation

When built: protocol mechanics + the "capabilities are per-workspace"
and "empty result ≠ no definition" lessons → book chapter (both are
better taught with the observation that a shipped client gets the second
one wrong); per-symbol rationale → yardoc on `Lsp::ClientWrapper` / the
tool, including why the `operation` enum is static while gating happens
at dispatch; the walked-path-filtering and Subprocess-exception
invariants → a `CLAUDE.md` seam entry; **direct-vs-MCP with the bridges
named** → a new
`DECISIONS.md` entry (suggested slug `lsp-direct-not-mcp`, with the usual
prefix); the COMPARISON.md LSP column → `✅`. Then delete this file,
plus the superseded LSP bullets in `coding-agent.md` and
`claude-parity.md`.
