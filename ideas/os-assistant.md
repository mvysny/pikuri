# OS/Linux Assistant

Status: **shipped** as the `pikuri-os` gem + `bin/pikuri-os-assistant`
(built; the local-model-fit question is provisionally settled — initial
testing confirms the recommended 35B-A3B model can diagnose a real
issue, see below — so what's left is the deferred work list). The design
brainstormed in this note is now implemented and documented — so this
note keeps only the *origin map*, the questions still open to
validation, and the explicitly deferred work. For the shipped design and
its rationale, read:

- **Guide [chapter 7](../book/07-os-assistant.md)** — the
  narrative walkthrough. Part 1: the severed-network sandbox, the
  read-before-edit fence, confirmed mutations, the read-only
  command approver, the file-index pair, `MACHINE.md`, boot grounding,
  and why egress is the trifecta leg this agent removes. Part 2 ("the
  third leg returns"): reattaching the network via the quarantined
  `RESEARCHER` sub-agent + the confirmed task prompt + the two
  independent network boundaries.
- **YARD headers** — {Pikuri::Os::Extension} (one-call wiring +
  confirmation policy), {Pikuri::Os::FileindexSearch} /
  {Pikuri::Os::FileindexRead} / {Pikuri::Os::LocalSearch} (the
  search → read-full pair), {Pikuri::Os::MachineMemory} (`MACHINE.md`),
  {Pikuri::Os::SystemInfo} (grounding),
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet} (the kernel-severed
  network) and {Pikuri::Code::Bash::ReadOnlyCommandApprover} +
  `Pikuri::Code::Bash::GIT_HARDENING` (the command approver + git arm).
- **[`../CLAUDE.md`](../CLAUDE.md)** — the `pikuri-os` gem entry and the
  Sandbox / Confirmer / Workspace seam invariants.

## Related

- [`assistant.md`](assistant.md) — the federation. This agent is the
  federation's `@private`/`@os` member, shipped standalone: one agent,
  no inter-agent routing. If the federation lands, it becomes a sibling.
- [`trifecta-detector.md`](trifecta-detector.md) — the three legs. This
  design breaks the trifecta by **enforced removal of the egress leg**,
  not by trusting its inputs.

## Settled by initial testing

- **A 35B-A3B model knows Linux deeply enough — the recommended
  default.** Target model: `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` — MoE,
  ~3 B active params per token. Factual recall scales with *total*
  params (35 B — ample for FHS / man pages / apt); the open worry was
  that multi-step *reasoning* depth scales with the ~3 B active budget,
  so deep causal diagnosis ("service failed → log says Y → therefore Z")
  might be shallow. Initial testing confirms it isn't: the model carries
  a real diagnosis end to end, not just flag recall. The design hedge
  holds up in practice — the agent iterates with tools rather than
  one-shotting, and verifies recall by *reading* (a man-page `read`
  beats a remembered flag). So this stays the **recommended** model; if
  further experience shows the ~3 B active reasoning budget falling short
  on deeper causal chains, we'll revisit.

  **Why MoE, not a bigger dense model:** a dense model needs its full
  parameter count resident in fast memory *and* run through the matmul
  on every token, so matching a MoE's quality densely means the whole
  thing must fit in VRAM on a strong discrete GPU — expensive, and
  against the no-cloud, no-strong-GPU-required posture this gem targets.
  A MoE activates only ~3-4 B params worth of experts per token, so the
  *inactive* experts can sit in ordinary system RAM while only the
  active path needs to be fast — the iGPU/CPU-RAM machine this project
  is shooting for. So "bigger total params, same 3-4 B active" is the
  only upgrade axis that keeps that target machine viable; a bigger
  dense model would instead demand a stronger GPU.

  **Bigger-box escalation, if not laptop-bound:** the ~3 B active-param
  budget is an inference-cost floor, not a total-param ceiling — a user
  running from an LLM-dedicated machine (still iGPU/CPU-RAM-class, just
  more RAM) can trade up in *total* params while keeping the same active
  budget and roughly the same tokens/sec. `Qwen/Qwen3-Coder-Next`
  (80B-A3B, ~3 B active, Feb 2026) is the candidate: same inference-cost
  class as the 35B default, 80B total params, and — unlike the
  general-purpose 35B model — agentically trained on long-horizon tool
  use and *recovery from execution failures*, which speaks more directly
  to the causal-diagnosis worry above. Needs ~50GB combined VRAM+RAM at
  Q4_K_M — comfortably a CPU-RAM box (e.g. 64GB system RAM) with little
  or no discrete GPU, not a jump to data-center hardware — so it's
  explicitly the dedicated-machine tier, not the laptop default. Also
  worth an empirical try at the *same* cost tier as the 35B default:
  `GLM-4.7-Flash` (30B-A3B) — same ~3 B active budget, benchmarks lower
  on general reasoning but ahead on agentic tool-use (τ²-Bench 79.5% vs.
  Qwen3.6-35B-A3B), which is most of what this assistant actually does.
  Neither swap is validated here — both ride the same "settle by using
  it" caveat, though the 35B default itself is now provisionally
  confirmed (above).

## Open questions (empirical — settle by using it)

- **Does keyword recall suffice, or is semantic search needed?**
  `fileindex_search` is only as good as `localsearch`'s lexical match.
  When it whiffs, the cause is one of *three*, and they have different
  answers — only the third is a genuine "nothing we can do":

  1. **Content not indexed** — a format `localsearch`'s extractors
     don't full-text, or the index is stale / scoped out. (In practice
     `localsearch`'s full-text coverage is uneven: some hosts full-text
     PDFs but skip `.odt`/`.md`/`.py`, indexing only their metadata.)
     The fix is a *better lexical indexer* — the one place `recoll`
     earns a mention (comparison below). Not a semantic problem.
  2. **Phrasing / synonym miss** — the doc is indexed but the user's
     words differ ("the doc about our refund policy" vs. a file that
     says "returns & cancellations"). This is **already ours and
     already in posture**: we already ship the RAG/agentic search — the
     agent reformulates (synonyms, narrower terms) and, because
     `pikuri-os` runs `FullFsNoNet` with full-disk *read* and wires
     `grep`/`glob`/`bash`, falls back to grepping likely directories
     when the index misses. No sub-agent wrapper needed — that framing
     is a technicality; the iteration is the substance.
     `localsearch`'s index is also already stemmed ("mouse"↔"mice",
     see {Pikuri::Os::LocalSearch}), so inflectional variants come free;
     the residue is true synonymy, which query iteration handles better
     than any lexical index would.
  3. **Genuine semantic / conceptual gap** — cross-lingual, or "that
     thing about being frugal" → an unlabelled budget spreadsheet. The
     only cause embeddings actually address, and the rarest on a
     personal machine. We decline it deliberately — **not** because
     `pikuri-vectordb` "would re-index what `localsearch` already holds"
     (that conflates *indexing cost* with retrieval *modality*; the
     point of vectordb would be a **different modality** over the same
     bytes), but because owning a live `$HOME` embedding index means
     reinventing the freshness daemon `localsearch` hands us for free
     (the `Watcher`), plus embedding VRAM and a large new surface —
     straight against the offline, "small enough to audit" posture.
     Semantic *re-ranking* of `localsearch` hits doesn't rescue this
     either: it fixes precision, not recall — a doc the keyword miss
     kept out of the candidate set can't be re-ranked back in.

  **Actionable for pikuri.** (2) is the primary answer and needs no new
  infra — at most a prompt nudge to reformulate / grep on a weak hit.
  (1) is the only lever that points *outward*: recommend the user
  install `recoll`. But that recommendation only helps pikuri if
  `fileindex_search` can actually *query* recoll — today it speaks
  `localsearch` only, so "just install recoll" closes nothing on its
  own. The real deferred item is therefore a `Recoll` backend
  (`recollq`) parallel to {Pikuri::Os::LocalSearch}, chosen via the same
  `available?` degrade-gracefully probe (see "Deferred" below). (3)
  stays declined.

