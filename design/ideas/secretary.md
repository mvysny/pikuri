# The secretary: what's still open

`bin/pikuri-secretary` is built and its chapter, `book/secretary.md`, is written; the forks it
settled are `D_secretary_wiring`. What's left is the questions below, answered from more
transcripts.

## Open questions

- `Q_two_readers`: the notes folder has two read tools, `rag_read` and workspace `read`, because
  edit only touches a file read through `read` (the read-before-edit gate). Seen twice
  (2026-11-13): the model tried `read` on a document outside the notes folder, and
  `read(xyz/spec.txt)` with a path `rag_read` takes relative to `~/Documents`. Both times it
  recovered, at one wasted call; the error now names the notes root. Does the model pick the right
  reader before an edit, or does it need rag's read to count for the gate?
- `Q_decline_snippet`: without `Workspace::Extension`, its "a decline is final" prompt snippet
  isn't wired. The confirmer's decline observation says the same and the smoke test honoured it;
  wire the snippet anyway if transcripts show a retry.
- `Q_embed_throughput`: embedding ran at about 7 chunks/s (~3,400 tokens/s) on the owner's GPU.
  Is that the embedder's real ceiling, or llama-server's batching flags?
