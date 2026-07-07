# Write/Edit confirmer: full read, confirmed writes

Status: **shipped.** The write-side half of the pikuri-os
tool-consistency work sketched in [`os-assistant.md`](os-assistant.md).
Landed in two steps:

- **Piece 1** — {Pikuri::Workspace::Filesystem::AllowAll} gained a generic
  `denylist:` constructor parameter (default `DEFAULT_CREDENTIAL_DENYLIST`,
  the old hardcoded floor).
- **Piece 2** — pikuri-os flips that knob to `[]` (full read, consistent
  with bash) *and* Write/Edit **confirm every write the agent can actually
  perform**, with a diff; unwritable targets short-circuit to "sudo it
  yourself" without prompting.

Where it graduated (source of truth is now the code + yardoc):

- {Pikuri::Workspace::WriteGate} — the pre-write gate (writability
  short-circuit + confirm-with-diff + decline messages).
- {Pikuri::Workspace::Write} / {Pikuri::Workspace::Edit} — the
  `confirm_all_writes:` posture.
- {Pikuri::Workspace::Confirmer::Change} + `Confirmer::Terminal` — the
  structured change payload + `diff -u` rendering.
- {Pikuri::Os::Extension} (`confirm_all_writes: true`) + the bin's
  `denylist: []`.

This note keeps the cross-cutting *why* (the threat-model reconciliation)
and the one explicitly-deferred generalization.

## Related

- [`os-assistant.md`](os-assistant.md) §"Deferred / not yet built" — the
  pointer bullet; pikuri-os is the (only) customer.
- [`bash-confirmer.md`](bash-confirmer.md) — the *bash*-side confirmer
  fatigue work. Same governing invariant (**code + the human decide — an
  LLM may translate, never render the ✓/⚠ verdict**), different tool
  surface. The diff below is the deterministic cousin of that note's AI
  translation aid: same "human as informed decider" goal, no LLM.
- [`more-confirmers.md`](more-confirmers.md) — the authorship/steering
  axis. We deliberately do *not* pull in its editable "author seat" here
  (see "Not editable").
- {Pikuri::Workspace::Filesystem::AllowAll} — the Piece-1 `denylist:` knob.
- {Pikuri::Workspace::Write} / {Pikuri::Workspace::Edit} /
  {Pikuri::Workspace::Confirmer} — the tools + seam Piece 2 extends.

## The threat-model reconciliation (why this shape)

pikuri-os is a full-host operator, so its boundary is **egress**, not
containment (kernel-severed bash + human-confirmed research tasks — see
book ch7). Under that model the read denylist on the *file* tools was
never load-bearing: bash already reads any secret (`cat ~/.ssh/id_rsa`
is auto-approved by the read-only auto-confirmer, which classifies the
command, not the path), so blocking `Read` while leaving bash open was
**false-consistency**, not a defense. Piece 2 removes it, and puts each
axis behind the boundary that actually governs it:

- **Reads gated by egress.** All tools read the whole disk (the owner's
  own files); a secret in context can't leave, because egress is severed
  / user-confirmed. If the owner approves leaking their own keys, that's
  the owner operating their own box.
- **Writes gated by confirmation.** Reachable ≠ silently writable: every
  write the agent can perform is confirmed with an exact diff.

## The design (shipped)

Two knobs, **no path list**:

1. **pikuri-os opts out of the read floor.** In
   `bin/pikuri-os-assistant`, `Filesystem::AllowAll.new(project_root:,
   denylist: [])`, commented to bind the opt-out to the
   user-confirmed-egress invariant (re-instate the floor the moment the
   parent gains *unmediated* egress). Read/Grep/Glob now see what bash
   sees.

2. **Confirm-all-writable on Write/Edit.** Every write the agent *can*
   perform is confirmed with a diff; writes that would fail short-circuit
   to a permission error with no prompt (below).

### Why confirm-all, not a "sensitive paths" list

