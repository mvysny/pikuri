# LSP client — language intelligence for the coding agent

Status: **building.** The design is settled, the evidence is in, and no open
question remains — the nine-item worklist this note carried is closed, and
§"The v1 build" is the checklist being coded against, step by step; a struck
step there has landed in `pikuri-lsp/`.

This note is split four ways, because the argued-and-closed part had grown to
~1600 lines and buried what was still to do:

| file | holds |
| --- | --- |
| **this file** | status, the strategy, the v1 build checklist, the decided forks, the graduation map |
| [`lsp/research.md`](lsp/research.md) | live client runs against both reference servers, a rubygems survey, a shipped client read off its schema — the stable `finding N` / `J<n>` / `H<n>` / `S<n>` labels everything else cites |
| [`lsp/harness-analysis.md`](lsp/harness-analysis.md) | the three shipped harnesses' LSP tools read first-hand (Claude Code, opencode, grok-build) — the operation surface, and where they converge, differ, or are contradicted by a finding |
| [`lsp/design.md`](lsp/design.md) | everything decided: direct-vs-MCP, the registry entry, no-timeout, progress + mailbox, the scheme table, the operation surface, document sync, protocol modeling, testing, the trifecta legs |

`lsp/design.md` is still here rather than split into `pikuri-lsp/DESIGN.md`,
five `DECISIONS.md` entries and a book chapter because the build is only
part-way: graduating a rationale whose implementation may still move is how
a doc starts lying. Graduation map below.

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

## Strategy: source the surface from harnesses, relay glitches honestly

**Decided 2026-08-17, and it reverses how this note was being built.** The
six runs in [`lsp/research.md`](lsp/research.md) found a genuine pattern,
and then the pattern turned on the method: *every* server is broken in its
own way, and the ways do not generalize. ruby-lsp advertises a type
hierarchy whose `subtypes` half is a `# TODO` (H1); jdtls's
`workspace/symbol` cannot see a method at all (S10);
ruby-lsp crashes on a full-text `didChange` that jdtls accepts (S1);
ruby-lsp's index desynchronizes from its own document because of a
typing-speed heuristic (S2). There are LSPs for Python, Kotlin, Rust, Go
and thirty other languages, each with its own list. **A catalogue of two
servers' glitches is not a design input**, and the arms it was steering
toward — a per-server known-stub list, per-server readiness predicates,
per-operation workarounds — are unbounded work that gets one server right
and says nothing about the third.

So:

1. **The operation surface comes from harnesses that shipped one**, not
   from what two servers happen to implement. Claude Code's nine
   (`research.md`, prior art), grok-build's set, opencode's — the authors
   did this homework, and their union is both a better v1 and a stable
   input. Deviate only where there is a *measured* reason (the
   `typeDefinition` addition, J9).
2. **Server glitches are relayed, not worked around.** The tool reports
   what the server said and what it asked for; the model decides what to do
   about it. This is not a shrug — a strong model handles "the index is
   stale, let me try another way" routinely, and the runs show pikuri
   cannot pre-empt the failure modes anyway.
3. **The one thing that must not be relayed is a *lie*.** Three distinct
   answers must stay distinct in what the model reads: *the server does not
   support this operation*, *the server answered nothing*, and *the server
   is not ready yet*. Collapsing them is the single most consequential
   defect in the shipped prior art (Claude Code's
   `No definition found. This may occur if…`, finding 2's false premise
   verbatim), and keeping them apart is one rendering rule, not a
   per-server anything.
4. **No fallback steering.** An error says what failed; it never proposes
   grep. Unchanged from `design.md`, and it is the same principle as (3):
   report, don't decide.

**And the readiness gate stays**, because it is the one case where waiting
is strictly better than relaying: a server that is still indexing will
answer `[]` (finding 2) and there is nothing for the model to reason about
in an empty list. Block until ready, emit progress, let the human be the
timeout.

**Model target: 25B+, not 4B.** A 4B model cannot code, so nothing here is
sized for one. This deletes the "small local models chain badly" argument
wherever `design.md` leans on it (the `lsp_read` refusal, the prepare-hop
collapse, the no-timeout decision, the name→position collapse) — each of
those needs an honest replacement reason or needs dropping. The strongest
surviving one is not about model capability at all: **a hop the tool can
perform exactly is not a hop worth spending a round trip on**, and a
coordinate the model was never shown is not a coordinate it should be
asked to invent (see the parameter item below).

## The v1 build

What ships, assembled in one place because it is currently spread over three
files. Every line has its rationale elsewhere; this is the checklist, not the
argument.

**The gem.** `pikuri-lsp`, depending on `pikuri-core` **and
`pikuri-workspace`** — the latter is not optional: the tool needs
`Filesystem#denied?`, the root confinement, the seam-routed read behind every
re-open, and `filesystem.private?` for its own trifecta declaration. An LSP
serves a *project*, and `Workspace` is what a project is in pikuri.

**Build order** (each step testable before the next exists):

1. ~~**Protocol layer + `Location` / `Position` / `Range` / `ServerProgress`
   value types.**~~ **Landed.** `Lsp::Connection` (framing, id demux on a
   reader thread, `result: null` to every server→client request, no timeout,
   `cancellable:` poll), `Location.from_wire` taking both the `Location` and
   `LocationLink` shapes (finding 4), `PositionEncoding` for the
   utf-16↔utf-8↔utf-32 offset arithmetic (finding 7, mandatory — jdtls
   ignored the utf-8 offer), 1-based↔0-based in `Position` alone, and
   `Uris` for the `file:`-or-not question every walked path asks. Two
   deviations from the line above, both narrower than it: `Range` has no
   `to_wire` (pikuri sends positions, never ranges), and the encoding
   arithmetic is its own module rather than living inside `Position`.
