# The desktop file index replaces rag for the secretary; rag and vectordb move to the workshop

Status (2026-11-18): both decisions are done. **A**: the secretary and `pikuri-briefing` search
through `pikuri-fileindex` (`D_secretary_wiring`, `D_briefing_wiring`). **B**: `pikuri-vectordb`
and `pikuri-rag` live in pikuri-workshop (`D_gem_placement`, test 1), pikuri's half in commit Y
(`3768548`). The workshop has pinned Y and keeps the eval's numbers in its `book/vectordb.md`
(workshop `c012e61`); Puri searches through pikuri-fileindex (puri `075bc06`). The recall chapter
is `book/recall.md`; the eval's misses by cause are there, and its harness and transcripts stay
at Y, linked from both books.

Two things keep this file alive, then it goes:

- **Siri's half** below goes to Puri's `design/research.md`, with the primary sources checked.
  The Spotlight fact pikuri's book uses is in `pikuri-fileindex/design/architecture.md`.
- **An owner's choice:** `secretary.md`'s reminder exchange ("Where the gate earned its keep")
  is from the chapter's first recording. Seven re-runs on the file index never offered a
  reminder, so it is labelled as such rather than re-recorded.

## Siri does the same: it borrows the OS's index (2026-11-17)

- WWDC26 (2026-06-08) Siri AI reaches personal context through the **Spotlight index**, on
  device, via a system orchestrator. That comes from secondary coverage of Apple's newsroom
  post. Siri doesn't own an index; it queries the OS's.
- Core Spotlight has had a *semantic* index since WWDC24 (session 10131): apps donate items,
  `title` / `textContent` "will be processed in the semantic index", and indexing is
  scheduled for idle time (device asleep). Apple hasn't published the embedding model or
  index format. "Local vector search" claims are secondary and unverified.
- So Puri on localsearch has Siri's architecture without the semantic half. GNOME's index is
  lexical, Apple's is semantic and built on the NPU while the device is idle. If GNOME ever
  gains a semantic index, the borrowing shape picks it up unchanged.