The original sketch was "auto-allow ordinary writes, confirm sensitive
ones" — which forces us to *enumerate what's sensitive* for a full-disk
agent (`/etc`, every app's `~/.config`, dotfiles, `/boot`, systemd,
cron, other users' homes…). That's the same unwinnable enumeration the
"Environment is not a secret store" seam and the bash auto-confirmer both
reject. Confirm-all sidesteps it, and it fits pikuri-os specifically:

- **Writes are rare.** It's a *diagnosis* agent — it reads constantly and
  writes exceptionally (fix a config, repair a file). So the fatigue
  argument for auto-allow nearly evaporates; there's little volume to cut.
- **It's the true bash-consistency.** In pikuri-os, bash routes *every*
  mutation through the confirmer (read-only auto-approves; everything
  else → human). So the consistent posture for the file tools is *every*
  Write/Edit confirms too — not "sometimes, if the path looks sensitive."
- **It can't be gamed** — no path classification to get wrong.

If selectivity is ever needed (a frequent-writing full-disk agent — none
ships today), the right generalization is the *inverse* of the sensitive
list: an **allowlist of auto-allowed (safe) paths**, deny-by-default =
confirm — the winning side of the enumeration game, same as
`READ_ONLY_BINARIES`. Build that only when such an agent exists; see
"Deferred."

### The writability short-circuit (subsumes /etc, /boot)

Before confirming, check writability; only prompt for writes that will
actually land:

> Not writable → return `Error: permission denied — cannot write <path>
> as this user; ask the user to make the change with sudo.` Writable →
> build the diff → confirm → write.

The fact that makes this exact: **the file tools run in the main pikuri
process as the real user — the sandbox (`FullFsNoNet`) wraps only
*bash*.** So a `Write`/`Edit` to `/etc` fails with a plain
`Errno::EACCES` in-process, and `File.writable?` reflects the user's
*real* permissions (existing file → `File.writable?(path)`; new file →
`File.writable?(dirname)`).

The payoff: the confirm set is **self-defining** and we never enumerate
`/etc` or `/boot`. Writable-by-the-agent = the user's own files (their
`$HOME`, dotfiles, `~/.ssh`, docs, configs) — exactly the set worth a
human look. Unwritable = `/etc`, `/boot`, `/usr`, root-owned, other
users' homes → short-circuit to "sudo it yourself," no prompt, no noise.
This is also what the OS helper is *supposed* to do for privileged edits:
advise, don't execute (it has no sudo in the namespace anyway).

Honest wrinkle: `File.writable?` is a heuristic vs. ACLs / read-only
mounts / TOCTOU. So if it says writable but the write then fails, return
the real OS error; if it's occasionally pessimistic, worst case we
tell the user to sudo when they marginally could — accepted.

### The diff is presentation (the chrome renders it)

The confirm is only meaningful if the human sees *what changes*, and
under the Confirmer seam presentation belongs to the chrome. So the tool
hands the Confirmer the **semantic change** — path + old bytes + new
bytes (Edit: `old_string`/`new_string`, the hunk; Write: old-file /
new-content) — and each chrome renders the diff its own way:

- **educational shipped bins** → shell out to the `diff` binary (through
  the `Subprocess` seam — legible and teachable);
- **pikuri-tui** (downstream production) → its LCS Ruby gem.

That keeps the differ choice at the *deployment* layer, with no differ
dependency in the tool or `pikuri-core`. Structural consequence:
`Confirmer::Request` grows an optional structured change payload (path +
old + new) alongside the current pre-rendered `detail` string — a
diff-capable chrome renders it, a plain one falls back to a size summary
(`"120 → 245 bytes"`, the shape `Write` already uses). Large-file writes
cap the rendered diff (first N hunks, "…M more").

### Not editable

Allow, or deny-with-reason — no editing of the bytes. The confirmer's
`Rejected(reason)` already carries steering back to the model; we simply
don't set `editable: true`. The editable "author seat" (human rewrites
the config before it lands) is the richer work tracked in
[`more-confirmers.md`](more-confirmers.md); deliberately out of scope
here.

### Edit gains a confirmer

Today {Pikuri::Workspace::Edit} takes no confirmer (bounded by the
read-before-edit gate + `old_string` as an implicit read-check). Piece 2
threads one in via `Workspace::Extension`, fired for every writable edit.
edit.rb's "why no confirmer" rationale narrows to "no confirmer where the
host wires none; the OS helper wires confirm-all." pikuri-code passes no
confirmer to Edit (unchanged) — this is opt-in for the full-disk agent.

## `DEFAULT_CREDENTIAL_DENYLIST` stays

The Piece-1 constant does **not** go away — it remains the safe default
for `AllowAll`, load-bearing for callers that aren't pikuri-os. The other
`AllowAll` caller is **`pikuri-code --yolo`** (`Sandbox::NONE`: full fs,
full network, no confirmer), where the denylist is exactly the
defense-in-depth the yardoc describes — best-effort protection against
the file tools reading bind-mounted host credentials in a throwaway
container. pikuri-os is the *sole* explicit opt-out. The whole
"default-on, opt-out explicitly" structure exists precisely so pikuri-os
can drop it without weakening `--yolo` / container callers.

Three coherent postures, one `denylist:` knob + one confirm-all flag:

| agent | boundary | denylist | writes |
|---|---|---|---|
| pikuri-code (contained) | containment | default-on | rarely confirmed (containment protects) |
| pikuri-code `--yolo` (container) | the container | default-on (defense-in-depth) | no confirmer |
| pikuri-os (full-disk) | egress-severance | `[]` (opt-out) | every *writable* write confirmed with a diff |

## Deferred / not yet built

The one explicitly-punted generalization: the **allowlist-of-safe-paths**
auto-allow (for a hypothetical frequent-writing full-disk agent, which
would want *some* writes to skip the prompt) — build it if such an agent
ships, not speculatively. Everything else in this note is shipped.
