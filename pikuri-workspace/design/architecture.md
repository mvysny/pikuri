# pikuri-workspace design notes

The one cross-cutting subject in this gem that no other doc owns: the
**read-before-edit gate** — its lifecycle across five classes, and the
Write/Edit confirmation asymmetry that rests on it. Everything else is
already homed and does **not** live here:

- The **invariants** — the composite, `resolve_for_read` / `_write`, the
  gate, `File.writable?`-is-exact, {Pikuri::Workspace::WriteGate}, the
  semantic `Request`→`#ask` confirmer protocol, the {Pikuri::Sanitizer}
  defanging — are the **Workspace seam** and **Confirmer seam** in
  this gem's [`AGENTS.md`](../../AGENTS.md).
- The **reader-level posture** — reads-are-safe / writes-need-a-human,
  confirm-every-writable-write, the unwritable short-circuit, no
  sensitive-path list, `AllowAll` + empty denylist behind a container —
  is the book's OS-assistant chapter and the coding-agent chapter.
- Every **per-symbol contract** (the containment walk, the `AllowAll`
  credential denylist, ripgrep argv + truncation, strict-match Edit) is the owning class's YARD header.
- The `AllowAll` × `Sandbox` interplay (why `ALLOW_ALL` + `Sandbox::NONE`
  only inside a container) belongs to the Sandbox owner —
  [`../pikuri-code/design/architecture.md`](https://github.com/mvysny/pikuri-workshop/blob/master/pikuri-code/design/architecture.md).

## The read-before-edit gate

The gate is one rule: **a mutation of an *existing* file is refused
unless the agent has read that path this conversation.** No single class
owns it — five cooperate, and the point of this section is how they
compose (each piece's own contract stays in its YARD):

- **{Pikuri::Workspace::Read}** marks a path read on any successful read
  — including a partial window, since even a windowed read is enough for
  the model to know what it's changing.
- **{Pikuri::Workspace::Write}** and **{Pikuri::Workspace::Edit}** check
  the record before touching an existing file (a *new-file* Write is
  exempt — there was nothing to read), and both mark the path read after
  a successful mutation, so a just-authored file is immediately editable
  without a re-read.
- **{Pikuri::Workspace::Workspace}** *is* the record: a `Set` of
  workspace-relative keys. Relative keys scope it to one workspace, so a
  read in a sub-agent's temp clone can never satisfy an edit in another
  workspace.
- **{Pikuri::Workspace::Extension}** shares that one composite across all
  file tools and clears the record on conversation reset — a
  `/clear` re-arms the gate from empty.

## Two guards — why Write confirms an overwrite and Edit doesn't

Both tools share the gate above. The asymmetry — Edit runs promptless by
default while Write always takes a confirmer for overwrites — is not
inconsistency; it falls out of a *second*, content-level guard that only
Edit has:

- **Edit** requires `old_string` to match the current bytes, so a read
  file can change only where the model demonstrably knows the content.
  The match is itself an implicit read-check on top of the gate — hence
  no prompt is needed.
- **Write** has no per-change check: a hallucinated `content` would
  clobber the whole file. So it asks for confirmation on top of the gate,
  routed through {Pikuri::Workspace::WriteGate} for the diff payload and
  unwritable-target short-circuit.
- A **new-file** write hits neither guard — nothing to have read,
  nothing to clobber — so it writes silently (until the confirm-all-writes
  posture opts even new files into a prompt; that posture is a separate
  axis, taught in the book's OS-assistant chapter).
