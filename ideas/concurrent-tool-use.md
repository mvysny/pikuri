# Concurrent tool use — the improvements still on the table

Status: **open**, narrowed. The *documentation* half shipped 2026-08-28: every
tool now declares one of four postures, `Agent` says it is thread-unsafe, and
the two forks are logged as `DECISIONS.md` `D_tool_sharing_postures` +
`D_rate_limiter_scope`. Items 1 and 2 closed the same day —
`D_tool_cancellation` came out of the second. Read those first; this note keeps
only what is still undecided.

What remains is the author's second question: *now that every tool has a
posture, which ones should we improve?* Nothing in `lib/` runs two agents
concurrently yet, so none of this is urgent; the point of the list is that the
decision is now visible per tool instead of being discovered by a host in
production.

## Where the sweep landed

For the record, so the list below has a baseline. 35 tools:

- **`P_stateless`** (4) — `calculator`, both `fileindex_*`, `recall`.
- **`P_shared_locked`** (6, now 11) — the three `vectordb_*`, both plan-mode
  tools, `web_search`; plus the five Thunderbird read tools, which item 4
  moved.
- **`P_shared_benign`** (2) — `fetch`, `web_scrape` (the on-disk `UrlCache`).
- **`P_one_agent`** (23, now 18) — the file tools, `bash`, `git_clone`, the
  four `task_*`, `skill`, `lsp`, `mcp_connect`, `agent`, and two of the seven
  `thunderbird_*`.

The interesting result is that a tool is a value object holding a `Proc`, so
almost none of them own state — the posture is always the collaborator's. That
is why the four things a threaded host would actually break are not tools:
`Confirmer::Terminal`, `Listener::Terminal`, `Paths.new_temp` and `Agent` — and
two of those four turned out to be demo chrome rather than defects (items 1 and
5), which is itself the lesson.

## The per-tool decisions

Ordered by whether I'd act. Each is "leave it" until someone says otherwise —
`P_one_agent` is a legitimate answer and most of these are.

1. **`Confirmer::Terminal` — closed, don't fix (2026-08-28).** I had this as
   the one safety issue: two agents prompting at once interleave on one
   terminal, and either `gets` can consume the answer typed for the other, so a
   command gets approved unread. True, and irrelevant — the class exists for
   pikuri's own single-threaded `bin/` scripts and is unfit for any real host
   (a TUI or web client owns the screen and the event loop; it cannot have a
   library class calling `puts`/`gets` behind its back). So the proposed
   `Confirmer::Serialized` decorator was library work whose entire value rested
   on a demo's shortcut, which is the thing CLAUDE.md's `bin/` doctrine tells
   you not to build. It is now marked as reference chrome in its own yardoc.
   Deleting it or inlining it into `bin/pikuri-code` was considered and
   rejected: 237 lines inside the demo makes the demo *less* readable (the
   doctrine's actual goal), there is only one consumer so DRY isn't the
   question, and it is the only place the warning-gated retype — security
   logic a real host must reimplement — is demonstrated.
2. **`Search::RateLimiter` — done (2026-08-28), differently than planned.** The
   note's original lean was `try_lock` + fall through the cascade; that is
   *wrong* and stays recorded as such, because the no-config default is
   DuckDuckGo alone, so there is nothing to fall through to and "wait 2 s"
   would have become "search failed". The shipped answer is
   `Cancellable#sleep`: the pacing wait is now interruptible, so a queued agent
   can abandon it on a user cancel. See `DECISIONS.md` `D_tool_cancellation`.
   Two pieces deliberately left undone — making the *mutex acquisition*
   interruptible (needs three concurrent agents to matter), and bounding the
   wait so a backed-up provider is skipped (only sensible with ≥2 providers
   wired).
3. **MCP and LSP — closed, one-agent-only on purpose (2026-08-28).** Both hold
   unguarded client hashes and a `#close` that kills children another caller
   could be mid-request on, so ten agents over one project would mean ten sets
   of child processes. A shared pool behind a lock is buildable and stays
   unbuilt, because the demand isn't there: both are *coding* tooling, coding is
   TUI work, and a TUI is one agent. The cost of being wrong is bounded and
   visible (jdtls twice is slow, not incorrect), so reopen if it ever bites
   rather than building for a host nobody has asked for.
4. **`Gloda` / `Calendar` — done (2026-08-28), now `P_shared_locked`.** A
   `Mutex` closes the rebuild-swaps-the-connection race, and sharing became the
   *better* wiring rather than merely the safe one. Everything durable landed
   elsewhere: the contracts in each class's `== Sharing`, the
   why-a-lock-here-but-not-for-item-3 fork in `DECISIONS.md`
   `D_gloda_locks_mcp_does_not`. One thing the sweep got wrong and is worth
   remembering while reading the rest of this list: the documented race was not
   the real hazard — `Extension` *reuse* was, where two backends land on one
   snapshot path and `cp -f` under each other's open fd. The postures were a
   map of races; they did not point at the lifecycle bug next to them.
5. **`Listener::Terminal` — leave it.** Scrambled stdout is a `bin/` script's
   problem, and the standing rule is that a demo's shortcuts are not pikuri
   policy: a TUI with per-tab buffers doesn't have this problem at all.
6. **`Paths.new_temp` — docs only, probably done.** It is a factory, so there is
   no collision; the trap is a host memoizing one dir at process scope and
   handing it to ten agents. Worth one clause in its docstring ("and per
   agent"), not a code change.
7. **`SubAgentTool`'s id counters and `GitClone`'s sandbox memo — leave.** Both
   are unguarded, both only reachable if you share a tool that is
   `P_one_agent` for stronger reasons anyway.

## Still open, not per-tool

- **What would a spec for any of this look like?** Partly answered by item 2:
  the cancellation specs drive two real threads and assert a *cut-short*, which
  is deterministic in a way "did they race?" never is. What is still unwritten
  is a structural guard — that a limiter constant stays class-level, that one
  `Workspace`'s read record does not answer for another's — which is what would
  catch a future refactor quietly moving a limiter onto an instance.

## Graduation

The vocabulary, the postures and the rate-limiter rule are already in their
durable homes (yardoc + CLAUDE.md + the two `D_` entries). What is left here is
a decision list; each item graduates into the fix's own home when it is acted
on — item 1 landed in `Confirmer::Terminal`'s own yardoc, item 2 in
`D_tool_cancellation`. Delete this file when the last item is settled.
