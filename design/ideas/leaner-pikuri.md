# Leaner pikuri

What remains of the 2026-11-14/15 reachability audit (roots = the `bin/` scripts + every gem's
`lib/`). Its rules for what stays graduated into `D_read_what_you_run`; these are the side findings
still open.

- `Q_embedder_throttle` — `VectorDb::Embedder` now owns its `RubyLLM::Context`, but embeds still
  skip `around_request`, so a host's llama-server throttle never sees a reindex barrage. Leaning
  yes: take `around_request:` on the Embedder, same contract as `Agent.new`'s.
- `Q_reranker_via_ruby_llm` — ruby_llm 2.2 has `Context#rerank` with a Jina-style
  `chat_completions` protocol (`POST rerank`, `results[].relevance_score`), llama-server's shape;
  if `:openai` routes there, `Reranker::LlamaServer`'s own Faraday client can go. Unverified.
- `Q_stale_thunderbird_docs` — `MailCompose` yardoc ("never wired", flag `compose:` → is
  `allow_compose_mail:`); entry file's "v2"; `pikuri-computer:187` "five" tools (six).
