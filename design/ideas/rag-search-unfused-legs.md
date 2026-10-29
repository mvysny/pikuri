# `rag_search`: show both legs, don't fuse them

Status: **half shipped.** The recall fix shipped 2026-10-29 as tuned fusion, not as this
idea's union — `design/decisions.md` `D_rrf_tuning`. What remains open is provenance labels on
each hit, and whether the union's better MRR is worth having. Origin: the courts repo's embedder eval, 2026-10-29
(`../courts/design/ideas/searchable-laws-in-pikuri.md`, *Embedder eval*; script
`../courts/bin/embedder-eval`). The owner's proposal: fusion has to merge two unrelated
algorithms mechanically and can't do it well, so hand the model both result lists and let it
pick.

## The finding

Reciprocal-rank fusion already sidesteps the incomparable scores (cosine vs bm25) — it keeps
ranks only, see `Rag::Tools::Search`'s *Why fuse by rank*. Its flaw is the other half of the
design: `RRF_K = 60` is chosen so "a confident rank-1 hit in one leg does not out-vote
agreement between both". With both legs `CANDIDATE_K` = 50 deep, *any* chunk both legs list
somewhere in their top ~60 outscores a chunk only one leg ranks #1 (1/61 + nothing < 1/(60+a) +
1/(60+b)). When the legs agree on the wrong chunks, the right one sinks.

On the courts corpus (4 Finnish acts, 165 chunks, 28 paraphrased questions, bge-m3,
bge-reranker-v2-m3 over the fused top 20), "gold" = the answering section is among the hits:

| What the model gets | Hits | Gold present |
|---|---|---|
| fused top 5 (today, no reranker) | 5 | 22/28 |
| fused, reranked, top 5 (today, reranker) | 5 | 24/28 |
| fused top 10 | 10 | 24/28 |
| vector top 3 ∪ keyword top 3 | ≤ 6 | 25/28 |
| vector top 5 ∪ keyword top 5 | ≤ 10 | 26/28 |

Three sections the vector leg ranked #1 came out of fusion at 6, 22 and 31; the last two were
past the reranker's depth, so it never saw them. The reranker cost 22 s/question on CPU.

## Proposal

`rag_search` runs both legs as today, then returns each leg's top few, deduplicated by chunk
id, every hit labelled with the leg(s) and rank that found it:

```
Found 6 matches (by meaning: 3, by keyword: 3, both: 1).

[1] tsl.md lines 812-840 — meaning #1, keyword #4
...
[2] tsl.md lines 1210-1248 — meaning #2
...
[3] ytl.md lines 300-331 — keyword #1
...
```

The model reads the snippets anyway and is a far larger relevance judge than RRF or a
cross-encoder; the labels tell it *why* each hit is there. `fuse` and `RRF_K` go; the
*Why fuse by rank* section becomes the decision record of why not. `vectordb_search` (one leg)
is untouched.

Side effects: the one-`score=`-label-over-three-scales caveat (`Rag::Tools::Search` header)
disappears, since per-leg ranks are honest where that number isn't; and `CANDIDATE_K` = 50 per
leg no longer serves anything, so `rag_search` gets its own per-leg constant instead of
aliasing `vectordb_search`'s `FINAL_K` / `CANDIDATE_K`.

## It is still a fusion — two changes, not one

"Each leg's top 3, interleaved, deduped" is a merge with a fixed per-leg quota — effectively
RRF with a tiny `k` and a shallow depth. The proposal bundles:

- **(a) a different merge** — all of the measured recall gain is here;
- **(b) provenance labels** — the gain is untested (`Q_model_uses_labels`).

So the decision record is not "fusion can't work" but "RRF at depth 50 rewards agreement deep
in both lists; a per-leg quota doesn't, and reads in one line". The flaw is *depth*: a chunk at
rank 30 in both legs scores 2/90 ≈ 0.022, a single-leg rank-1 scores 1/61 ≈ 0.016. Even if a
tuned RRF matches the union's recall (`Q_tuned_rrf_baseline`), the change still stands on (b)
plus simplicity — "Readable in an evening" favours a quota over `fuse` + `RRF_K` + a paragraph
on damping — but the record should say which of the two it shipped for.

The extra hits are not the cost: no one asks for 5, `FINAL_K` is host policy, and ≤ 6 vs 5
snippets is negligible context. The real cost is that the keyword leg now *always* gets its
quota — on a lay paraphrase an OR'd bm25 top 3 can be junk that fusion used to sink. Hence
`Q_keyword_value` is the open question that matters most.

## Tuned RRF, measured (2026-10-29)

`Q_tuned_rrf_baseline`, same corpus, questions and bge-m3 index as above, no reranker; RRF
reimplemented in `../courts/bin/embedder-eval` with `k` and per-leg depth as knobs (at `k` 60,
depth 50 it ranks every question exactly as `Search.fuse` does — checked per question).

| Merge | top 5 | top 6 | top 10 | MRR |
|---|---|---|---|---|
| vector only | 24 | 24 | 26 | 0.75 |
| keyword only | 13 | 15 | 15 | 0.37 |
| RRF `k` 60, depth 50 (today) | 22 | 23 | 24 | 0.54 |
| RRF `k` 5, depth 50 | 23 | 25 | 26 | 0.63 |
| RRF `k` 60, depth 10 | 25 | 26 | 26 | 0.60 |
| RRF `k` 5, depth 10 | **26** | **26** | 26 | 0.61 |
| union 3 + 3, interleaved (≤ 6 hits) | 24 | 25 | 25 | **0.73** |
| union 5 + 5, interleaved (≤ 10 hits) | 24 | 25 | 26 | 0.74 |

