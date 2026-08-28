# Concurrent tool use — the improvements still on the table

Status: **open**, narrowed. The *documentation* half shipped 2026-08-28: every
tool now declares one of four postures, `Agent` says it is thread-unsafe, and
the two forks are logged as `DECISIONS.md` `D_tool_sharing_postures` +
`D_rate_limiter_scope`. Read those first — this note keeps only what is still
undecided.

What remains is the author's second question: *now that every tool has a
posture, which ones should we improve?* Nothing in `lib/` runs two agents
concurrently yet, so none of this is urgent; the point of the list is that the
decision is now visible per tool instead of being discovered by a host in
production.

## Where the sweep landed

For the record, so the list below has a baseline. 35 tools:

- **`P_stateless`** (4) — `calculator`, both `fileindex_*`, `recall`.
- **`P_shared_locked`** (6) — the three `vectordb_*`, both plan-mode tools,
  `web_search`.
- **`P_shared_benign`** (2) — `fetch`, `web_scrape` (the on-disk `UrlCache`).
- **`P_one_agent`** (23) — the file tools, `bash`, `git_clone`, the four
  `task_*`, `skill`, `lsp`, `mcp_connect`, `agent`, all seven
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
2. **`Search::RateLimiter` — the stall is worth a look.** The mutex is held
   across the HTTP call, so ten agents serialize into a 20 s+ wait that
   `Cancellable` cannot break. Three options: leave it (correct, and the result
   cache means the second agent asking the same thing never reaches the
   limiter); `Mutex#try_lock` and raise `Unavailable` so the cascade falls
   through to another provider, turning a stall into a fallback — cheap, and
   the cascade exists for exactly this; or separate the pacing sleep from the
   request so only the bookkeeping is under lock (more surgery, keeps the
   pacing exact). Leaning on the middle one.
3. **MCP and LSP — accepted as one-agent-only.** Both hold unguarded client
   hashes and a `#close` that kills children another caller could be mid-request
   on, so ten agents over one project means ten sets of child processes. A
   shared pool behind a lock is buildable and simply isn't built; the cost is
   real (jdtls twice is not free) but nobody has paid it yet. Revisit when a
   host actually runs a multi-tab coding agent.
4. **`Gloda` / `Calendar` — one instance per agent, or one lock.** The
   freshness rebuild swaps the connection under a concurrent query. Sharing one
   behind a lock would be *better* than one-per-agent (the ~1 s FTS5 rebuild
   would be paid once, not N times), so this is the case where the improvement
   buys something measurable rather than just safety.
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

- **Should the cross-agent `UrlCache` / `Engines::CACHE` flow be examined by
  the taint work?** Agent B's search can be answered from agent A's cached
  result. Almost certainly fine — it is a public search engine's answer to the
  same query, and the cache is already cross-*process* — but it is a real
  cross-agent information flow and `ideas/private-context-taint.md` is where
  that question lives. Cheap to settle: probably one sentence there saying
  public-URL content is nobody's private context, which is what
  `Pikuri::UrlCache` now claims.
- **What would a spec for any of this look like?** `rake test` is
  single-threaded and a race that reproduces one run in fifty is worse than no
  test. The testable part is *structure* — a limiter constant is class-level,
  one `Workspace`'s read record does not answer for another's — which guards
  against a future refactor moving a limiter onto an instance. Worth writing if
  and only if we act on item 2.

## Graduation

The vocabulary, the postures and the rate-limiter rule are already in their
durable homes (yardoc + CLAUDE.md + the two `D_` entries). What is left here is
a decision list; each item graduates into the fix's own home when it is acted
on — item 1 into `ideas/more-confirmers.md`, item 2 into
{Pikuri::Tool::Search::RateLimiter}'s yardoc plus a line on
`D_rate_limiter_scope`. Delete this file when the last item is settled.
