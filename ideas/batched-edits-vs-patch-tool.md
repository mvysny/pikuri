# Batched edits vs. a patch tool

Open half of `ideas/feedback.txt` item 2 ("edit is search-replace only").
The cheap half — `occurrence: N`, which lifts the *uniqueness* tax without
touching strictness — shipped. What's still open: does `edit` get a
**batching** sibling, an **apply-patch** sibling, or neither?

No `DECISIONS.md` entry yet on purpose: `occurrence`, batching and the
patch tool are one fork, so one `D-` entry should close all of it once this
settles. Its rejected-roads list is most of this file. (Batching and a
context-anchored patch turn out to be *one* arm with two serializations —
see arm 5.)

## What Grok actually asked for

> A unified-diff / apply-patch tool as a sibling of `edit` would cover the
> "this function is now a different shape" case without the unique-string
> dance. Keep `edit` for the one-hunk change.

Three pain cases named, and they are *not* the same problem:

- **(a) rename across a file** — `replace_all` exists and Grok saw it, so
  the real complaint is that it has no word boundary: renaming `foo` also
  hits `foo_bar`, `:foo`, `"foo"`, and the comments.
- **(b) method move** — two edits (delete here, insert there), so the body
  crosses the wire twice on top of having been read once.
- **(c) reshape a function** — one edit, old body + new body.

## The finding that undercuts the prescription

**The diff format is not cheaper on any of the three, and on (b)/(c) it is
worse.**

- Move under a diff = a removal hunk carrying the body as `-` lines plus an
  addition hunk carrying it again as `+` lines. Same 2×, plus `@@` headers
  and context.
- Reshape under a diff = context + old lines + new lines. Search-replace is
  `old + new`, i.e. strictly smaller.

