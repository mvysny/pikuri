# Requirements

What must hold — the promises the README's pitch makes, as official rules. One entry per
promise. A requirement *states*; it never argues: the fork behind it, if there is one, is a `D_`
entry it cites.

- **Owner-written.** An agent never adds, edits or retires an entry here; it proposes one — in
  conversation, or as a drafted entry in `design/ideas/<slug>.md` — and the owner moves it in.
- A requirement is a promise the README's pitch makes — what pikuri does differently, or better,
  than the alternatives. The owner's ruler for a proposal: **allow the opposite everywhere — is
  it still pikuri?**
  "Nothing leaves the machine by default", "no agent holds all three trifecta legs" → not pikuri
  → an entry. "Every subprocess goes through the chokepoint", "nothing appended mid-conversation
  is `:system`" → broken in places, still pikuri → not an entry: an *invariant* — the rule that
  *keeps* a promise — is an `AGENTS.md` seam line, named here under *Enforced by*; a rule about
  one class is its yardoc.
- One file, here at the root; a gem's README is a reference card and gets none. A gem owns the
  rule that keeps a root promise inside its boundary, as a seam line in its own `AGENTS.md`.
- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- Shape: `## R_<slug> — <the promise in its operational form, one sentence>`, then **Status**
  (Active, or Retired <date> — see `D_<slug>`), **If violated** (the observable failure, one or two
  sentences — not the argument, which is the `D_`'s), **Enforced by** (a spec, a tripwire cited as
  `T_<slug>` — this line is that slug's home — or "review only"), **See** (the pitch passage and
  the `D_` entries behind it).
- A retired requirement stays as a tombstone. A requirement that wants a *Rejected:* section is a
  decision — move it to `decisions.md`.
- **The first entry is the ruler**: later entries are trimmed to its length, never the other way
  round.

---

## R_privacy_first — By default nothing leaves the machine; every hosted provider and every network-reaching tool is an explicit opt-in

**Status:** Active.
**If violated.** A conversation, a file, or the *name* of a denied file reaches a party the user
never chose — the one thing the README's first paragraph says cannot happen. The defaults are a
local llama.cpp server, no cloud account, no API key, no telemetry; a feature that only works
against a hosted provider breaks the posture even when nobody turns it on.
**Enforced by.** Every `bin/` defaults `llm_server` to `http://localhost:8080`; a tool that
reaches a hosted service carries a `== Privacy posture` yardoc section ({Pikuri::Tool::Search::Exa});
`T_walked_path_denylist` and `T_lsp_denied_sites` keep a denied path out of the transcript.
Otherwise review.
**See.** README "Why this exists", `D_walked_path_denylist`, `D_corpus_trust_declaration`.

## R_readable_in_an_evening — The whole of pikuri can be read end-to-end in an evening

**Status:** Active.
**If violated.** The codebase stops being the tour of an agent runtime the README promises, and a
privacy-conscious user who cannot audit it is back to trusting a vendor. Growth is by bounded
gems with a closeable threat model, never by fattening one; a layer, a plugin system or a knob
not needed for the next concrete step is a violation even when it is small.
**Enforced by.** Review only — `book/README.md`'s running order is the evening; each gem's
`design/architecture.md` is where its threat model closes.
**See.** README "Where to go next", SECURITY.md "Pikuri itself — trust it (and read it)",
`D_keep_ruby_llm`.

## R_trifecta_break — No agent that reads untrusted content also holds private data and a way to send bytes out

**Status:** Active.
**If violated.** One injection hidden in a scraped page, a `node_modules/` file or an MCP result
is enough: the fooled model has the tool to act on it. At most two of the three legs at any
node, by construction — pikuri never filters or sanitizes tool output, because filters lose to
adversarial text.
**Enforced by.** Every {Pikuri::Tool} declares `trifecta_legs` (default `ASSUMED`, the worst
case); the bundled personas hold at most two legs; {Pikuri::Trifecta.walk} reports every node
where all three meet, at boot, in every `bin/` — a smoke alarm that never blocks, and
SECURITY.md names the parents that still have the shape.
**See.** SECURITY.md "Prompt injection (the long axis)", `book/trifecta-detector.md`,
`D_egress_axis_shape`, `D_trifecta_map_orphans`, `D_no_static_poisoned_flag`.
