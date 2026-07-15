# OS/Linux Assistant

Status: **shipped** as the `pikuri-os` gem + `bin/pikuri-os`
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
  {Pikuri::Os::FileindexRead} / {Pikuri::Os::LocalSearch} /
  {Pikuri::Os::Recoll} (the search → read-full pair over a swappable
  file-index backend), {Pikuri::Os::MachineMemory} (`MACHINE.md`),
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
- **`bin/pikuri-computer`** — app integrations (thunderbird, …) compose *on
  top* of pikuri-os as a **demo binary** (thunderbird as a dev-dep; not a gem,
  not a merge); pikuri-os stays substrate-only and keeps its no-egress posture
  unchanged. Landed + live-verified — see CLAUDE.md's pikuri-os entry + the
  "grow by bounded gems" convention, and book ch7 Part 3.

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

  1. **Content not indexed / not reachable** — confirmed the dominant
     real limit, and it's *structural*, not a quality problem.
     `localsearch` **mime-gates** extraction: `text/plain` / Markdown /
     PDF / office get full body text, but **source code is
     filename-only** (`text/x-java` etc. store zero content — a 90 KB
     `.java` indexes 0 chars), and any tree containing `.git` is skipped
     wholesale. On top of that it has **no directory scoping** — it
     ranks globally over the whole `$HOME` index, so a small target
     corpus is buried below the default result limit even when fully
     indexed. So on a dev box the code is invisible and the target
     folder is drowned. The fix is grep (cause 2 already wires it) or a
     *different indexer* (`recoll`; comparison below) — not embeddings.
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
  infra — at most a prompt nudge to reformulate / grep on a weak hit,
  *especially* for code and git repos, which `fileindex_search` cannot
  see at all (cause 1). (1)'s only outward lever is `recoll`, but the
  measurement below shows it's a thin slice: on content `localsearch`
  indexes, recoll's recall is *identical*, and the cases where recoll
  wins (source, `.git`, scoped search) are already covered by the wired
  grep. The `Recoll` (`recollq`) backend parallel to
  {Pikuri::Os::LocalSearch}, `available?`-probed, is now **shipped and
  wired** (see "Deferred / not yet built" below for its shape); it earns
  its keep only for *non-GNOME hosts* or *large non-code corpora* outside
  GNOME's indexed set. (3) stays declined.

### `recoll` vs `localsearch` — is recoll actually better?

Qualified yes — but for *coverage and scoping*, **not for search
quality** and not for the semantic gap. Both are **lexical** (stemmed
keyword) indexers; neither does embeddings, so neither closes cause (3).

**Measured (2026-07; `localsearch` vs `recoll` vs `rg` over a 59-file
pikuri Markdown corpus and `~/flowsrc`, ~825 Java files; harness +
numbers were a throwaway bench).** On content `localsearch` actually
indexes (the Markdown), `localsearch` and `recoll` are **equivalent** —
both reach ~100% recall against a ripgrep oracle across distinctive,
common, morphological, and multi-word/concept queries, returning
near-identical file sets; `localsearch` stems and does stemmed-AND
multiword just like `recoll`. recoll is *not* a better engine here. The
tempting "recoll wins 100%→single-digits" on the Java corpus was an
**artifact** — `localsearch` doesn't content-index source at all, so
those `localsearch` "hits" were *filename* matches; the fair corpus is
prose. `localsearch`'s real limits are structural, not quality:
**(a) no source code** (mime-gated; `.java` etc. filename-only, `.git`
trees skipped); **(b) no directory scoping** — global ranking over the
whole `$HOME` index, so a small target corpus is buried below the
default limit (everything is *in* the index — ~100% at a high limit —
but the LLM, capped at ten hits, sees none of it for a common word).

| | `localsearch` (tracker3) | `recoll` |
|---|---|---|
| Backend | GNOME knowledge graph (SPARQL) | Xapian |
| Setup | **zero** — already running on GNOME | install + build index + pick dirs |
| Freshness | continuous daemon (GNOME-managed) | cron *or* inotify daemon (`recollindex -m`) |
| Recall on indexed prose | ~100% (**= recoll**, measured) | ~100% |
| Source code | **filename-only** (mime-gated); `.git` trees skipped | full-text (all text mimes) |
| Directory scope | **none** — global ranking only | `dir:` filter + per-config `topdirs` |
| Query ops | stemmed AND / OR | + phrase / proximity / wildcard / field filters |
| Desktop tie-in | **GNOME-only** | DE-independent (KDE, Xfce, headless) |
| Headless CLI | `localsearch search` / `info` | `recollq` |

Reading the table: on a GNOME box `localsearch` is the right default
for whole-`$HOME` *document* discovery — already indexing, always
fresh, zero-config, and (measured) as good as recoll at it. recoll only
pulls ahead where `localsearch` is structurally blind — **source trees,
`.git` repos, scoped in-folder search, non-GNOME hosts** — and those
cases are *already* covered by the wired `grep`/`glob` (scoped, exact,
zero-setup, blind to none of it). So recoll's marginal value over the
shipped `localsearch` + grep pairing is a thin slice: fast indexed,
stemmed, ranked search over *large non-code corpora* outside GNOME's
indexed set. What recoll does *not* buy, anywhere, is a fix for a fuzzy
conceptual ask — that's cause (2)/(3): agent iteration or declined.

Sources: local measurement (above);
[recoll.org](https://www.recoll.org/),
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

**A `Recoll` file-index backend** — **shipped** as
{Pikuri::Os::Recoll}, a stateless module parallel to
{Pikuri::Os::LocalSearch} behind the same `#search` / `#read_text` /
`#available?` / `#limitations` / `#label` + `CommandError` duck type.
{Pikuri::Os::Extension} wires the `fileindex_*` pair on the first
backend in `FILE_INDEX_BACKENDS` whose `available?` is true —
`localsearch` first (GNOME, zero-setup), then `recoll` (but only with a
*built* index: recoll's `available?` requires `<confdir>/xapiandb`, so
an installed-but-unindexed recoll doesn't win selection and then error
on every query). The measurement in the open question above bounds the
payoff: on content `localsearch` indexes, recoll's recall is
*identical*, and recoll's genuine wins (source code, `.git` trees,
scoped in-folder search) are already served by the wired grep — so its
live niche is the **non-GNOME host** (no `localsearch` at all) *or* a
large non-code corpus wanting fast indexed ranking grep would scan too
slowly. That thinness is why it's a *fallback*, not a co-equal: the
selection order encodes "localsearch if you have it." Two things worth
noting on the shape: recoll's blind spot is the **inverse** of
localsearch's — it indexes exactly the configured `topdirs` (source
code included) rather than all of `$HOME` minus source, so its
`limitations` is a *method* reading the live `topdirs` (parsed from
`$RECOLL_CONFDIR`/`~/.recoll`), not a constant; and pikuri never
*builds* or *configures* a recoll index — it only queries an index the
user already maintains.

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
