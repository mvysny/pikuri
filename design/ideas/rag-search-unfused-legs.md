# `rag_search`: show both legs, don't fuse them

Status: **idea, not built.** Origin: the courts repo's embedder eval, 2026-10-29
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

## Open questions

- `Q_per_leg_k` — 3 + 3 (≤ 6 hits, 25/28) or 5 + 5 (≤ 10, 26/28)? Context cost vs recall;
  a `FINAL_K` per leg rather than one total.
- `Q_order` — two labelled groups, or interleaved (meaning #1, keyword #1, meaning #2, …)?
  A small local model may read only from the top, so the order may matter more than the labels.
- `Q_model_uses_labels` — does the agent actually pick better? Measures retrieval only so far;
  needs an agent-level eval (answer quality on the same questions), not just "gold present".
- `Q_keyword_value` — the courts questions are lay paraphrases by design, which favour the
  vector leg (vector top 10 alone also reaches 26/28). The keyword leg's job — ids, "55/2001",
  "7 luvun 3 §", rare terms — is barely tested. Add exact-term questions before reading
  anything into it.
- `Q_reranker_role` — drop the reranker from `rag_search`, or rerank only the union (≤ 10
  documents, cheap) to order it? Either way it stops being a fixed stage.