So the *format* buys nothing on the cited cases. What it costs is a
hand-written patch parser plus standing pressure toward fuzz — a hunk that
fails on an off-by-one line offset earns a `--fuzz` flag within a month,
reversing the position `edit.rb` logs explicitly ("opencode runs a
9-replacer cascade despite saying *must match exactly*; pi stays strict,
and so do we").

**Correction, after looking at V4A** (see prior art): the fuzz half of that
indictment lands on *unified* diff only. V4A has no line numbers, so a hunk
fails when its context anchor doesn't match — the same failure mode as
`old_string`, and no fuzzier. The parser cost stands; the fuzz-pressure
cost does not, and this note should not keep using it against arm 5.

There is also a security property in the way: `old_string` doubles as an
**implicit read-check** — the model cannot supply bytes it hasn't seen.
Line-numbered hunks pin to less content; fuzzy ones pin to almost none.

## What Grok was right about, without naming it

The tax was never diff-vs-search-replace. It was **uniqueness**: a diff
hunk is disambiguated by line number, `old_string` by *being unique*, which
in a repetitive file forces a much bigger anchor than three lines of
context would. `edit.rb`'s own four near-identical `p.required_string`
blocks are the worked example.

`occurrence: N` answers exactly that, and is fail-safe: a stale index fails
the call rather than editing the wrong text, because `old_string` still has
to match byte-for-byte.

**So the open question is narrower than the original feedback:** with the
uniqueness tax paid, is there residual pain worth a second tool?

## Arms still on the table

### 1. Nothing more

`occurrence` + `replace_all` + strictness may already cover it. Cheapest,
and consistent with "no abstraction just in case". Costs: (a) rename still
has no word boundary; (b) move still burns two calls and two confirmations.

### 2. Batched edits — one call, a list of hunks, atomic

Reuses the strict matcher verbatim: no new match semantics, no line
numbers, no fuzz. One read-before-edit gate check, one `WriteGate` diff for
the whole batch, all-or-nothing on failure. This is what "sibling of `edit`"
is really reaching for once the format is stripped off, and it is the only
arm that improves (b).

Open sub-questions:

- **Naming.** The convention says a universal verb goes bare and a prefix
  marks a *family sharing one backing resource*. `multi_edit` is neither.
  Options: a second tool with an awkward name; an optional `edits: [...]`
  array on `edit` (conflicts with the required `old_string`/`new_string`);
  or make `edit` array-shaped from the start (breaking, and it taxes the
  overwhelmingly common one-hunk call).
- **Failure reporting.** Hunk 3 of 5 not found → the observation has to say
  *which* and that nothing was written, or the model retries blind.
- **Does it actually save a turn?** Parallel tool calls in one message
  already exist (Grok's own first nit praises them). If the model can emit
  three `edit` calls in one message today, batching saves confirmations and
  atomicity, not round-trips. **Worth measuring before building** — and see
  the prior-art section: Claude Code shipped this arm and later removed it.

### 3. Word-boundary `replace_all`

Answers (a) directly. Cost: regex escaping inside JSON is a footgun, and
"boundary" is language-specific (Ruby `foo?`, `foo!`, `@foo`, `:foo`).

Note "just use `sed`" is *not* the clean fallback: bash escapes both the
read-before-edit gate and the `ReadOnly` gate
(`pikuri-code/bin/pikuri-code:324` — plan mode covers Write/Edit, not bash).
Routing renames through bash routes them around the posture.

### 4. Line-range replace

The only arm that actually drops payload — no `old_string` at all, and
`Read` already emits `cat -n` numbering so the anchors are free. Costs:
staleness (`edit.rb` deliberately keeps the path marked read after a write,
so numbers drift silently), and it forfeits the implicit read-check — a
hallucinated range silently nukes real code. A `expect_first:` /
`expect_last:` two-line checksum would restore the check, at the price of a
fourth concept.

### 5. apply_patch / unified diff

Grok's literal ask, and the arm with real prior art behind it (Codex CLI —
see below). Two very different things hide under one name:

- **Unified diff** — `@@ -145,7 +145,9 @@` is line *arithmetic*, which small
  models are bad at in the way they're bad at arithmetic generally. Don't
  ship this one.
- **V4A / context-anchored envelope** — no line numbers, anchors on
  surrounding code. This is arm 2 with a different *serialization*: same
  anchors, same strict matching, same multi-hunk atomicity, text blob
  instead of a JSON array.

**So "batch vs. patch" is a false dichotomy.** Strip the syntax off a
context-anchored patch and it *is* batching. The real question is which
serialization a small local model emits more reliably — see the two
arguments under "Arguments to weigh either way", which point opposite ways.

## Prior art: the two harnesses disagree

### Anthropic — shipped batched edits, then removed them

Checked against the installed binary (`claude` 2.1.233), not memory. Its
live edit surface is three tools: `Edit` (`file_path`, `old_string`,
`new_string`, `replace_all`), `Write` (full overwrite), `NotebookEdit`
(`.ipynb` cells). No patch tool — `ApplyPatch` / `apply_patch` are zero
hits in any form.

`MultiEdit` appears 12 times, but never as a tool definition: in
permission-rule help text (`Edit/Write/MultiEdit deny rule`) so old
deny-rules keep matching, in two tool-name enum lists, and in a UI verb
map beside the dead legacy names `FileReadTool` / `FileWriteTool` /
`FileEditTool` / `GlobTool`. There is no `edits` array parameter anywhere.
So it was a real tool that got **removed**, leaving compat scaffolding.

Reads as evidence for arm 1: the harness with the most usage data shipped
batching, then dropped it, while keeping strict single-hunk `Edit` *and*
parallel tool calls. That matches arm 2's own open sub-question — that
batching mostly buys atomicity, not round-trips.

Caveats before leaning on it:

- Removal is inferred from residue plus enum position. The binary doesn't
  say *why* — redundancy with parallel calls, the genuinely nasty
  partial-batch failure states, or prompt-cache economics that don't apply
  here.
- A harness aimed at frontier models is exactly where local-first diverges.
  A tool dropped because a big model didn't need it says little about a 7B
  one — the same asymmetry as the in-distribution argument below, pointing
  the same way.

Also: Claude Code's `Edit` has no `occurrence` equivalent — uniqueness or
`replace_all`, nothing else. So pikuri is now *ahead* on that axis rather
than catching up, and no one else's design can be cited as validation for
it.

### OpenAI — ships patch as *the* edit tool

Codex CLI's primary edit mechanism is `apply_patch`, now also a first-class
API tool. Format is **V4A**: `*** Begin Patch` / `*** Update File:` /
`@@ <anchor>` / `-` / `+` / `*** End Patch`, with add, delete and rename in
one envelope. Deliberately **context-anchored** — it locates the region by
matching surrounding code rather than trusting line numbers.

So "nobody ships a patch tool" is false, and the earlier read of this note
was too Anthropic-centric: one major harness bets the whole edit surface on
patch. That is the strongest evidence arm 5 has.

**But the load-bearing detail cuts the other way for us.** OpenAI describes
V4A as a grammar their models were *specifically trained to produce*. If
generic diff exposure sufficed, they'd have used unified diff — by orders
of magnitude the best-represented format in any corpus. Instead they
designed the line arithmetic out *and* trained on the replacement. Two
independent admissions that "LLMs are heavily trained on diffs" doesn't
survive contact with *authoring* one.

The honest form is narrower and worse for us: **a patch format works when
the model was trained on that format.** Shipping V4A to a local Qwen buys
the parser without the training. Before weighting this arm, check whether
the default local model was tuned on a V4A-like grammar — unknown today,
and knowable.

## Arguments to weigh either way

- **In-distribution — but for a *specific* format, not diffs in general.**
  See the V4A finding above: this argues for patch *on OpenAI models* and
  says little about ours until someone checks what the local default was
  trained on.
- **Constrained decoding may invert the local argument.** If the llama.cpp
  endpoint does schema-constrained tool calls (llama-server supports it),
  a JSON edits-array is *grammar-enforced* and cannot come out malformed,
  while a free-text patch blob has no grammar and fails at the parser
  instead. Under that mode JSON is the safe format precisely because it is
  the constrained one. **Check which mode the default wiring uses — it
  flips the sign of this whole bullet.**
- **…though a text blob has fewer escape sites.** One JSON string field
  instead of an array of objects with 2N escaped multi-line strings. This
  is the best argument for the patch *serialization*, and it is not the
  "trained on diffs" one. Largely moot if decoding is constrained.
- **The readable-diff benefit is already captured on the output side.**
  `WriteGate` computes a unified diff from old/new bytes and
  `Confirmer::Terminal` renders it (`confirmer/terminal.rb:87`), so the
  human sees a diff regardless of what the model typed.

## The thing that actually decides arm 1

Arm 1's entire defense is "N single edits cost one turn, because they go
out in parallel." **That defense is Anthropic-conditional.** If the local
default emits one tool call per turn, N edits become N sequential
round-trips, each re-processing the prompt — and on local hardware prompt
processing is the expensive part, not generation.

Which means the Anthropic datum is a *package*: strict single-hunk edit
**plus** reliable parallel calls. "Anthropic found a simple edit tool to be
enough" is true but incomplete — enough *given the other half*. pikuri's
local default may only get half the package. Exactly the CLAUDE.md warning
about importing a frontier-shaped conclusion.

And the tension that makes this hard, worth stating plainly:

> **Local is simultaneously where batching would help most (no parallel
> calls) and where adoption is least likely (a small model reaches for the
> simplest tool).**

A batch or patch tool that ships and never gets called is worse than
nothing — it costs schema tokens on every single turn.

## Next steps, cheapest first

1. **Does the default local model emit parallel tool calls?** One session
   answers it. If no, arm 1 loses its justification here and the fork
   genuinely opens. If yes, this whole note probably closes.
2. **Would it use a batch tool if offered?** Give it a JSON edits-array —
   an afternoon, versus a V4A parser plus its error reporting — and see
   whether it ever reaches for it unprompted. Tests the adoption worry
   directly.
3. **Re-take Grok's feedback with `occurrence` available.** The original
   complaint was written without it, so (b) the method move and the
   multi-hunk turn need re-measuring before anything is built on them.
4. Only then, if 1–3 still show pain: bench the three serializations
   (`edit` calls / JSON array / anchored blob) on real restructures from
   this repo and count valid-and-applies-cleanly rates.

## Sources

- <https://github.com/openai/codex/blob/main/codex-rs/apply-patch/apply_patch_tool_instructions.md>
- <https://developers.openai.com/api/docs/guides/tools-apply-patch>
- <https://codex.danielvaughan.com/2026/03/31/codex-cli-apply-patch-v4a-diff-format/>
- Claude Code: read out of the installed binary, `claude` 2.1.233.
