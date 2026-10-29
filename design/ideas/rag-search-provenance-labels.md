# `rag_search`: label each hit with the leg(s) that found it

Spun off from the graduated "show both legs, don't fuse them" idea (2026-10-29). The fusion
stays (`design/decisions.md` `D_rrf_tuning`); what's left is telling the model *why* each hit
is there:

```
Found 5 matches.

[1] tsl.md lines 812-840 — meaning #1, keyword #4
...
[2] ytl.md lines 300-331 — keyword #1
...
```

- The model reads the snippets anyway and is a far larger relevance judge than RRF or a
  cross-encoder; the labels give it the provenance fusion throws away.
- The labels could replace the single `score=` label, which today covers three scales: fused
  rank, cross-encoder relevance and cosine (`Rag::Tools::Search` header). Per-leg ranks are
  honest where that number isn't.
- Measured motive: the unfused union (each leg's top 3, interleaved) reached MRR 0.77 against
  tuned RRF's 0.63 on the courts corpus, with the same or better recall from RRF. Labels on the
  fused list might close that gap without the union's recall loss.

## Open questions

- `Q_model_uses_labels` — does the agent actually pick better? Retrieval evals can't tell;
  needs an agent-level eval (answer quality on `../courts/eval/questions.yml`), not just "gold
  present".
- `Q_reranker_role` — with labels, does the reranker still earn a fixed stage? It cost 22 s
  per question on CPU for 20 documents (bge-reranker-v2-m3), it now scores ≤ 20 fused
  candidates, and its one opaque score would override the provenance order. Could become an
  opt-in reorder.
