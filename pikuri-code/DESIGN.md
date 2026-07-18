# pikuri-code — design & threat model

Audience: someone extending pikuri-code or auditing its sandbox
posture. The per-class contracts — the exact bind set, the `@raise`
conditions, the wrapped-argv shape — live in the YARD headers
({Pikuri::Code::Bash::Sandbox}, {Pikuri::Code::Bash::Sandbox::Bubblewrap},
{Pikuri::Code::Bash::Sandbox::FullFsNoNet}). This file carries the
cross-cutting *why* those headers otherwise swell with: the two-sandbox
design, each one's threat model, and the invariants that span
{Pikuri::Code::Bash} + {Pikuri::Workspace::Filesystem} +
{Pikuri::Code::ToolchainPaths} at once. In-flight notes and still-open
questions live in [`../ideas/coding-agent.md`](../ideas/coding-agent.md).

The must-not-break half is already in [`../CLAUDE.md`](../CLAUDE.md)'s
**Sandbox seam** and **Workspace seam**; this file is the reasoning
*behind* those one-liners, not a second copy of them.

## Two sandboxes, opposite postures

{Pikuri::Code::Bash} runs every command through a `Sandbox#wrap(argv)`.
Three implementations, but only two real postures — `NONE` is the
identity passthrough (the `Bash.new` default and the `--no-sandbox`
opt-out); the other two are deliberate inverses:

| | {Bubblewrap} | {FullFsNoNet} |
|---|---|---|
| Filesystem | curated subset (project + toolchain + `/etc` baseline) | the whole real root, read-write |
| Network | **kept** (`--share-net`) | **severed** (`--unshare-net`) |
| PID / IPC / UTS | unshared (`--unshare-all`) | kept shared |
| Written for | the in-repo coding agent (`bin/pikuri-code`) | the offline OS helper (`bin/pikuri-os`) |
| On probe failure | degrades (overlay → `--ro-bind`) | **raises** — the severed net *is* the property |

