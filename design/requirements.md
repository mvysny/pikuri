# Requirements

What must hold — of pikuri's behaviour, not of the environment it runs in. One entry per
requirement. A requirement *states*; it never argues: the fork behind it, if there is one, is a
`D_` entry it cites.

- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- **An entry is a property the README promises**, or the whole-tree rule that keeps it — *every*,
  *never*, *all*, code not yet written included. A rule about internals no user would care about
  is a tripwired seam line in `AGENTS.md` with no slug; a rule about one class is its yardoc.
- Shape: `## R_<slug> — <the requirement, one sentence>`, then **Status** (Active, or
  Retired <date> — see `D_<slug>`), **Why** (one paragraph), **Enforced by** (a spec, a tripwire
  cited as `T_<slug>` — this line is that slug's home — or "review only"), **See** (the yardoc
  and the `D_` entries behind it).
- A retired requirement stays as a tombstone. A requirement that wants a *Rejected:* section is a
  decision — move it to `decisions.md`.
- **The first entry is the ruler**: later entries are trimmed to its length, never the other way
  round.

---

## R_privacy_first — Nothing leaves the machine that the user did not ask to leave

**Status:** Active.
**Why.** The README's promise is that a conversation never leaves your computer unless the model
itself calls a network tool, and it is the whole reason to pick pikuri over a hosted agent. Two
halves keep it. A default that reaches a hosted provider, or a feature that works only against
one, breaks it even when nobody turns it on — cloud is a transport the host passes in, never a
fallback pikuri picks. And a path pikuri *walked* to on its own — a listing, a glob, a grep hit,
an LSP location — passes the denylist before it is reported, or a denied `.env` leaks its name,
and for grep a line of its content, into a transcript the user never asked to produce.
**Enforced by.** `T_walked_path_denylist`, `T_lsp_denied_sites`; the transport half is review only
— a default is a one-line change no grep can distinguish from a legitimate host wiring.
**See.** {Pikuri::Workspace::Filesystem#denied?}, {Pikuri::Agent::ChatTransport},
`D_walked_path_denylist`.

## R_trifecta_break — The trifecta is broken by wiring, and pikuri never sanitizes tool output

**Status:** Active.
**Why.** SECURITY.md sells the trifecta-break as the headline defense: an agent holding private
data, attacker-influenceable content and an egress path is the live wire, so pikuri keeps a
persona to at most two of the three legs and quarantines the rest behind the sub-agent boundary.
That only stays true if the boundary is *structural* — filtering model-facing bytes for
injections is a guess pikuri refuses to sell as a guarantee. So every tool declares its
`trifecta_legs` at construction, where the workspace, sandbox and confirmer that decide a leg are
already in hand; an undeclared tool defaults to `ASSUMED`, presumed hostile on both axes, so
forgetting fails loud rather than quiet. {Pikuri::Trifecta} only *reports* — it never blocks, and
a clean map is never an assurance.
**Enforced by.** `TrifectaLegs::ASSUMED` as the default; `SubAgent::Extension#configure` raises on
a persona naming a tool no pool holds; `Trifecta.walk` is a pure function of the tree, spec'd from
hand-built nodes.
**See.** {Pikuri::Trifecta}, {Pikuri::Tool}, `SECURITY.md`, `D_lsp_trifecta_legs`.

## R_readable_in_an_evening — The whole codebase stays small enough to read end-to-end in an evening

**Status:** Active.
**Why.** The README invites a reader to do exactly that, and the book's teaching value rests on
it: pikuri is meant to be audited, not trusted. The rule that keeps it is negative — no layer, no
plugin system, no abstraction and no knob that the next concrete step does not need. Growth goes
sideways into a new bounded gem with its own threat model, never into another indirection in an
existing one, because a reader can skip a gem they do not use but cannot skip a layer.
**Enforced by.** Review only — this is the one requirement no grep can hold, which is why it is
stated here rather than left as taste.
**See.** `AGENTS.md` "Working on this codebase", `D_keep_ruby_llm`.