- **Tuning RRF recovers all the recall, and a bit more.** `k` 5 over each leg's top 10 puts a
  gold § in the top 5 for 26/28 — the union 3 + 3 reaches 25 even at its full ≤ 6. One question
  of 28 is noise; "at least as good" is the honest reading.
- **The flaw is depth, as argued above.** Depth 10 alone (`k` 60) gets 25/26; `k` 5 alone at
  depth 50 only 23/25. Agreement *near the top* of both legs is signal — tal 6:24 sits at
  vector #8 and keyword #5, which the 3 + 3 quota drops and depth-10 RRF lifts to #3.
  Agreement deep in both lists is the noise.
- **The union wins on rank, not recall:** MRR 0.73 vs 0.61 — it puts the gold at #1 more
  often, because each leg's #1 is always at the top. That matters exactly if the model reads
  from the top (`Q_order`).

So this does **not** ship as a recall fix: a two-constant change to `fuse` (`RRF_K` 5, each
leg cut to 10 before fusing) gets the recall with today's shape. The unfused proposal stands or
falls on (b) provenance and simplicity, and on MRR. Labels don't need the union either — a
tuned-RRF list can carry "meaning #1, keyword #4" on each hit just as well — so the two halves
can ship separately.

## Exact-term questions, measured (2026-10-29)

`Q_keyword_value`: 13 questions added to `../courts/eval/questions.yml` (`kind: exact`), typed
the way a lawyer or HR person would — section references ("TSL 6:6", "työsopimuslain 7 luvun
3 §"), an act number ("1333/2021"), terms of art ("takaisinottovelvollisuus", "työaikapankki",
"varallaolo", "säästövapaa"). Gold § in the top 5, same index:

| Merge | paraphrase (28) | exact (13) | all (41) | MRR, all |
|---|---|---|---|---|
| vector only | 24 | 11 | 35 | 0.78 |
| keyword only | 13 | 7 | 20 | 0.42 |
| RRF `k` 60, depth 50 (today) | 22 | 9 | 31 | 0.57 |
| RRF `k` 5, depth 10 | **26** | 11 | **37** | 0.63 |
| union 3 + 3, interleaved | 24 | 11 | 35 | **0.77** |

- **The keyword leg rescued no question on its own.** bge-m3 already finds every term of art at
  #1 ("takaisinottovelvollisuus": vector #1, keyword #11). The keyword leg's measured value is as
  a *voter*: it lifts a vector #7 or #8 into the top 5 when it agrees near its own top (vll 2:5,
  tal 6:24). That is what tuned RRF uses and a quota throws away — a quota hands the keyword leg
  three slots whether or not it has anything, and the union lands exactly on vector-only (35).
- **Bare section references fail every leg:** "työsopimuslain 7 luvun 3 §" (best rank 14) and
  "työaikalain 5 luvun 19 §" (best 9). The tokens are "7", "luvun", "3" — digits that sit in every
  heading and every amendment date, and "luku", in every heading. No ranking finds that; it is a
  *lookup*, which the corpus's own table of contents answers exactly. A courts concern (the law
  agent's prompt), not a `rag_search` one.
- Limits: one embedder, and a strong one on Finnish; 165 chunks. With a weaker embedder (nomic:
  9/28 on paraphrase) or a large corpus where rare ids discriminate more, the keyword leg may
  rescue what it can't here. The voter role holds either way.

## Open questions

- Answered 2026-10-29, above: `Q_tuned_rrf_baseline` — tuned RRF matches the union's recall.
- Answered 2026-10-29, above: `Q_keyword_value` — on this corpus a voter, not a rescuer.
- `Q_merge` — leaning **tuned RRF** (`RRF_K` 5, each leg cut to 10 before fusing): best recall
  on all 41 (37 vs the union's 35) and today's code with two constants changed. The union's one
  edge is MRR (0.77 vs 0.63) — the gold more often at #1 — which matters only if a model reads
  from the top; provenance labels on the tuned list may close that gap.
- `Q_per_leg_k` — 3 + 3 (≤ 6 hits, 25/28) or 5 + 5 (≤ 10, 26/28)? Context cost vs recall;
  a `FINAL_K` per leg rather than one total. Leaning **3 + 3**: 5 + 5 buys one question for up
  to twice the context, and context is what a small local model runs out of.
- `Q_order` — two labelled groups, or interleaved (meaning #1, keyword #1, meaning #2, …)?
  A small local model may read only from the top, so the order may matter more than the labels.
  Leaning **interleaved**: with groups, keyword noise either leads or buries the vector hits,
  depending on which goes first. A both-legs hit sits at its better rank, with no agreement
  bonus — that bonus is exactly the flaw.
- `Q_model_uses_labels` — does the agent actually pick better? Measures retrieval only so far;
  needs an agent-level eval (answer quality on the same questions), not just "gold present".
- `Q_reranker_role` — drop the reranker from `rag_search`, or rerank only the union to order
  it? Either way it stops being a fixed stage. Leaning **drop**: 22 s for 20 documents puts 6
  at ~7 s on CPU, and it would replace the provenance order with one opaque score. Could come
  back as an opt-in reorder of the union.

## Next step

Tuned RRF shipped (`D_rrf_tuning`: `RRF_K` 5, `LEG_K` 10). Left: provenance labels on each
hit, whose value only an agent-level eval can show (`Q_model_uses_labels`), and `Q_merge`'s MRR
question. When those are settled — labels shipped or rejected — this idea graduates; its "don't
fuse" title was the wrong half.