2. ~~**`ClientWrapper.new(stdin:, stdout:)` + `.spawn(entry)`**~~ **Landed.**
   The constructor adopts a channel and starts reading; `#start` is the
   handshake, so a fake server drives a wrapper over `IO.pipe` with no binary
   in sight. Restart-on-death is `Mcp::ClientWrapper`'s shape (`MAX_ATTEMPTS`
   = 3), reached through an injected `respawn:` — which is also what makes
   restart testable in-process. Also landed: the declared client capabilities
   (the four measured ones), `#supports?` reading *this* workspace's
   `initialize` response, the negotiated `position_encoding`, the stderr tail
   that says *why* a child died, and teardown (`shutdown` + `exit`, then
   SIGTERM to the process group).

   Three deviations, all narrower than the line above:

   - **The entry came forward from step 4.** `.spawn(entry)` needs one, so
     `Registry` + `StdioEntry` + the extension→language-id table + basename-glob
     dispatch (`#claims?` / `#entry_for`) landed here. Step 4 is now
     `Registry.from_h` alone.
   - **`Connection#send_request`** was added for teardown: `shutdown` must
     reach the server *before* `exit`, and its reply changes nothing. The first
     cut awaited the reply on a thread with a grace period, which cost that
     grace on every close where a server never answers — the wait for the
     process to actually leave is `reap_child`'s, and that is the only clock
     teardown needs.
   - **No `Finalizers` coupling**, matching `Mcp::Servers`: the owner closes it,
     which will be `Lsp::Extension`'s `on_close` in step 7. A hard crash can
     therefore orphan a child — the same exposure stdio MCP has today.
3. ~~**The fake server + raw-byte fixtures**~~ **Landed.**
   `Pikuri::Lsp::Testing` holds both halves: `Wire` (manual — hand-framed
   bytes, for asserting what the client wrote and for the sequences no real
   server performs on demand) and `FakeServer` (scripted — answers the
   handshake for free, one block per method, `#received` / `#await` for
   assertions, `#crash!` for a death). Neither builds what it sends through
   pikuri's own framing or value types; going the *other* way is the point,
   and one spec round-trips a `Position` out through `to_wire` and back in
   through `from_wire` so an asymmetry cannot hide.

   Three notes:

   - **It ships, off the production load path** — `require 'pikuri/lsp/testing'`,
     the loader ignores it, exactly as `pikuri-core` does with
     `pikuri/testing.rb`. A host wiring the gem can then test its own
     integration without a language server installed.
   - **The fixtures are faithful reconstructions, not raw captures**, and
     `pikuri-lsp/spec/fixtures/README.md` says so per file, with the finding
     id each one pins: the throwaway clients' transcripts were never kept, so
     what survives is the findings. Field names, counts and every recorded
     string are theirs; whitespace, key order and ranges past the recorded
     line are ours. The `supertypes` fixture goes further — its 14 rows are
     this repo's real `class Tool` reopenings, so `grep` still reproduces the
     list.
   - `FakeServer#await` exists because `#received` legitimately lags: a client
     call returns when its bytes are *written*, and the serving thread records
     them a moment later. Without a barrier, every assertion on what the
     client sent is a race.
4. ~~**`Registry.from_h`**~~ **Landed.** The host-config bridge, and all that
   was left of the step once step 2 pulled the registry forward. A Hash keyed
   by server **id** → entry fields, so the duplicate `Registry#initialize`
   refuses is unwritable and insertion order is dispatch order; format-agnostic
   as decided, so the demo bins' YAML and a TUI's own settings object go through
   the same method. Two deviations, both narrower than the line above: every
   field is **validated rather than coerced** (a mistyped `env` is a jdtls that
   hard-fails below Java 21, a mistyped `init_options` is J4's silence — both
   invisible at the point of the typo), and `nil` reads as no servers, so a host
   reading an absent config key needs no `|| {}`.
5. ~~**Readiness gate + the coalescing mailbox + `ServerProgress`.**~~
   **Landed.** `Lsp::Mailbox` (the thread boundary: latest-value-per-key,
   `drain(tick:)` yielding `nil` on an idle tick and ending on the caller's
   `break`) and `Lsp::Readiness` (quiescence plus a `SETTLE` debounce, blocking
   with no timeout, polling `Cancellable`). `ServerProgress` and
   `window.workDoneProgress: true` landed with steps 1 and 2, so what was left
   was the gate around them.

   Four deviations, all narrower than the line above:

   - **The gate is composed into `ClientWrapper`**, which delegates `#ready?`
     and `#wait_until_ready`, rather than standing beside it for the tool to
     pair up. Two reasons, both structural: a restart must reset the gate (a
     fresh child indexes from nothing) and only the wrapper knows a restart
     happened; and a free-standing gate would make the tool hold a second
     server-keyed Hash alongside its clients. `Readiness` still knows nothing
     about the wrapper — it takes `server_id:`, an `alive:` probe and a
     `settle:`, so its specs need no client at all.
   - **The wait loop lives in `Readiness#wait`, not at the tool's call site**,
     and the emitter arrives as its block. So `design.md`'s snippet reads
     `client.wait_until_ready(cancellable:) { |p| emit.call(p) }` at the call
     site, and the *one* emission site the capability seam wants is still the
     agent thread's.
   - **A death mid-wait is a restart, not an error.** The wait exits false when
     the child dies and `ClientWrapper` feeds that through the same
     `with_restart` path a dying request takes, so a jdtls that dies importing
     is respawned and waited out again, `MAX_ATTEMPTS` times, before
     `ServerDied`. Without that a server could only ever be revived by a
     *request*, which the gate stands in front of. It cannot become a spawn
     storm: a wrong `command:` never reaches here (`ENOENT` and a
     dies-on-handshake binary both raise at boot, before an agent exists), the
     retry is capped at three, and a replacement that fails its handshake raises
     out of the loop on the first try rather than spending the other two — the
     wait checks liveness *before* readiness, so a child that died without ever
     announcing a task is a death rather than a quiet server that must be ready.
   - **`SETTLE = 1.5s`**, above the 0.9s gap J2 measured, and the terminal
     `done: true` covers **open tokens ∪ what this wait showed**, keyed by
     title — a `ServerProgress` carries no token, so a host keys its bars by
     title and the gate has to agree. `readiness:` is injectable purely so a
     spec can shorten the settle; production passes nothing.
