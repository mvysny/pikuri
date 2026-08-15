# Batched edits vs. a patch tool

Open half of `ideas/feedback.txt` item 2 ("edit is search-replace only").
The cheap half — `occurrence: N`, which lifts the *uniqueness* tax without
touching strictness — shipped. What's still open: does `edit` get a
**batching** sibling, an **apply-patch** sibling, or neither?

No `DECISIONS.md` entry yet on purpose: `occurrence`, batching and the
patch tool are one fork with three arms, so one `D-` entry should close
all of it once this settles. Its rejected-roads list is most of this file.

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
  atomicity, not round-trips. **Worth measuring before building.**

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

Grok's literal ask. Nothing the others don't give, plus a parser and fuzz
pressure. Note the OpenAI-style context-anchored envelope is essentially
"several search-replaces in one wrapper with a stranger syntax" — i.e.
arm 2 with worse ergonomics. **If the value is batching, ship batching.**

## Arguments to weigh either way

- **In-distribution.** Diffs are heavily trained-on, so a frontier model may
  emit a restructure more reliably as a patch than as a big
  `old_string`/`new_string` pair. Empirical; pikuri can't settle it without
  a bench.
- **…but local-first cuts the other way.** pikuri defaults to llama.cpp, and
  a small local model emits a well-formed `@@` envelope far less reliably
  than two strings in a JSON object. This is the pikuri-specific reason the
  general "models love diffs" argument doesn't transfer.
- **The readable-diff benefit is already captured on the output side.**
  `WriteGate` computes a unified diff from old/new bytes and
  `Confirmer::Terminal` renders it (`confirmer/terminal.rb:87`), so the
  human sees a diff regardless of what the model typed.

## Next step

Cheapest experiment first: run a real session against this repo with
`occurrence` available and see whether (b) the method move and the
multi-hunk turn still feel expensive. Grok's original complaint was written
without `occurrence`, so the feedback needs re-taking before building
anything on it.
