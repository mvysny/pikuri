# DECISIONS.md

A living record of the design decisions behind pikuri — especially the
*roads not taken*. It exists because the graduation pipeline (see
[`CLAUDE.md`](CLAUDE.md)) had no home for one fact class: a rejected
alternative. Both candidate homes refuse it on their own stated terms —
yardoc is browsed standalone on rubydoc.info by someone at the API, who
gains nothing from an argument against a design that never shipped; and
CLAUDE.md is loaded into *every* session's context under a 40 KB cap, so
rationale there is paid for on every turn. This file is the lazy side of
that split: never context-loaded, read only when someone asks "why this
way?".

It is the *why-we-chose* record. It is not the *how-it-works* reference
(yardoc), the *why-the-concept* narrative (the book), the *what-you-must-
not-break* list (CLAUDE.md), a gem's architecture + threat model (per-gem
`DESIGN.md`), what other projects do (`COMPARISON.md`), or the shipped
defenses (`SECURITY.md`). An entry links out rather than restating.

**Boundaries** — the three that keep this from becoming a second copy of a
neighbor:

- **vs. per-gem `DESIGN.md`.** DESIGN.md describes the system *as it is*,
  for someone extending that gem. This file records *forks*, and is
  repo-root so it can hold the cross-gem ones DESIGN.md structurally
  can't. Carve-out: when a rejected alternative is gem-local *and*
  inseparable from that gem's threat model, leave the reasoning in the
  gem's DESIGN.md and make the entry here a one-line pointer. Never two
  half-answers.
- **vs. `COMPARISON.md`.** That file says what *others* do; this one
  records our choice against that option.
- **vs. `SECURITY.md`.** A shipped defense stays there. Only the fork
  ("rejected X because it widens the surface") comes here.

**Format.** One entry per decision. The ID is a slug, not a number: `D-`
plus a 1–4-word kebab hint at the subject (`D-per-process-temp`), so a
citation carries meaning on its own. The `(date)` on the heading is
*decided* provenance, not a log position — git owns the edit history, so
don't narrate how an entry used to read. Keep each entry tight: context,
the decision, the alternatives rejected and why, and the consequences a
future contributor would trip over. A decision is worth logging the moment
it's *made*; implementation can lag (the `Status:` line says which).