### `recoll` vs `localsearch` — is recoll actually better?

Qualified yes — but for *coverage and portability*, not for the
semantic gap. Both are **lexical** (stemmed keyword) indexers; neither
does embeddings, so neither closes cause (3).

| | `localsearch` (tracker3) | `recoll` |
|---|---|---|
| Backend | GNOME knowledge graph (SPARQL) | Xapian |
| Setup | **zero** — already running on GNOME | install + build index + pick dirs |
| Freshness | continuous daemon (GNOME-managed) | cron *or* inotify daemon (`recollindex -m`) |
| Formats | built-in extractors; full-text coverage uneven in practice | broader, via external filter helpers |
| Query | one snippet/file, simple | phrase / proximity / wildcard / field filters |
| Desktop tie-in | **GNOME-only** | DE-independent (KDE, Xfce, headless) |
| Stemming | yes | yes (language switchable at query time) |
| Headless CLI | `localsearch search` / `info` | `recollq` |

Reading the table: on a GNOME box `localsearch` is the right default
*because* it's already indexing, always fresh, and zero-config — "use
what the OS offers." recoll earns the recommendation in two concrete
situations, both cause-(1) fixes: **(a) non-GNOME hosts**, where
`localsearch` is absent and the fileindex tools currently degrade to
*omitted* entirely — a `recollq` backend would restore an index there;
and **(b) coverage gaps**, where the user keeps hitting documents
`localsearch` doesn't full-text. What recoll does *not* buy is a fix
for a fuzzy conceptual ask — that's cause (2)/(3): agent iteration or
declined, respectively.