6. ~~**The `lsp` tool**: ten operations, the `symbol`-anchored parameters,
   capability gate at dispatch, re-open-on-read sync, result rendering.~~
   **Landed.** `LspTool` (the schema, the description, the legs, the emitter
   handoff) over `Navigator` (route → gate → wait → re-open → ask → render),
   with `Operation`'s ten-value table, `Anchor` (the derived column and the
   index route), `Sources` (URI identity, the scheme table, snippet text) and
   `Renderer` (caps, the source/tests split, the ancestry collapse). Every
   rendering rule the line above lists is in, and the whole stack is driven
   in-process from scripted fake servers — including the failure paths a real
   server will not produce on demand.

   Ten deviations, and the first two are scope rather than design:

   - **The client set came forward from step 7.** A tool needs live clients, so
     `Lsp::Servers` — one `ClientWrapper` per entry, spawned at boot, plus
     basename routing — landed here. Step 7 is now the extension alone, and its
     `configure` is three lines over this class.
   - **The re-open is a `ClientWrapper` method**, not tool code:
     `#open_document(path, text)`, with the whole measured policy in its yardoc,
     which is where the graduation map was already sending it. The tool decides
     *when* (once per document per call); the client owns *what it means*.
   - **`locate` has no any-occurrence fallback.** Only matches bounded by
     non-identifier characters count, so `greet` never matches inside
     `greeting`. An unbounded fallback would anchor the query on a *different*
     name and the server would answer confidently about it — worse than the
     empty answer, and the one failure this parameter shape exists to avoid.
   - **`file` without `line` is answerable, which the plan did not say.** The
     index route restricted to that file, and when the index has no entry
     (a Java method, S10; a short Ruby name, H6) the first bounded occurrence
     in the file, under a note saying which line was used and why. It is the
     honest middle between the two shapes item 1 describes, and it is the
     shape a model reaches for after a `grep` that printed no line number.
   - **A snippet is one line, not "the range plus a few lines of context".**
     45 hits × 3 lines is the volume problem the cap exists for, and the
     operation that returns prose is `hover`. An out-of-root row also keeps a
     bare *basename* rather than nothing: H3's six rows of `Object` from four
     unrelated gems are indistinguishable noise without one, and a basename is
     provenance that still cannot be opened.
   - **The out-of-root refusal is a *lexical* root test**, not "does
     `resolve_for_read` raise". Under `AllowAll` — the container wiring — it
     never raises, so the arm this note chose would have been a no-op exactly
     where the trifecta answer leans on it. The boundary that matters is the
     server's own `rootUri` anyway: outside it a server answers about a file it
     does not consider part of the project, which is a *different* lie from the
     one the gate prevents.
   - **A reply pikuri cannot parse is relayed too**, which is the relay rule
     reaching further than the note stated: the wire types raise `KeyError` for a
     location missing its `range` and `ArgumentError` for a `definition` that
     answered a bare String, and a turn dying on a backtrace nobody reads is the
     precise failure the stance exists to prevent. It is the server's bug, so it
     goes back as a sentence naming the operation and the shape.
   - **The tool description says nothing about *results*, only about
     mechanics** (decided 2026-08-18, in review). Two sentences an earlier draft
     had are gone: that the first call waits for the index, and that an
     unsupported operation refuses cleanly. The model has no notion of time, so
     the only content in the first is an implied promise that results are now
     complete — and a fully-started server can still be broken, which is exactly
     what the model must stay free to notice. The second it learns from the
     refusal itself. What survives is how to anchor a call and what shapes the
     answer arrives in; the error strings carry the rest, which is what makes
     them worth their length.
   - **Out-of-root results carry a path where the workspace would read one**
     (decided 2026-08-18, in review). `design.md`'s snippet-only rule is true
     under root confinement and false under `AllowAll`: `bin/pikuri-code --yolo`
     and `bin/pikuri-os` open a gem checkout happily, so suppressing the path
     there deletes a capability the wiring granted, and the description's "a
     file you cannot open" was simply not universal. `Sources` asks
     `resolve_for_read` per path instead — the path where it would open, the
     basename where it would not. The legs do not move: `untrusted: :hard` is
     already unconditional *because* results reach outside the root.
   - **"Not ready yet" never has to be said, so the third distinct string is
     the death report.** The gate blocks instead of relaying, so the three that
     must stay apart are *unsupported* (a `Refusal` naming the missing
     capability), *answered nothing* ("that is what it said, not proof that none
     exist") and *could not be asked* ("the ruby server died while its index was
     building"). Related: a fan-out labels its blocks `From the <id> server:`,
     so an entry's `id` does reach the model after all — what survives is that
     the model never *supplies* one.
7. ~~**Lazy start, and the relevance rule that comes with it**~~ **Landed**
   (decided
   2026-08-18, and it reverses step 2's "spawn synchronously at boot"). A
   server starts on **first use**, not at boot: jdtls in a Ruby project is a
   JVM and a 78s import for a language the project does not contain, which is
   erratic behaviour rather than a cost. What changes:

   - `Servers#start_all` goes away. `#client_for(path)` spawns-and-memoizes,
     and `#all` becomes an **active** set — the registered entries claiming at
     least one file in the project — which it spawns on demand.
   - **Laziness alone is not enough, because the capability gate needs a live
     handshake.** `Navigator` partitions `@servers.all` on
     `ClientWrapper#supports?`, which reads *this* workspace's `initialize`
     response, so a fan-out cannot decide who to ask without starting them. The
     `file`-anchored path is where laziness pays in full (one server, and the
     anchor file *proves* relevance — no project walk at all); the
     bare-`symbol` path still starts every candidate, which is why "candidate"
     must mean project-scoped rather than everything registered.
   - **So relevance is computed once, on the fan-out path, memoized** — a
     pruned walk honouring `denied_roots` (or `Workspace::Search::Glob`),
     short-circuiting per entry. It costs nothing measurable on a path that is
     about to block for a whole index, and **boot does zero work.**
   - `Navigator`'s `raise Refusal, 'no language server is running' if
     @servers.empty?` inverts under lazy start — nothing is ever started, so
     every call would refuse. It becomes a *registry* emptiness check.
   - `#client_for` can now raise `ServerDied` mid-call, so `Navigator` grows
     that relay arm — the same string shape as the existing death-mid-request
     one.
   - **Missing-binary loudness is dropped, deliberately.** See
     `lsp/design.md` §"Missing binary at boot", reversed there: first use
     reports `"Error: cannot spawn ruby-lsp: …"` (already
     `ClientWrapper.spawn_child`'s wording) and the model relays it to the
     human. One policy instead of two — identical to the already-decided
     die-on-child-death arm — and the boot-raise was only ever defensible
     while spawning was eager. This also dissolves the asymmetry against
     `Mcp::Servers#start_all`'s log-and-drop: with no boot spawn there is no
     boot failure to compare.
8. ~~**`Lsp::Extension`**~~ **Landed.** `configure` builds the `Servers` set (constructing
   only — nothing spawns), registers the tool via `Configurator#add_tool`
   (**not** `add_raw_tool`, or the legs go invisible), arms `on_close`; `bind`
   hands the tool the emitter
   (`tool.on_progress = ->(progress) { ctx.emit_event(progress) }`).
   Contributes **no** `trifecta_contribution`. `Mcp::Extension#configure` is
   the shape verbatim, including `return if @registry.empty?` and the
   construct → arm `on_close` → *(no longer)* start ordering.
9. ~~**Progress has to render, which is a `pikuri-core` change**~~ **Landed**
   (decided 2026-08-18). `ServerProgress` exists because a 78s block must be legible,
   and today nothing renders it: it defines no `to_s`, so
   `Listener::Terminal`'s generic domain-event arm prints
   `· #<data Pikuri::Lsp::ServerProgress …>` — and that arm does not
   `Sanitizer`-defang, though `ServerProgress`'s own yardoc delegates the
   defanging to whoever renders it. Three edits:

   - **`ServerProgress#to_s`**, the `Code::PlanModeChanged` /
     `Skill::Promoted` precedent — they define one *because* the arm is
     generic.
   - **The generic arm sanitizes, unconditionally.** Not an LSP fix: every
     gem domain event's `to_s` can carry foreign text (skill names off disk,
     MCP descriptions, server-supplied titles), and `truncate_tool_result`
     is one `Sanitizer.sanitize(…).text` call away already.
   - **A transient arm**, because at `Readiness::TICK` 0.1s a cold import is
     hundreds of scrollback lines. Core must recognize "this replaces its
     predecessor" without knowing `pikuri-lsp` exists, so: an
     `Event::Transient` marker module in core with a two-method contract
     (`to_s` for the text, `done` for retire-the-line), which
     `ServerProgress` includes; `Terminal` prints it with `\r` and no
     newline through the existing `@at_line_start` machine and clears on
     `done`. Two deliberate simplifications: **not a tty ⇒ only the `done`
     event prints** (a `\r` stream into a pipe is one unreadable mega-line),
     and **one transient line, last-writer-wins** rather than one per server
     — two concurrent bars needs ANSI cursor movement the demo listener does
     not earn, and `server_id` is in the text.
10. ~~**Tests, split by what each can actually prove**~~ **Landed** (decided 2026-08-18;
    the earlier plan was one line, "live smoke specs, tagged to skip when the
    binary is absent"). **No real language server becomes a test
    dependency.** ruby-lsp is cheap to *start* — pure Ruby, no JVM — but its
    dependency closure would enter the monorepo `Gemfile.lock`, so one of its
    releases can redden CI for work unrelated to LSP; it cannot be made to
    reproduce the failure modes this design is built on; and it does nothing
    for the jdtls half, so the real-server leg stays half-covered either way.

    - **10a — a dummy server binary, in CI.** `Lsp::Testing::FakeServer` runs
      in-process over `IO.pipe`, so it covers framing, demux and the value
      types but never `Open3.popen3` with argv/env/`chdir`/`pgroup`, real
      process death, SIGTERM-to-the-group teardown, the reap, the stderr tail,
      or restart-on-death against a real pid — which is the whole reason
      `lsp/client_wrapper.rb` is a `Subprocess` seam exception. That leg is
      ~60 lines in `spec/support/`: read framed JSON on stdin, answer a canned
      handshake, plus flags to die on the third request or exit without
      answering. Zero dependencies, deterministic, and it can be *told* to
      misbehave.
    - **10b — `bin/pikuri-lsp-check`, never in CI.** Something must still
      re-validate S1/S2/S5 and the *reconstructed* fixtures against a real
      server, and a skip-when-absent spec is the worst home for it: it reports
      green by staying silent. `bin/pikuri-wire-check` is the precedent — a
      dev diagnostic that says "I could not ask" rather than passing. Run by a
      human after a server upgrade. Six probes, each naming the decision it
      guards, and each reporting *ok* / *DRIFT* / *no answer*.

    **What building the two halves found**, both of which are why the split was
    worth it:

    - **A clean shutdown stranded the helpers a server forked.** `reap_child`
      only signalled the process group when the child *ignored* `exit`, so the
      group sweep that `pgroup: true` exists for never ran on the happy path —
      exactly the case jdtls's forked helpers are in. The dummy's
      `--fork-helper` caught it in one run; nothing the in-process fake can do
      would have. Fixed: the leader is stopped, then the group is swept
      regardless.
    - **pikuri's own bundler environment leaks into a Ruby language server.**
      A host that boots under `bundler/setup` hands `BUNDLE_GEMFILE` and
      `RUBYOPT` to the child, and `ruby-lsp` then refuses to run at all
      ("can't find executable ruby-lsp for gem ruby-lsp") unless the agent's
      own Gemfile happens to list it. The check script wraps its spawn in
      `Bundler.with_unbundled_env`, which a `bin/` script may do; a library
      host cannot, and `StdioEntry#env` cannot express it either, because its
      validator takes `Hash{String=>String}` and *unsetting* a variable needs
      a `nil`. **Open**: either `env:` learns that `nil` removes a variable, or
      this becomes a documented note for whoever wires a Ruby server. Nothing
      in pikuri filters `ENV` and nothing should start — this is the
      per-child channel's job.

**The entry.** `Pikuri::Lsp::Registry::StdioEntry`, a `Data.define`. Types
are yardoc-exact; the *why* for each field is
[`lsp/design.md`](lsp/design.md) §Configuration, and the two worked literals
(including what every part of the jdtls command means) are §"The two book
examples".

```ruby
StdioEntry = Data.define(:id, :command, :files, :language_id, :env, :init_options)
```

| field | type | req? | what it is | `ruby-lsp` | `jdtls` |
| --- | --- | --- | --- | --- | --- |
| `id` | `String` | ✅ | this server's name in log lines, restart messages, the degrade string, and `ServerProgress#server_id`. Never model-facing — the model names no server. Duplicates raise. | `'ruby'` | `'java'` |
| `command` | `Array<String>` | ✅ | argv, `Subprocess.spawn` convention (the documented seam exception). Spawned with cwd = the `Workspace` root, always. | `%w[ruby-lsp]` | `['jdtls', '-data', Paths.cache.join('jdtls', slug).to_s]` |
| `files` | `Array<String>` | ✅ | the dispatch key: globs matched against the **basename**, first match in declaration order wins, no overlap detection. Globs not extensions, because `Rakefile` has none. | `%w[*.rb *.rake *.gemspec Rakefile Gemfile]` | `%w[*.java]` |
| `language_id` | `String, nil` | — | the `languageId` every `didOpen` carries. `nil` derives it from a built-in table via the entry's first extension-bearing glob — per *entry*, not per file. Values are the LSP spec's language identifiers. | `nil` → `'ruby'` | `nil` → `'java'` |
| `env` | `Hash{String=>String}` | — | merged over the inherited environment; the legitimate per-child channel of the "Environment is not a secret store" seam. Carries `JAVA_HOME` here, not a token. | `{}` | `{ 'JAVA_HOME' => ENV.fetch('JAVA_HOME') }` |
| `init_options` | `Hash, nil` | — | passed verbatim as `initializationOptions` at handshake time; pikuri never parses it. The home for outbound per-server glue. | `nil` | `{ extendedClientCapabilities: { classFileContentsSupport: true } }` |

So a Ruby entry is three lines and two facts (`command`, `files`), and the
Java one exercises the rest — each for a reason the reader can check by
deleting it: without `-data` two same-named checkouts collide in a hardcoded
`~/.cache`, without `JAVA_HOME` the launcher hard-fails below Java 21, and
without `classFileContentsSupport` every library symbol answers with silence
(J4).

**Deliberately absent, each a decision rather than an omission:** no `root:`
/ `cwd:` (one root, so the LSP's project and the confinement boundary cannot
diverge), no `startup_timeout:` (no value is defensible; child death is the
real signal), no `content_request:` (a protocol method is code, not config —
pikuri hardcodes the one-row scheme table instead), and no `settings:` yet —
deferred, though both harnesses ship one, so say that rather than implying
nobody needs it.

**The tool.** `operation` (enum of ten), `symbol` (required), `file` and
`line` (optional). Column derived by `locate(text, symbol)`, never asked
for. Rendering rules, all measured: cap and group (`findReferences` hardest
— S9's 80,609), group `supertypes` by name preferring the declaration over
namespace reopenings (H2), a path outside the root only where the workspace
would read it (see step 6's deviations), the scheme table
for `jdt:`, never dereference `http(s):`, and keep *unsupported* /
*answered-nothing* / *not-ready* three distinct strings.

**An anchor that resolves outside the root is refused with its own
message** in v1 (the fork, and the two arms not taken, are below). With
`file` + `line` the ordinary shape, the anchor is in-root by construction
almost always, and what is lost — following a hop *into* a dependency — is
still answered by `hover` and the scheme table.

**Explicitly not in v1**, each with its home: observing the agent's own
edits (a settled shape, deferred — `design.md` §"Observing the agent's own
edits"), diagnostics, `rename` / formatting / code actions, an `lsp_read`
operation, and the operations left out of the enum — `subtypes` (H7/H8),
`prepareCallHierarchy` (collapsed inside the tool), `declaration`,
`completion`.

## The forks behind the v1 calls

The worklist, now that every item on it is decided — kept because each
fork's *alternatives* are what a reader would otherwise re-litigate, which is
what an `ideas/` note owns. The original nine closed as: 1, 7, 8 and 9 by the
document-sync run, 5 and 6 by the hierarchy runs and the harness survey, 3
folded into fan-out below, and 2 and 4 answered in §"The v1 build".

### 1. The parameter shape: `symbol` replaces `character`

Deliverable, and the run settles which half is deliverable how:

- **`symbol` + `file` + `line` → the column, derived by the tool.** One
  line read, one string search, no index and no server involvement. This
  works on every server that will ever be wired, and it is the whole point:
  **nothing in the model's input contains a column.** `Read` prints
  line→text, `grep` prints `file:line:text`; producing a column means
  counting characters in a line the model saw as prose, exactly right, with
  tabs and multibyte. Being wrong is not an error — S8 has `definition`
  answering 0 at a keyword column, and S9 has `references` seven columns
  off returning **80,609** results instead of 2.
- **`symbol` alone → position via `workspace/symbol`** is the half that is
  *not* reliable, in opposite directions per server: H6 (a bare namespaced
  Ruby class scores below ruby-lsp's 0.7 Jaro-Winkler threshold and is never
  returned) and S10 (jdtls indexes no methods, so a Java method name is
  unreachable). Ship it as a best-effort convenience that reports honestly
  when it resolves nothing, and let `file` + `line` be the shape the tool
  description actually teaches.
- Two mechanical rules survive from the runs: the exact-name filter
  compares the **last `::` segment**, never `name` (H6, deliberate in
  ruby-lsp's source), and `locate(text, symbol)` is mandatory on both
  servers for different reasons (H5 strict, S8 strict-per-operation).
- An optional `character` override is strictly additive if the derived
  column ever disagrees with what the model meant. Not v1.

### 2. What anchors a hop that resolves outside the root

**Decided in "The v1 build" above** — refuse with its own message. This is
the full fork, kept because the other two arms are what a reader will ask
about.
With `symbol` alone, `workspace/symbol` can place the anchor in a gem file
outside the workspace root, or behind a `jdt:` URI (J5). Every
position-based operation then needs a document the tool is not allowed to
open. Result *rendering* has an answer (snippet-only, the scheme table);
the *anchor* does not. Three arms, and they need not all get the same one:
refuse with a distinct message, permit a read-only `didOpen` of an
out-of-root `file:` path, or `didOpen` the virtual URI with the text the
scheme table already fetches (nvim-jdtls does the last).

Smaller than it was: with `file` + `line` the normal shape (item 1), the
anchor is in-root by construction almost always, so "refuse with a distinct
message" is a defensible v1 — the capability lost is following a hop *into*
a dependency, which `hover` and the scheme table still answer.

### 3. What the tool and the registry entry are missing

**Answered in "The v1 build" above** — the entry's field table, with
`language_id:` optional behind a built-in table; the reasoning is below.

**The tool.** The Sketch names only the emitter handoff. It also needs the
client set and a `Workspace::Filesystem` — for `denied?`, the root
confinement, the seam-routed read behind the sync notification, and
`private?` on the trifecta declaration (the closed item 9 makes that last
one load-bearing: the tool declares all three legs itself, so it must hold
the filesystem). One line in the Sketch closes this.

**The entry needs a `languageId`, and this is the one real hole the harness
survey found.** `didOpen` carries a `languageId` and pikuri's
`StdioEntry#files` is a list of *basename globs*, which cannot answer what
to put there. Both harnesses carry an extension→language-id map
(grok-build's `extensions:`, opencode's `LANGUAGE_EXTENSIONS` with a
`"plaintext"` fallback). Either `files:` becomes a glob→id map, or a single
`language_id:` rides alongside it — right for a one-language server, wrong
for the `eslint`-shaped server that claims eight extensions. Decide before
the client is written; see
[`lsp/harness-analysis.md`](lsp/harness-analysis.md) §"Two gaps".

Also folded in here: **fan-out.** A bare-`symbol` call fans out to every
**project-relevant** server and therefore waits for all of them to be ready,
so a question in a mixed Ruby/Java repo pays jdtls's cold import (78s, J6) the
first time. That follows from the no-timeout rule and is acceptable — and with
`file` the normal shape it is the rare path rather than the default.

*Amended by step 7's lazy start:* "every registered server" was the original
wording, and under a **global** registry — which is what
`lsp/design.md` §"Where the user actually writes this" settled on, since which
binaries you have installed is machine state — it meant a pure-Ruby project
paying for the `java` entry its owner added once, in every session. Relevance
is now project-scoped, so the sentence is about a repo that really does
contain both. The rejected mitigation stands and its reason is sharper: fanning
out only to servers *already started* would make the same query answer
differently depending on what an earlier call happened to touch, which is worse
than latency.

## Closed by the harness survey

Full reading in [`lsp/harness-analysis.md`](lsp/harness-analysis.md); the
outcome, so nobody re-derives it:

- **The v1 enum is ten operations, harness names verbatim plus one** —
  `goToDefinition`, `findReferences`, `hover`, `documentSymbol`,
  `workspaceSymbol`, `goToImplementation`, `incomingCalls`, `outgoingCalls`,
  `goToTypeDefinition`, `supertypes`. Claude Code and opencode ship an
  identical nine (near-identical tool text too, so they count as roughly one
  data point); grok-build ships six, a strict subset; the last two are
  measured deviations.
- **`subtypes` is out — and the reason is now measured, not merely an
  absence.** H7/H8: on jdtls, `goToImplementation` answers "list all
  subtypes" **transitively in one call** (abstract `Widget` → all 3
  descendants) and works on *concrete* classes too (`Panel` → 2), while
  `typeHierarchy/subtypes` returns the direct children only (`Widget` → 1)
  and needs one round trip per level. On ruby-lsp it is the `# TODO` (H1).
  So there is **no server on which `subtypes` is the best available
  answer**, and the question that motivated it is already served by an
  operation in the enum. `findReferences` is *not* the substitute — H10 has
  exactly 1 of 4 hits being the `extends` site, unlabelled.
- **`supertypes` is in, as the tenth.** It is the one hierarchy operation
  that works on **both** servers (H2 on ruby-lsp, H9 on jdtls), and the one
  with no substitute: `goToDefinition` on the name after `extends` answers a
  single level, whereas the *chain* takes one call per level — which the tool
  walks internally, the same collapse `workspace/symbol` and `prepare*` get.
  Marginal cost is one enum value and one dispatch arm, because the
  prepare-then-fetch machinery is already required by the call pair. Two
  known consequences: H2's grouping pass is mandatory (14 rows of namespace
  reopenings for one Ruby class, declaration ordered last), and an ancestor
  walk reaches jar URIs routinely (H9's `Object`), so the scheme table is on
  this path too.
- **`documentSymbol` is in**, reversing `design.md`'s cut: all three ship it,
  and S10 makes it the only route from a Java method *name* to a position.
- **`goToTypeDefinition` is in**, the one deviation from all three, because
  J9 measured what nothing else recovers (`var names = new ArrayList<>()`).
- **`prepareCallHierarchy` stays out** — the one place pikuri narrows a
  2-of-3 majority, because exposing it hands the model an opaque
  `CallHierarchyItem` to echo back; the prepare hop runs inside the tool.
- **Two harness habits are confirmed and adopted**: `workspaceSymbol` fans
  out and takes no position (opencode documents `filePath` as a
  server-selector only), and a read-only tool takes no confirmer.
- **One convergence is rejected with evidence**: both visible harnesses
  sync documents with version-tracked ranged whole-document `didChange`
  events — and grok-build's `capabilities.rs` opens by describing S1's
  failure against *Roslyn*, which is the finding independently confirmed on
  a third server. The scheme still loses to S2 on ruby-lsp (document fresh,
  index stale), and opencode ships a `ruby-lsp` definition, so pikuri keeps
  its own re-open policy.
- **Also confirmed by contrast**: nobody caps results (S9's 80,609-location
  `references` would arrive as raw JSON in opencode), nobody gates per
  operation, and nobody waits for indexing — the three places pikuri
  deviates deliberately.

## Closed by the document-sync run

Recorded here rather than deleted, because each one's *resolution* is what
a reader would otherwise re-litigate. Findings `S1`–`S10` in
[`lsp/research.md`](lsp/research.md); the settled policy is in
[`lsp/design.md`](lsp/design.md) §"Document synchronization".

- ~~**Document synchronization across calls**~~ (was items 1 and 7).
  **Settled, and the leaning was wrong.** The leaned scheme — a per-server
  open-URI set, `didOpen` on first touch, full-text `didChange` with an
  incremented version when the digest moved — fails on the first server it
  meets: ruby-lsp declares incremental sync and *crashes* on a rangeless
  full-text change, reporting it only to `window/logMessage` (S1). The
  ranged variant is honoured, and then desynchronizes the *index* from the
  document it just updated (S2), so `definition` answers `[]` for a symbol
  the server can see. What works on both servers is the thing the spec
  forbids: **re-send `didOpen` with the current disk text before every
  call** (S5) — no versions, no digests, no `didClose` (which resyncs
  ruby-lsp and does nothing for jdtls, S6). The reason it is sound rather
  than merely lucky is that **pikuri has no unsaved buffers**: `write` and
  `edit` land on disk immediately, so the tool never owns state the disk
  lacks, and the spec's own out-of-band channel
  (`workspace/didChangeWatchedFiles`) is ignored precisely because a client
  that opened a document is *presumed* to be its authority (S7).
- ~~**Does jdtls anchor like ruby-lsp?**~~ **No, and not uniformly within
  itself** (S8): `prepareTypeHierarchy` answers from any column on the
  declaration line including the keywords, while `definition` answers 0 at
  a keyword column, and `workspace/symbol` reports the *symbol* column
  where ruby-lsp reports the *keyword* column. `locate(text, symbol)` is
  load-bearing on both servers; the per-server reasons are not worth
  modeling.
- ~~**Does `Filesystem#denied?` have an opinion outside the root?**~~ (was
  item 8). **Only under `AllowAll`, and that is fine.** Measured against
  the real classes: the scoped `Filesystem` — `bin/pikuri-code`'s wiring —
  has `denied_roots == []` and answers `denied?(path) == false` for
  *everything*, in-root and out, while `resolve_for_read` raises for every
  out-of-root path. `AllowAll` answers `true` for `~/.ssh`, `~/.ssh/id_*`
  and `/etc/shadow` and `false` for gem paths, `~/.m2/repository` and a
  nonexistent path, symlink-resolving first and never raising.

  So: **root confinement carries the out-of-root boundary alone**, and the
  `denied?` pass is load-bearing exactly where it was designed to be — the
  container wiring, where an LSP result *could* name a credential path and
  nothing else would stop it. `design.md`'s sentence "`Filesystem#denied?`
  still applies" is true but weaker than it reads; keep the pass (it is
  cheap, exact and fails closed) and stop implying it filters gem paths.
- ~~**Does `Lsp::Extension` contribute trifecta legs?**~~ (was item 9).
  **No — it must not override `trifecta_contribution` at all**, and the
  base class already returns `nil`, so this costs nothing. Three mechanics
  make it definite: an extension registers a real `Pikuri::Tool` through
  `Configurator#add_tool` at *configure* time (the `Tasks::Extension`
  shape), which lands it in `agent.tools`, so `Trifecta.build` reads its
  `trifecta_legs` directly — `add_raw_tool` is the leg-invisible path and
  is only for MCP's and sub-agents' synthesized `RubyLLM::Tool`s. A
  contribution's legs are *unioned* per label, and `legs | legs == legs`
  (verified), so a duplicate declaration would not move the verdict —
  the harm is the map: a `(lsp)` row would appear beside the `lsp` row
  carrying the same three legs, and `Contribution#label` is what
  `Report#attribution` points the reader at, so it would blame the
  extension for a declaration living on the tool. And an MCP-shaped
  `ASSUMED` contribution would actively *widen* the answer —
  `legs | ASSUMED` flips egress to `:unreviewed` / `:attacker_reachable`
  (verified) — which is the opposite of the measured truth.

## Graduation

When built: protocol mechanics + the "capabilities are per-workspace"
and "empty result ≠ no definition" lessons → book chapter (both are
better taught with the observation that a shipped client gets the second
one wrong, and the second is sharper for J3's contrast — one server
defers, the other answers `[]`, and only one of them can be trusted);
the silent-empty traps (pre-index query, an undeclared
`classFileContentsSupport`, a fuzzy `workspace/symbol` hit, an advertised
provider wired to a `# TODO`) → one book section, since they are the same
lesson wearing four hats; **the document-sync policy** → yardoc on the
client plus a book paragraph, because "an agent is not an editor: it has no
unsaved buffers, so it must not own documents" is the whole reason the
spec-forbidden re-open is the right answer; per-symbol
rationale → yardoc on `Lsp::ClientWrapper` / the tool, including why the
`operation` enum is static while gating happens at dispatch; the
walked-path-filtering and Subprocess-exception invariants → a `CLAUDE.md`
seam entry; the entry's field-by-field rationale → yardoc on
`Lsp::Registry::StdioEntry`, and the two worked configs → the book chapter
(the *no configurable root* rule is the one that also wants a sentence in
the seam entry, since it is what keeps the LSP's project and the
`Workspace` root the same boundary);
**direct-vs-MCP with the bridges named**, **no-timeout with its three
replacements** (plus the startup and failure policy that falls out of it:
spawn synchronously at boot so a missing binary raises, index in the
background, block the first call for as long as it takes, and on child
death return `"Error: …"` with **no fallback suggestion** — the tool works
or it errors, and never proposes grep), **the harness-sourced operation
surface with relay-don't-work-around as its rule** (rejected: a per-server
known-stub list; per-server readiness predicates; an enum sized to what two
servers implement), and **the scheme table** (standard-first, one hardcoded
`jdt:` row, rejected alternatives: standard-only — which made the Java arm
untestable — and a `content_request` config field; plus the deletion
condition), and **the declared trifecta legs** — one entry for all three
axes, since it is one declaration a reader questions once: `:no_egress`
despite a child that goes online (rejected: a `:tool_vouched` tag on the
vetted-destination argument; inheriting MCP's `ASSUMED` on the shared
foreign-stdio-binary shape) and unconditional `untrusted: :hard` (rejected:
riding `filesystem.trusted?` the way {Pikuri::Workspace::Read} does;
confining results to the root to earn `:none`), **with the trusted-checkout
verdict flip stated as a consequence** → five new `DECISIONS.md` entries
(suggested slugs `lsp-direct-not-mcp`, `lsp-no-startup-timeout`,
`lsp-operation-surface`, `lsp-scheme-fallback`, `lsp-trifecta-legs`, with
the usual prefix); the threat model itself, including the
unsandboxed-child asymmetry against `Code::Bash` → `pikuri-lsp/DESIGN.md`;
the COMPARISON.md LSP column → `✅`.
Then delete this file **and the whole `lsp/` folder with it**, plus the
superseded LSP bullets in `coding-agent.md` and `claude-parity.md`.

The scheme table also wants a line in the `CLAUDE.md` seam entry, since
"pikuri-lsp reads only `file:` paths and one enumerated server-private
scheme, never the network" is an invariant someone could break by adding
a row without noticing.
