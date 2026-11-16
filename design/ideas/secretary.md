# The secretary: what's still open

`bin/pikuri-secretary` is built and its chapter, `book/secretary.md`, is written; the forks it
settled are `D_secretary_wiring`. What's left is the questions below, answered from more
transcripts.

## Open questions

- `Q_decline_snippet`: without `Workspace::Extension`, its "a decline is final" prompt snippet
  isn't wired. The confirmer's decline observation says the same and the smoke test honoured it;
  wire the snippet anyway if transcripts show a retry.
- `Q_embed_throughput`: embedding ran at about 7 chunks/s (~3,400 tokens/s) on the owner's GPU.
  Is that the embedder's real ceiling, or llama-server's batching flags?