Sources: [recoll.org](https://www.recoll.org/),
[Recoll (Wikipedia)](https://en.wikipedia.org/wiki/Recoll),
[Tracker SupportedFormats](https://wiki.gnome.org/Projects/Tracker/SupportedFormats).

## Deferred / not yet built

**Confirmation-fatigue work beyond the shipped read-only command approver**
(the sequencer/pipe composition and the `git` arm are shipped — see
{Pikuri::Code::Bash::ReadOnlyCommandApprover}). The governing invariant
for everything below: **AI may *translate* a command ("this deletes
`~/tmp` recursively"), but code and the human *decide* — never an AI
✓/⚠ verdict.** An AI approver is talked into "yes" by the same laundered
content that fooled the agent; a usually-silent AI warner is worse, as
it trains the user to read "no warning" as "safe" and goes quiet exactly
when an injection is crafted to look benign.

- **`Write`/`Edit` full read + confirmed writes** — **shipped**: full
  read to match bash (`denylist: []`), and every *writable* write
  confirmed with a diff, unwritable writes short-circuited to "sudo it
  yourself" (`confirm_all_writes`). Narrative in the guide's ch7
  (Workspace + Confirmer seam sections); mechanism in
  {Pikuri::Workspace::WriteGate}. Deferred residue (allowlist-safe
  auto-allow) in §"File confirmations: allowlist-safe auto-allow" below.
- **The rest of the confirmer-gate fatigue work** — session-sticky
  grants, subcommand-aware read rules, batching, and the AI translation
  aid — is collected in [`bash-confirmer.md`](bash-confirmer.md).

**A `Recoll` file-index backend** (`recollq`) parallel to
{Pikuri::Os::LocalSearch}, selected via the same `available?`
degrade-gracefully probe. The lever behind cause (1) in the open
question above: `localsearch` is GNOME-only, so on KDE/Xfce/headless
hosts the fileindex pair degrades to *omitted* entirely — a recoll
backend restores an index there, and also covers formats `localsearch`
doesn't full-text. Deferred, not rejected: it's the only path that
makes "recommend the user install recoll" actually reach the LLM's
tools, but no non-GNOME host has driven the need yet. Both backends
front the same `fileindex_search` / `fileindex_read` seam, so it's an
added `available?`-picked alternative, not a rewrite.

## File confirmations: allowlist-safe auto-allow

`pikuri-os` confirms **every** writable `write`/`edit` with a diff
(`confirm_all_writes`), because writes are rare for a diagnosis agent, so
there's little fatigue to cut and no "sensitive path" list to maintain —
see book ch7 and {Pikuri::Workspace::WriteGate}. The considered-and-punted
generalization: an **allowlist of auto-allowed (safe) write paths**,
deny-by-default = confirm. It's the inverse of a sensitive-path denylist
(and the winning side of the enumeration game, like `READ_ONLY_BINARIES`),
for a *hypothetical frequent-writing full-disk agent* that would want some
writes — a scratch dir, `/tmp` — to skip the prompt. No such agent ships,
so building the allowlist plumbing now would be speculative. Revisit when
one exists; `confirm_all_writes` is `[]`-safe-paths as a special case.

**Larger pieces:**

- **GUI-config *application*, app launching, package *installation*.**
  The agent advises (prints the exact `gsettings` / `apt` command) but
  doesn't run these: installs need root + egress (barred by the severed
  network anyway), and the rest are post-v1.