**No entry without a real fork.** If nothing was seriously considered and
rejected, it isn't a decision — it's how the thing works, and that's
yardoc. This is the guard against a diary. Nor is an entry warranted when
the fork is already argued somewhere durable — a rejected alternative with
real teaching value belongs to the **book** (worked example: the
MoE-vs-dense-model argument, the book's first-conversation chapter), and this file would only duplicate
it.

**Newest first.** Entries run reverse-chronologically by decided date, so a
scan hits recent decisions first.

**Never read wholesale.** `grep '^## D-' DECISIONS.md` is the index; there
is no ToC (same discipline as `ls ideas/`). Cite an entry by slug. Grep
tripwire: every `D-<slug>` referenced anywhere in the repo must exist as a
`^## D-` heading here.

**Entries are mutable — edit in place, don't append addendums.** Each entry
is the single coherent home for one *live* decision; keep it current as the
decision is refined or extended. Two things this does *not* license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is live
  content of the current decision, not stale history — never edit it away.
  It's the most valuable thing in the file.
- **A reversed *shipped* decision forks a tombstone, it is not
  overwritten.** When a design was tried, shipped, and then thrown away,
  leave the old entry as the scar, set its `Status:` to **Superseded by
  D-\<slug\>**, and write the replacement fresh. The line: *refined or
  extended* → edit in place; *reversed after shipping* → tombstone + new
  entry.

**Backfill is opportunistic.** Rejection rationale that already sits inline
in a yardoc or a `DESIGN.md` (the pre-2026-08-04 convention) stays put —
this file is the home going *forward*. Move an old one only when you're
already editing that doc and the inline rejection is crowding out the live
design.

---

## D-egress-axis-shape — Two orthogonal egress axes, no invented persona (2026-08-12)

**Status:** Accepted; implemented 2026-08-12 in
{Pikuri::Tool::TrifectaLegs}. Folds in two earlier forks that never had a
home: the `egress_human_author` drop (2026-08-09) and the rejected
proxy-visible middle rung.

**Context.** The detector's egress leg started as one graded axis
(`none < human_approver < autonomous`) reading *payload visibility* — did a
human see the bytes, or only a proxy for them? A second property kept
recurring in the notes without a place to live: `web_search` reaches an
engine this repo picked, while `fetch` reaches a host the model chose, and
an attacker can read back the second but not the first. The two were
repeatedly mistaken for rungs of one scale.

**Decision.** The egress leg is **two orthogonal axes**, both carrying
`:no_egress` at the bottom and kept coherent by the constructor:
`egress_payload_review` (`:human_reviewed` / `:unreviewed`) and
`egress_destination` (`:tool_vouched` / `:attacker_reachable`). The verdict
grid becomes eight exhaustive clauses; exactly one cell moved, and no
shipped wiring's verdict changed.

**Alternatives rejected.**

- **A third rung on the visibility axis (`egress_human_author`).** Dropped
  2026-08-09, not deferred: a seat whose outbound bytes originate in the
  human's own intent holds no egress leg to grade, so it declares
  `:no_egress`. A rung definitionally equal to the bottom rung is not a
  rung, and clean-by-construction is leg-*absence*. The teaching gain is
  sharper too: **the only thing better than a reviewed gate is not holding
  the leg.**
- **A middle rung for a gate showing a *proxy* for the payload** (bash
  behind a confirmer). Rejected: it would make `Code::Bash` soft and with it
  every loud verdict in the repo. The admissible test is structural —
  payload or proxy — and grading the human's attention instead relaunches
  trust-the-approver at a finer grain.
- **Naming the visibility axis for the seat** (`egress_confirmer`,
  `egress_gatekeeper`), i.e. "who can stop it". Rejected on the same
  example, one level up: `Code::Bash` *has* a confirmer and still grades
  top-rung, so a seat-named field invites a confirmer-holding tool to
  declare the softer rung and silently deletes the alarm. Naming the
  payload makes `:unreviewed` cover both "no human" and "a human who saw
  only a proxy" without a gloss.
- **Grading the destination by who chose it** (`:tool_pinned` vs
  `:llm_chosen`). The natural framing, killed by one counter-example: a
  tool hard-coding a POST to `github.com` picks its own destination and
  still hands the bytes over, because a gist is world-readable. Pinning is
  necessary, not sufficient — so the axis asks whether a hijacked model can
  *reach the attacker*, and `:attacker_reachable` covers a model-chosen host
  and a republishing fixed sink with one rung.
- **`:safe_vetted_set` for the softer rung.** Rejected: this detector never
  claims safety. Bytes genuinely leave a vouched destination; they merely
  cannot be read back.
- **`egress_target_server`.** Rejected: a mail recipient is not a server,
  and the parked custody question (`ideas/trifecta-detector.md`) has synced
  folders as candidate sinks.
- **Folding both axes into one lattice.** Rejected: neither dominates the
  other. A reviewed send to an attacker's inbox and an unreviewed query to a
  vouched engine are different animals, and a single scale would have to
  order them.
- **Nesting the pair in an `EgressLeg` value that is `nil` when absent.**
  Genuinely deletes the both-or-neither invariant, but costs a nested
  `Data`, `nil`-handling at ~10 read sites and churn at every declaration
  site. The invariant is three lines in a constructor; that was the cheaper
  trade.
- **Shipping a `SEARCHER` persona alongside the axis.** The plan of record
  bundled them ("all three together or none") on the grounds that the tag
  alone is decoration. Rejected: that conflates two reachabilities. The
  *verdict* cell needs a search-only wiring, but the **map** shows the
  distinction the day `web_search` declares it, which is where the teaching
  value lives. Inventing a persona so a verdict could fire would have traded
  away page-reading in a demo to satisfy the detector — and the detector must
  not be what forces a capability decision.

**Consequences.**

- **The detector now has two declared axes and one determined.**
  `:tool_vouched` is a claim the framework inherits from the tool's author,
  exactly as `private:` is inherited from the user; only `untrusted` is
  determined. The vocabulary says which is which, and the book says the tag
  is worth precisely the care that went into declaring it.
- **A vouched destination survives only as the sole egress leg.** No special
  case: `max` at a node hardens it the moment one attacker-reachable tool
  joins. The advisory for that cell says so, so a soft verdict does not read
  as settled.
- **A soft cell no shipped wiring reaches.** Every persona holding
  `web_search` also holds `fetch`. It is tested from hand-built nodes and
  waits for the first host that wants a search-only agent; the unplaced-level
  tripwire in `Report#verdict` was re-pointed at a hypothetical fourth level
  so it survives its own graduation.
- **The delegation cap applies to one axis.** A gate bounds what leaves and
  who saw it, never who can read it back, so `#cap_payload_review` leaves the
  destination alone — the name says the scope.

---

## D-blob-spotter-alphabets — Single-alphabet encodings count, at their own longer thresholds (2026-08-08)

**Status:** Accepted; implemented 2026-08-08 in
{Pikuri::Thunderbird::ComposeGuard}. Supersedes an inline "hex and base32
stay out" note that lived in `#body_blob_note`'s yardoc, moved here under
the pre-2026-08-04 relocation rule above.

**Context.** The blob spotter soft-warns when a compose body carries an
encoded dump — the lazy way to walk a secret past a skimming human. Its
original gate was three-class (upper *and* lower *and* a digit) over the
base64 alphabet, which by construction can match neither single-case hex
nor base32. Stress-testing the egress axis surfaced the hole: those two are
not evasion, they are the *natural* dress for a key — it is already hex on
disk — and they drew **no flag at all**. 64 lowercase hex chars is an
entire 256-bit ed25519 seed, silent.

**Decision.** Two chunk shapes with independent thresholds, whichever trips
first: the existing three-class shape at 16/32, and a single-alphabet shape
({Pikuri::Thunderbird::ComposeGuard::HEX_ALPHABET} /
`BASE32_ALPHABET`) at 32/48. 48 is not a round number — it is the only gap
available, above a full git SHA-1 (40) and below a 32-byte key in base32
(52) or hex (64).

**Alternatives rejected.**

- **Keep hex and base32 out** (the original call). Its reasoning was right
  about the *mechanism* — a two-class alphabet cannot clear a three-class
  gate — but weighed only false positives and never counted the zero-flag
  hole on the other side. A guard that catches the encoding an attacker
  picks *when trying to look normal*, and misses the one they pick by
  default, has its priorities inverted.
- **Widen the three-class gate to two classes.** This is what the original
  note actually rejected, and rightly: it applies the *base64* thresholds
  (16/32) to hex, so every UUID and every short SHA in an engineering mail
  warns. Alarm fatigue, and the note is body-wide, so one dev thread would
  train the user to ignore it. Separate longer thresholds get the coverage
  without touching that gate.
- **Raise the single-class join to 64** to dodge the SHA-256 false
  positive. Buys FP relief by surrendering half the coverage: a 32-byte key
  in base32 is 52 chars, so the threshold *must* sit below 52 to see it.
- **Fail closed on a blob** instead of warning. Same answer as everywhere
  else in this guard: it is trivially walked under by splitting the payload
  into sub-threshold pieces, so a hard reject would block honest mail while
  stopping no motivated attacker.

**Consequences.** A lone SHA-256 checksum (64 hex chars) now warns, and
this is irreducible — a 256-bit hash and a 256-bit key are the same string,
so no threshold separates them. Accepted: checksums are rare in mail, keys
are the thing being looked for. The guard's character is unchanged — a
paste / dumb-attack guard, not an exfil control; widening the alphabets
raises the attacker's cost by one token of prompt.

## D-headless-os-agent — No app launching, and the sandbox masks the session's IPC surface (2026-08-06)

**Status:** Accepted. The mask ships in
{Pikuri::Code::Bash::Sandbox::FullFsNoNet::SESSION_IPC_MASKS}; app launching
was never built and now won't be.

**Context.** `pikuri-os` advises on GUI config (it prints the `gsettings`
command rather than applying it), and "let it launch apps / `xdg-open` a
file" sat on the deferred list as a post-v1 nicety. Measuring what
`FullFsNoNet` actually permits killed the nicety and exposed a hole in the
egress cut, on this host, GNOME/Wayland:

- A sandboxed `curl` gets nothing (`000`, loopback-only netns). The same
  `curl` handed to `systemd-run --user` returns **HTTP 200** — `systemd
  --user` spawns it in the *host* netns, parented outside the sandbox.
- `xdg-open file.png` on a `DBusActivatable=true` handler (loupe) is spawned
  by the session bus: host netns, full network, cgroup `dbus.service`, and it
  survives `--die-with-parent` because it was never a child.
- A plain `Exec=` handler (librewolf) forks *inside* the sandbox and is
  contained — **unless an instance is already running**, in which case the
  remote-instance handoff delivers the URL to the outside process. Measured
  both ways: cold browser → "Unable to connect"; warm browser → the GET
  landed in the listener's log. Containment that depends on whether the user
  happens to have their browser open is not a security property.

So the trifecta's egress leg reopened through the session, and the enabling
authority is one unauthenticated socket: the session bus is the user's own
bus, with the user's full authority and no polkit in front of it.

**Decision.** The OS agent is **headless**. Two halves, one decision:

1. **No launcher.** No `open`/`launch` tool, and no GUI-application arm to
   the config advice. The human is at the keyboard; opening a file or
   starting an app is a double-click, so the capability buys ~nothing while
   costing an egress channel.
2. **The sandbox subtracts the session's live IPC surface** — a tmpfs over
   `$XDG_RUNTIME_DIR` (session bus, Wayland socket, keyring / ssh-agent /
   at-spi, a rootless container daemon) and over `/tmp/.X11-unix`, plus a
   `/dev/null` mask over a `DBUS_SESSION_BUS_ADDRESS` pointing elsewhere.
   Abstract-namespace sockets need no mask: `--unshare-net` already scopes
   them (measured — reachable from the host, `ECONNREFUSED` inside).

Being headless is what *permits* half 2: with launching declined, nothing
legitimate wants those sockets.

**Alternatives rejected.**

- **Ship the launcher anyway, confirmer-gated.** Rejected on value, not just
  risk: it's an egress-capable tool in a deliberately offline agent, bought
  for a double-click. It would also have to pick a broken semantics —
  direct-exec keeps the egress cut but ships crippled apps (a browser with no
  network), `xdg-open` works properly *by* escaping the cut.
- **Deny `xdg-open` (a bash denylist).** The tempting one-liner, and the
  losing side of the enumeration game that `PASSIVE_BINARIES` is deliberately
  the winning side of: `gio open`, `gdbus call`, `dbus-send`, `systemd-run
  --user`, `setsid librewolf URL`, five lines of Python on the bus socket are
  all the same channel. Worse, a partial denylist manufactures false comfort
  — "no deny hit ⇒ contained" is exactly the wrong lesson. Remove the
  authority, not the names.
- **Accept and document it** (the status quo, with the confirmer as the only
  guard). Rejected because the innocuous *look* of the trigger is the whole
  problem: a human who has read "bash here is network-severed" approves
  `xdg-open ~/report.png` on that understanding, and it is not true. Every
  such binary is non-passive today, so the human *does* see the command —
  which is necessary but too thin a thread to hang the gem's premise on.
- **Mask the rootful container sockets too** (`/run/docker.sock` &c., reusing
  `Bubblewrap::DENIED_CONTAINER_SOCKETS`; mechanically easy — `--ro-bind
  /dev/null <socket>` masks one cleanly). Rejected on the **error-signal**
  argument that already decided the real `/dev` and
  `D-permission-wall-handoff`: a user outside the `docker` group — the common
  case, and the reason rootless docker exists — gets an honest `EACCES` from
  the untouched socket, which tells the model *and* the human exactly what is
  true. Masking it trades that for a confusing `ENOENT`, and then both waste
  turns wondering where the daemon went. It would also cost `docker ps` as a
  diagnostic. For a user who *is* in the `docker` group the socket is a live
  root-equivalent escape — but that user holds root-equivalent power outside
  the agent anyway, and the guard there stays the confirmer (`docker` is
  non-passive, so it reaches the human).

**Consequences.**

- Lost, and worth stating plainly: `systemctl --user` (session-bus state
  queries), a *rootless* `docker`/`podman` socket, `ssh-add -l`, and audio
  tooling. Still fine, measured: `systemctl`/`hostnamectl`/`loginctl` on the
  system bus, `journalctl` (including `--user`, it reads files), `gsettings
  get` / `dconf read` (dconf reads the file; only *writes* need the bus),
  `ps`/`lsblk`/`smartctl` and every file read. The masked runtime dir is
  user-owned and writable, so a program wanting its own socket there still
  works.
- Residual paths out, all human-gated and none silent: the **system** bus
  stays bound (`systemctl status` needs it) — a transient unit there is
  polkit-gated and pops an *authentication dialog on the user's desktop*
  (observed; it is loud, and consistent with `D-no-agent-sudo`); **deferred
  execution** via a confirmed write (`~/.bashrc`, `~/.config/autostart/*`,
  `crontab`), which the write confirmer shows as a diff; and **rootful**
  container sockets, left visible on purpose so the denial is honest — see
  the rejected alternative above.
- The mask must stay *after* `--dev-bind / /` in the argv or the root bind
  covers it — invisible in review and silent under every other test, so
  there's an ordering assertion in the spec.
- `Bubblewrap` needs no change: it binds an allowlist that never included
  `/run/user`, so the coding agent never had the channel.

## D-no-agent-sudo — Privileged actions are a human hand-off, never agent-held root (2026-08-06)

**Status:** Accepted. Already the shipped behaviour on both legs (the
`EACCES` read hand-off of `D-permission-wall-handoff`, and
{Pikuri::Workspace::WriteGate}'s "sudo it yourself" short-circuit for an
unwritable write). The 2026-08-06 addition is one prompt clause splitting
*read* hand-offs (paste the output back) from *state-change* hand-offs
(say when it's done, the agent verifies itself).

**Context.** `pikuri-os` operates the real host but runs unprivileged, so
anything needing root — installing a package, editing `/etc`, restarting a
service — is out of reach. The recurring question is whether the agent
should ever *acquire* root, most concretely for package installation. Three
barriers stack up today, and it's worth keeping them straight:

- Inside either bwrap sandbox, `sudo` cannot work at all: `bwrap` sets
  `PR_SET_NO_NEW_PRIVS`, which neuters the setuid bit (`sudo: The "no new
  privileges" flag is set`). No sudoers or password arrangement gets around
  it.
- Under `FullFsNoNet` the network is severed too, so an install's download
  leg fails independently of privilege.
- Under `Bubblewrap` the target is also wrong: toolchain dirs are ephemeral
  overlays, so an install would vanish at session exit.

So installation is reachable only under `Sandbox::NONE` (`--no-sandbox` /
`--yolo`) — which for `pikuri-os` re-opens the network and reassembles the
trifecta the gem exists to break. The fork therefore isn't "sandbox or
not"; it's what the *host* does when root is genuinely required.

**Decision.** The agent never holds root. It advises: hand the human the
exact `sudo …` command with an explanation, and let them run it in their
own terminal. A downstream host (`pikuri-tui`, a web UI) must not add a
privilege-acquisition path either. This costs no new mechanism — the
hand-off is the shipped `EACCES` path, and the human's "done" is an
ordinary next user turn.

**Alternatives rejected.**

- **Agent-held sudo via `sudo -S` on stdin, or `SUDO_ASKPASS` / `sudo -A`.**
  Mechanically possible under `Sandbox::NONE`. Rejected because it
  **collapses the confirmation posture the file tools are built on**:
  {Pikuri::Workspace::WriteGate} short-circuits an unwritable write instead
  of prompting, and that is precisely why there is no sensitive-path
  denylist to maintain — "the files worth confirming are simply the ones
  you can actually write." Grant root and *every* file becomes writable,
  the argument evaporates, and the denylist we deliberately avoided has to
  be built. `D-permission-wall-handoff` rests on the same precondition:
  root turns its wall into a suggestion.
- **polkit / `run0` / `pkexec`** — the strongest form, since the auth prompt
  renders in the desktop's trusted UI and pikuri never touches the
  password. Rejected anyway: it solves password *handling* and leaves the
  posture problem untouched, still granting root to an LLM-authored command.
- **A per-install password prompt** ("just ask each time"). Rejected: with
  `--new-session`, sudo's timestamp cache is per-tty, so the password is
  re-fed on every call — making it a **standing root capability** for the
  session rather than one authorized act, which is
  `ideas/bash-confirmer.md` §"The danger" at maximum privilege. A web UI is
  strictly worse: password over a transport, held server-side, no local
  trusted tty.

**Consequences.**

- **The two hand-off legs are asymmetric, and the prompt now says so.** A
  privileged *read* needs its output pasted back; a privileged *change*
  does not — verification is available to the agent locally, needing
  neither root nor network (`dpkg -l`, `apt-cache policy`, and friends are
  already in the passive allowlist, so it self-verifies without even a
  confirmation prompt). Observed on a live 2026-08-06 "install openjdk-21"
  run: the model handed back the correct `sudo apt-get install …` from the
  grounding block's `Packaging:` fact, then asked for apt's progress bars
  to be pasted back. That misfire is what the clause fixes.
- **Probing with a doomed command first is fine.** The same run spent two
  steps discovering the dpkg lock was unwritable before escalating. Left
  as-is deliberately: it's the honest-`EACCES` path working, and the
  opposite of `D-permission-wall-handoff`'s open caveat (escalating *too*
  fast, before gathering the partial picture).
- **Package availability works offline.** apt's package lists are local, so
  `apt-cache policy` names the exact candidate version with the network
  severed. The agent can confirm a package exists and what it would install
  before handing off — the network barrier never fires on that leg.
- **This closes the "package installation" item** that sat in
  `ideas/pikuri-os.md`'s deferred list as "post-v1". It is not deferred
  work; it is declined by posture, and the hand-off already ships.

---

## D-context-window-sources — The `/props` probe, never ruby_llm's model registry (2026-08-04)

**Status:** Accepted; the behaviour has always shipped this way
({Pikuri::Agent::ContextWindowDetector}). Logged 2026-08-04 when the
argument moved out of that class's yardoc.

**Context.** A context-window cap is only worth emitting if a host can *act*
on it — warn, compact, or switch models before
`RubyLLM::ContextLengthExceededError`. So the number has to be trustworthy
without a caveat attached.

**Decision.** Two sources only: llama.cpp's non-standard `/props` probe (the
server's *launched* `n_ctx`, i.e. the real window) and an explicit
{Pikuri::Agent::ChatTransport#context_window}. Anything else resolves to
`nil` — an honest "we don't know."

**Alternatives rejected.**

- **`RubyLLM::Model::Info#context_window`** (the obvious source, and free) —
  it's a static `models.json` lookup, so it returns `nil` for every
  `assume_exists` local id, `nil` for anything past the snapshot, and —
  worst — a **frozen** value for models it *does* know: a window bumped
  256k → 1M still reports the old number. A cap you must caveat defeats its
  only job, and a confidently-wrong number is worse than `nil`. Not
  consulted at all, rather than consulted as a last resort, because a
  fallback that lies is indistinguishable from one that works until it
  silently truncates.

**Consequences.** Non-llama.cpp servers get no cap unless the host passes
`context_window:` on the transport — deliberate, and why the detector's
failure path is a debug log rather than a raise.

---

## D-permission-wall-handoff — An honest `EACCES` beats prompt guidance (2026-07-18)

**Status:** Accepted; the read-vs-mutate sub-bullets were removed in
`f917226`. Validated live 2026-07-18 ("Is my SSD healthy?").

**Context.** `pikuri-os` runs unprivileged inside a bwrap user namespace
where `sudo` doesn't work, so anything genuinely needing root must be handed
to the human. The question was how much of that escalation *strategy* the
system prompt has to spell out.

**Decision.** One line in `prompts/os-assistant.txt` states the hand-off (a
`Permission denied` means the real answer needs root → give the exact
`sudo …` command, explain it, ask for the output pasted back). No
elaboration beyond that. On the live test the model ran the probe, read
"Permission denied", recognized root was required, and handed back exact
`sudo nvme smart-log` / `sudo smartctl -a` with an explanation and a
paste-back ask — unprompted, and reaching for the NVMe-specific tool first.

**Alternatives rejected.**

- **Read-vs-mutate escalation sub-bullets in the prompt** — they existed and
  were trimmed as dead weight once the behaviour proved emergent.
  **Don't re-add them thinking they're load-bearing.** Prompt text is not
  free: every line competes for attention with the ones that *are* doing
  work, and this one was buying behaviour the model already had.

**Consequences.**

- **The precondition is the load-bearing half, and it's in the sandbox, not
  the prompt.** This only works because `FullFsNoNet` binds the *real*
  `/dev`. The earlier synthetic `--dev /dev` hid block-device nodes, so
  `smartctl` failed `ENOENT` ("No such device") while `lsblk` / `/sys`
  showed a healthy disk — an incoherent machine, and the model retry-looped
  instead of escalating. A prompt cannot fix an environment that lies. See
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet} + `pikuri-code/DESIGN.md`.
- **Open caveat.** The model escalated *straight* to `sudo` without first
  gathering the partial non-root picture. Fine when root is genuinely
  required (SMART data is), but on a case with real partial value (a
  root-only log where `/sys` gives half the story) the leaner prompt may
  leave that on the table. Watch for it before calling a "gather partial
  first" nudge permanently unnecessary.

---

## D-fake-transport — Fake the HTTP backend, not the agent (2026-07-18)

**Status:** Accepted; shipped for single-agent 2026-07-17
({Pikuri::Testing}), export boundary settled 2026-07-18. Graduated from
`ideas/fake-llm.md`.

**Context.** Unit-testing agent behaviour needs no server and no network,
but mocking the *agent* tests nothing — the value is in the real `run_loop`,
real listeners, real tools/extensions, real `Event` stream, real ruby_llm
loop.

**Decision.** A fake is a plain {Pikuri::Agent::ChatTransport} carrying an
anonymous `Faraday::Adapter` (a generic `faraday_adapter:` field, no
subclass), installed on the agent's *per-chat* `RubyLLM::Context` so the
global `RubyLLM.config` is untouched. Only `fake_transport` is exported.
Mechanics + limitations: {Pikuri::Testing}.

**Alternatives rejected.**

- **A fake backend that reimplements the ruby_llm loop** — it would drift
  against every ruby_llm upgrade, and the whole point is that the *real*
  loop parses the tool calls and invokes the real registered tools.
- **The two-phase `new` / `configure` split** — splitting `Agent.new` (pure)
  from a public `Agent#configure` (block + network) to make offline
  construction testable. Tried, then **reverted: it bought nothing.**
  pikuri-tui's stubs fake `run_loop` (turn *execution*), not construction,
  and pikuri-core already tests real agents by faking the backend — which
  needs no construction change and works with the existing ctor block. The
  lever was always the backend seam. **Don't re-open the two-phase split as
  a testing enabler.**
- **Exporting the white-box `fake_chat`** — the callback-capture stub that
  `agent_spec` (and the mcp / skills / subagents specs) hand-roll, which
  fires individual chat callbacks by hand and inspects chat internals. It
  tests pikuri's own `Agent` ↔ `RubyLLM::Chat` adapter seam — an *internal*
  contract. No downstream consumer ever pokes that wiring (they test their
  own tools/listeners/extensions, which is `fake_transport`'s job), so
  exporting it would ship a helper no external caller can use and leak the
  internal adapter contract into the public API.

**Consequences.**

- The white-box fake stays test-internal, per gem, and its ~5×
  duplication is an **accepted** internal DRY smell: the copies genuinely
  diverge, cross-gem spec-support sharing is awkward, and the real-loop
  coverage those callback tests approximate is carried end-to-end by
  `pikuri-core/spec/pikuri/testing_spec.rb`.
- Most of `agent_spec` can't move to `fake_transport` without losing
  coverage — you can't fire a lone `after_tool_result`, or read
  `model_switches`, off a real chat.

---

## D-per-process-temp — Two named `Paths` methods, not `cache(session:)` (2026-07-14)

**Status:** Accepted; implemented 2026-07-14 (`Paths.new_temp` +
`Paths.sweep_stale_temps!`). Graduated from `ideas/session-scoped-store.md`,
now retired.

**Context.** Two concurrent `pikuri-thunderbird` processes shared a *fixed*
snapshot path (`~/.cache/pikuri/thunderbird/{mail,calendar}/`), so they
clobbered each other's SQLite copies — and one process's clean-exit `rm_rf`
(a `Snapshot` finalizer) deleted the copy the other was mid-query on. The
root cause was **discoverability**, not the path: `Paths` was invisible, so
the implementer re-derived `XDG_CACHE_HOME` inline and landed on a shared,
persistent directory without ever meeting the per-process concept. Any fix
had to make the shared-vs-private choice unmissable at the call site.

**Decision.** Split the concept into two *named* methods with distinct
semantics — `Paths.cache` (shared across all pikuri processes, persistent)
and `Paths.new_temp` (private to this process, ephemeral, finalizer-reaped,
stale-swept at core load). Per-symbol mechanics and their full why —
in-home rather than `/tmp`, factory rather than memoized accessor, the
reap/sweep contract — live in {Pikuri::Paths.new_temp} /
{Pikuri::Paths.sweep_stale_temps!}. The invariant ("cache & temp paths go
through `Paths`") plus its `ENV['XDG_CACHE_HOME']` grep tripwire live in
CLAUDE.md *Conventions*.

**Alternatives rejected.**

- **`Paths.cache(session: :shared | :current)`** — a required kwarg
  *forcing* the decision at the signature. Genuinely attractive: great
  discoverability, and pikuri-shaped like `StepLimit.new(on_exhausted:)`.
  **Killed** because the enum is secretly a 2×2 matrix — *shared-vs-private*
  × *persistent-vs-nuked* — crammed onto one axis: `:shared` implies
  persistent, `:current` implies nuked, and **there is no cell for a
  persistent per-process session**. The moment that cell is wanted, the enum
  breaks. Two named methods don't share an axis, so the same future need
  becomes a *third named method* instead of a broken enum value. It also
  invented an on-disk `sessions/<id>/…` tree the two-method design never
  needed.
- **Keeping the mint on `Workspace::Filesystem`** (`mint_internal_temp` /
  `sweep_stale_internal_temps!`) — rejected: the concept isn't
  workspace-shaped, and the stale sweep ran at *workspace* gem load, so a
  binary that wires no workspace never swept. Both were deleted;
  `Filesystem#internal_temp` now memoizes `Paths.new_temp`, and the sweep
  moved to *core* load with a generic `temp-*` prefix, so every binary
  sweeps.

**Consequences.**

- **A persistent per-process session is deliberately not built.** If the
  need appears (scratch that survives a process's own restart yet stays
  private), it is a *third* named `Paths` method — the two-method split
  leaves room without reopening the rejected enum.
- **Stale-sweep liveness is a known latent hazard** (pre-existing —
  inherited from the workspace design, not created here). The sweep is
  mtime-cutoff based (`Paths::TEMP_STALE_SECONDS`, 7 days), so a process
  outliving the cutoff whose temp-dir mtime never gets bumped could have a
  *live* dir reaped by a newly-starting process's core-load sweep. A pidfile
  + `Process.kill(0, pid)` liveness probe would fix it but is PID-recycle-
  fragile. Deferred — revisit if it actually bites.
- `new_temp` registers one block-form reap per mint at its ownership
  boundary, under the single `at_exit` of the *Finalizers / teardown seam* —
  no second `at_exit`.
- Thunderbird's `Extension` now takes `cache_dir` with `nil` meaning "mint a
  fresh per-process dir," which is what closed the original collision.

**Related.** [`ideas/thunderbird.md`](ideas/thunderbird.md) — where the
collision surfaced; its Q11 (concurrency) covered the *live-DB* race, not
this *snapshot-destination* race between two pikuri processes.
