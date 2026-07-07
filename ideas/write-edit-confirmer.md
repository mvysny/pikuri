# Write/Edit path-zone confirmer: full read, confirmed writes

Status: **deferred design — Piece 1 machinery shipped, Piece 2 (this
note) not built.** This is the write-side half of the pikuri-os
tool-consistency work sketched in [`os-assistant.md`](os-assistant.md)
(the "path-zone auto-allow" fatigue item, kept there as a pointer). It
was split from a companion read-side change:

- **Piece 1 (shipped)** — {Pikuri::Workspace::Filesystem::AllowAll} gained
  a `denylist:` constructor parameter (default
  `DEFAULT_CREDENTIAL_DENYLIST`, the old hardcoded floor). Pure
  machinery, zero behavior change: every current caller gets the default
  and denies credential reads/writes exactly as before. This is the knob
  Piece 2 turns.
- **Piece 2 (this note)** — pikuri-os flips that knob to `[]` (full read,
  consistent with bash) *and* adds a write-confirmation tier so the
  now-reachable sensitive writes prompt with a diff. The two land
  together so no intermediate state has unconfirmed writes to secrets.

## Related

- [`os-assistant.md`](os-assistant.md) §"Deferred / not yet built" — the
  "path-zone auto-allow" pointer; pikuri-os is the (only) customer.
- [`bash-confirmer.md`](bash-confirmer.md) — the *bash*-side confirmer
  fatigue work. This note is its Write/Edit analog: same governing
  invariant (**code + the human decide — an LLM may translate, never
  render the ✓/⚠ verdict**), different tool surface. The key asymmetry:
  a bash command is Turing-complete (effect unknowable statically),
  whereas Write/Edit have structured inputs — a known path + exact bytes
  — so a path-zone rule is *sound* and the diff is *exact*. That's why
  the auto-approve/confirm split is reliable here and only heuristic
  there.
- [`more-confirmers.md`](more-confirmers.md) — the authorship/steering
  axis (author seat, reason channel). Distinct from this note's
  fatigue/comprehension axis.
- {Pikuri::Workspace::Filesystem::AllowAll} — the Piece-1
  `denylist:` knob.
- {Pikuri::Workspace::Write} / {Pikuri::Workspace::Edit} /
  {Pikuri::Workspace::Confirmer} — the tools + seam Piece 2 extends.

## The threat-model reconciliation (why this is the right shape)

pikuri-os is a full-host operator, so its boundary is **egress**, not
containment (kernel-severed bash + human-confirmed research tasks — see
book ch7). Under that model the read denylist on the *file* tools was
never load-bearing: bash already reads any secret (`cat ~/.ssh/id_rsa`
is auto-approved by the read-only auto-confirmer, which classifies the
command, not the path), so blocking `Read` while leaving bash open was
**a false-consistency wart**, not a defense. Piece 2 removes it.

The resulting posture puts each axis behind the boundary that actually
governs it:

- **Reads gated by egress.** All tools read the whole disk (the owner's
  own files); a secret in context can't leave, because egress is severed
  / user-confirmed. If the owner approves leaking their own keys, that's
  the owner operating their own box — not something we can or should
  prevent.
- **Writes gated by confirmation.** Reachable ≠ silently writable:
  sensitive-path writes prompt the human with an exact diff. This is
  where `confirm_paths` comes in.

This keeps pikuri-code untouched (it keeps the network, so *containment*
is its boundary — the default `denylist` floor stays, and
`confirm_paths` is empty).

## Piece 2 — the change

1. **pikuri-os opts out of the read floor.** In
   `bin/pikuri-os-assistant`, construct
   `Filesystem::AllowAll.new(project_root:, denylist: [])`
   with a comment binding the opt-out to the user-confirmed-egress
   invariant (re-instate the floor the moment the parent gains
   *unmediated* egress). Read/Grep/Glob now see what bash sees.

2. **`confirm_paths:` on Write and Edit.** Both tools take a list of
   absolute paths via constructor. A write/edit whose *resolved* target
   equals or lies under any entry → confirm; otherwise current behavior.
   - **Reuse the denylist's matcher**, don't reimplement it: filesystem
     already does symlink-resolved descendant matching (so
     `/tmp/link → ~/.ssh` can't dodge the gate). Path matching in tool
     code is exactly where a bypass hides — expose a small `Filesystem`
     helper and call it.
   - **Additive.** Write keeps its existing overwrite-confirm; the list
     only *adds* triggers (pikuri-code's `[]` ⇒ unchanged). Edit gains a
     `confirmer:` (a `Workspace::Extension` wiring change) used *only*
     when the target is in `confirm_paths` — ordinary edits stay
     unprompted, so edit.rb's "why no confirmer" rationale narrows to
     "no confirmer *for ordinary edits*."

3. **Deterministic diff in the confirmation.** Since both byte sequences
   are in hand, the sensitive-path prompt carries an exact unified diff
   in `Confirmer::Request.detail` (Edit's `old_string`→`new_string` *is*
   the diff; Write's is old-bytes→new-content). `Terminal` already
   renders `detail`, so this is nearly free and is the whole point of
   confirming a sensitive file. It's the deterministic cousin of
   bash-confirmer's AI translation aid — same "human as informed
   decider" goal, no LLM, no manipulability.

The single emptied `denylist` + `confirm_paths` yields "full
read, confirmed write" without ever needing a *write*-side denylist
variant — the confirmation is the write gate.

## Open question — the pikuri-os `confirm_paths` list

The set to define (absolute, HOME-expanded; matched as file-or-directory
prefix). Starting proposal, to refine by use:

- `/etc` (system config), `/boot` (bootloader/kernel)
- the credential dirs now reachable: `~/.ssh`, `~/.gnupg`, `~/.aws`,
  `~/.kube`, `~/.docker`, `~/.netrc`
- shell init (run on login → exec risk): `~/.bashrc`, `~/.bash_profile`,
  `~/.profile`, `~/.zshrc`, `~/.zprofile`
- `~/.gitconfig`, `~/.config` (app + systemd-user config)

Tension to settle: **too broad reintroduces the fatigue this is meant to
cut; too narrow misses a dangerous edit.** And for a full-disk agent, is
"outside `$HOME`" itself a sensitivity signal (writing `/usr`, `/opt`,
another user's home)? That's the policy-heavy part and the reason this
half stayed deferred while Piece 1 shipped.

## Deferred / not yet built

All of Piece 2 above. Piece 1 (the `denylist:` parameter) is
in `pikuri-workspace`; nothing turns the knob yet, so pikuri-os behaves
exactly as before until this lands.