Bubblewrap contains the filesystem and trusts the network; FullFsNoNet
trusts the filesystem and severs the network. Which is right follows
from what the agent's job must touch: a coding agent must
`git pull` / `mvn` / `curl` (network essential, containment cheap); an
OS helper must inspect the real host (filesystem essential, egress is
the whole risk). The class lives in pikuri-code because it's a `Bash`
sandbox; its *user* is pikuri-os (see that gem's DESIGN and book ch7).

### Sandbox is not Workspace

Two overlapping-but-distinct objects govern what bash can touch, and
keeping them separate is deliberate:

- **{Pikuri::Workspace::Workspace}** is *what the LLM observes* through
  the `Read` / `Write` / `Edit` / `Grep` / `Glob` tools, which run
  in-process as the real user.
- **Sandbox** is *what the executed bash subprocess sees*.

They overlap on project + toolchain dirs but diverge on the OS-runtime
baseline ({Bubblewrap}'s `ETC_BASELINE` — TLS certs, DNS, tz, hosts):
the LLM has no business `Read`-ing `/etc/resolv.conf`, but the `curl`
subprocess needs it. Separate objects keep each allowlist with its
rightful owner rather than fusing two different questions into one list.

## Bubblewrap: blast-radius containment, not a malware boundary

Bubblewrap composes a `bwrap` argv from the {Pikuri::Workspace::Filesystem}
plus a curated OS-runtime baseline, so the bash subprocess sees only
project + toolchain + ephemeral temp + the handful of `/etc` files
needed for a TLS/DNS/tz/hostname handshake. The exact bind list is in
the class YARD; the *design points* worth stating once:

### The toolchain overlay

`workspace.readable` dirs (the toolchain caches from
{Pikuri::Code::ToolchainPaths}) are mounted as **read-write ephemeral
overlays**: the host dir is the read-through lower, a per-session upper
under `<internal_temp>/overlay-<slug>/` absorbs writes. So
`gem install` / `bundle` / `mvn` / `gradle` / `cargo` / `pip` succeed
against `/usr`, `~/.rbenv`, `~/.gradle/caches`, … while the host's real
toolchain stays untouched. Writes survive across bash calls within one
session (a warm cache — the upper is a persistent dir re-mounted each
call, not a tmpfs that dies with the `bwrap` process) but never across
sessions, so a poisoned session can't propagate into the host's normal
`gradle` or a future run.

Why the mounts are *narrow* subdirs (`~/.gradle/caches`, not
`~/.gradle`) — so `gradle.properties` / `init.d` / `.credentials` never
reach the sandbox — is owned by {Pikuri::Code::ToolchainPaths}: because
the lower is the host's real file, it's the narrow *mount*, not the
write's ephemerality, that keeps secrets out of the sandbox's view.

### What the overlay does NOT defend

Blast-radius containment for the subprocess, **not** a malware boundary.
Prompt injection reaching the LLM can still:

- modify project source under `project_root` (the LLM legitimately needs
  `Write` there);
- inject a malicious dependency the next build executes;
- exfiltrate over the network — `--share-net` is intentional so
  `git pull` / `mvn` / `curl` work.

The overlay specifically prevents *cross-project* contamination via
shared `$HOME` caches — nothing more. Users needing adversarial
isolation run pikuri-code inside a container: the container is the outer
boundary, `bwrap` the inner. (The `Filesystem::AllowAll` note in
CLAUDE.md's Workspace seam is the file-tool-side counterpart.)

### Concurrency: one umbrella, serialized bwrap

Each `Bubblewrap` instance must own its overlay upper/workdir
exclusively — overlayfs returns `EBUSY` on a shared upper. The bundled
wiring guarantees it: one {Pikuri::Workspace::Filesystem} mints one
umbrella ({Pikuri::Workspace::Filesystem}`#internal_temp`) feeding one
`Bubblewrap`, and `Bash` runs `bash -c` synchronously
({Pikuri::Subprocess}`#wait`) while sub-agents block their parent's
loop — so two `bwrap` invocations from one pikuri process never overlap
in time. Two pikuri-code *processes* are independent (each its own
umbrella; the shared read-only lower may be shared across mounts per
kernel docs). A downstream host that reused one `Bubblewrap` across
parallel bash tasks would collide on its own `EBUSY`; pikuri's own
wiring never does.

## FullFsNoNet: sever the egress, not the filesystem

The inverse of Bubblewrap: `--bind / /` binds the entire real root
read-write, and *only* the network is unshared (`--unshare-net`). This
is the sandbox for the offline OS helper (`bin/pikuri-os`). That agent's
job is to operate the real host, so filesystem *containment* is the
wrong tool — there is deliberately no fs sandbox. The one isolation that
matters is egress: with the network namespace unshared, an injection in
a file the agent reads has nowhere to exfiltrate to. **The trifecta's
egress leg is cut by the kernel, not by a prompt** — the load-bearing
invariant of the OS-helper design.

Running unprivileged, `bwrap`'s user namespace maps the caller's uid to
itself, so root-owned files (`/etc/*`, another user's `$HOME`) appear
owned by an unmapped id and are *not* writable (and `/etc/shadow` stays
unreadable) — matching the OS helper's "advise, don't execute anything
privileged" rule: privileged edits need `sudo`, unavailable in the
namespace, so they route to the human.

### Why the real /dev, not bwrap's synthetic --dev

FullFsNoNet binds `--bind /dev /dev` (the real device tree) where
Bubblewrap uses a synthetic `--dev` (null/zero/random/tty only). It's
redundant with `--bind / /` but stated explicitly so it survives someone
narrowing the root bind — and the reason is an **error-signal**
argument, not access:

A synthetic `/dev` omits the block-device nodes (`/dev/nvme0n1`,
`/dev/sda`). With them missing, `smartctl -a /dev/nvme0n1` fails
`ENOENT` ("No such device") while `lsblk` / `/sys` still show a healthy
disk — an incoherent machine the model can't reason about, so it
retry-loops instead of escalating. With the real node present the
unprivileged open fails `EACCES` ("Permission denied"), the honest error
that says "escalate" — and here escalation *is* the answer: `sudo` is
unavailable in the namespace, so a privileged read becomes advice to the
human, matching the "advise, don't execute privileged" rule.

This is not a security regression: the root is already bound read-write,
so the synthetic `/dev` was hiding nothing an attacker couldn't
otherwise reach — it only mangled the error. (Regression-guarded by the
`refute_includes argv, '--dev'` assertion in the sandbox spec.)

Note the PID namespace is *not* unshared, unlike Bubblewrap's
`--unshare-all`: an OS helper must see and reason about host processes
and services, so `--proc /proc` over the bound root still shows them —
essential for `ps` / `top` / `systemctl status`. Unsharing PID would
blind them.

### No fallback if the network can't be severed

If `bwrap` is missing, or the kernel forbids unprivileged user / network
namespaces, the constructor **raises** — it does NOT degrade to a
networked sandbox (the opposite of Bubblewrap's overlay probe, which
logs and falls back). Here the severed network *is* the security
property, so a silent networked run would void the no-egress invariant.
A host that can't unshare the network must fix the kernel setting (e.g.
`kernel.unprivileged_userns_clone`) or not run this agent there.

### What FullFsNoNet does NOT defend

`--bind / /` exposes everything, including container/VM control sockets.
Unsharing the *bash process's own* network namespace does not constrain
a container the agent asks the *host daemon* to spawn — a confirmed
`docker run --network=host` would have full connectivity. So this is not
a malware boundary; it severs the agent's own egress, and the guard
against socket abuse is the confirmer (`docker` / `nc` / `curl` are
mutating and non-allowlisted, so they reach the human). A hard boundary
means running the whole agent inside a container / VM.

## Construction-time probing (loud, not on first tool call)

Both sandboxes probe `bwrap` in their constructor, so a misconfigured
host fails at boot rather than mid-conversation. The two probes differ
in exactly the way the postures differ, and that difference is
load-bearing:

- **Bubblewrap** probes with `--share-net` (its runtime posture), then —
  only when a `readable` dir would actually be overlaid — runs a *second*
  overlay probe that **degrades** to `--ro-bind` on a warning if
  overlayfs-in-userns is unavailable (Linux < 5.11).
- **FullFsNoNet** probes with `--unshare-net`, because a kernel that
  forbids unprivileged net namespaces must fail *here*, loudly. Probing
  with `--share-net` would let a host pass the check and then be unable
  to sever the network at runtime — silently voiding the whole point.

So the probes are not interchangeable: the flag under test is precisely
the property each sandbox promises. A shared probe helper would have to
be parameterized by that flag (and by raise-vs-degrade) rather than
unified away.
