# Prerequisites

This chapter is the one-time machine setup: Ruby, the pikuri
checkout, and a Docker daemon that doesn't hand root to everything
running under your account. Each later chapter installs its own
*subject matter* when it first appears (llama.cpp and the models
are the first-conversation chapter's job), but these three are boring enough to
front-load — and the Docker section contains a security decision
that deserves more than a parenthetical in a later chapter.

In a hurry? The [first-conversation](chat.md) and
[sub-agents](subagents.md) chapters need
only Ruby and the checkout. Docker first earns its keep in
[the vector-DB chapter](vectordb.md) (persisting the vector index) and
becomes load-bearing in the [memories](memories.md),
[MCP](mcp.md), and [MCP-revisited](mcp-revisited.md) chapters — skipping the
Docker section now and coming back at the vector-DB chapter is a perfectly
fine reading order.

## The platform

Linux. **Ubuntu 26.04 LTS or newer** makes every package command
in this guide literal (the first-conversation chapter needs its `llama.cpp` build
anyway); another Debian derivative is one step removed; other
distros mean adapting the `apt` lines yourself. macOS may work but
isn't tested; Windows is unsupported.

## Ruby and the checkout

Pikuri needs Ruby ≥ 3.3 plus Bundler, and runs in dev mode
straight from a git checkout — no gem install:

```sh
sudo apt install ruby ruby-bundler git
git clone https://codeberg.org/mvysny/pikuri.git
cd pikuri
bundle install
```

Every demo binary self-bootstraps Bundler, so you run them
directly (`./pikuri-core/bin/pikuri-chat "Hello"`) — no
`bundle exec` prefix.

## Docker — rootless, not the docker group

### Meet Docker (the sixty-second version)

A **container** runs a program in its own little world: its own
filesystem, its own process table, its own view of the network,
all walled off from your real machine unless you explicitly punch
a hole. The program inside thinks it has a whole Linux box; in
reality it can't see your files, your other processes, or your
keys. It's the same idea as the bubblewrap sandbox the coding
agent uses ([the coding-agent chapter](code.md)), packaged as a widely-used,
batteries-included tool. Docker is everywhere — most server
software ships as a Docker image now — so it's worth having
installed regardless.

That's the whole mental model you need for now. The deeper
material — what isolation Docker does and doesn't give you,
ephemeral overlays, the container-socket footgun — is
[the MCP-revisited chapter](mcp-revisited.md). For now: it's a box, the
program runs in the box, the box can't see your stuff.

The guide leans on that box from the vector-DB chapter on: that
chapter keeps your vector index in a Qdrant container, the
memories chapter runs the mem0 memory store as a small compose
stack, and the two MCP chapters use a container as the wall
between pikuri and MCP-server code you didn't write. All of it just needs a working `docker` on
`PATH` — pikuri doesn't care how the daemon behind it runs. But
*you* should.

The setup you'll find in most tutorials is:

```sh
sudo apt install docker.io
sudo usermod -aG docker "$USER"      # ← DON'T DO THIS!!!
```

That second line is **passwordless root**. The default Docker
daemon runs as root, and the `docker` group is nothing more than
permission to talk to it — so anything running as your user can
ask the root daemon for the keys:

```sh
docker run --rm -v /:/host debian cat /host/etc/shadow
```

No exploit, no CVE — that's the daemon working as designed. A
malicious npm postinstall script, a compromised pip package, one
bad `curl | bash` — anything that runs as you inherits the group,
and "my user account got compromised" silently upgrades to "root
got compromised". For a project whose whole pitch is that your
data stays on a machine you control, wiring that in as step zero
would be absurd.

**Rootless Docker** is the fix: the daemon itself runs as your
user inside a user namespace, so a container — or anything that
talks to the docker socket — can reach at most what your account
can already reach. Same `docker` CLI, same images, same compose
files; every container in this guide runs identically on it.

On Ubuntu 26.04 with the distro package:

```sh
sudo apt install docker.io docker-compose-v2 rootlesskit slirp4netns uidmap socat
# don't run the system-wide root daemon at all — we won't use it
sudo systemctl disable --now docker.service docker.socket

# set up the per-user daemon (the script ships with docker.io)
/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh install

# point the docker CLI at your user's daemon socket, persistently
docker context create rootless --docker "host=unix:///run/user/$(id -u)/docker.sock"
docker context use rootless
```

The setup tool starts a per-user daemon under your systemd
(`systemctl --user status docker`); the context points the
`docker` CLI at it in every future shell. (A stray `DOCKER_HOST`
environment variable overrides the context — unset it if you had
one.) If anything balks — a leftover `docker` group membership
from an earlier install, a missing subuid range, a distro that
ships the setup script elsewhere — the long-form walkthrough with
troubleshooting is
[*Rootless Docker*](https://mvysny.github.io/docker-rootless/).

Verify, in a fresh shell:

```sh
docker run --rm hello-world
docker info --format '{{.SecurityOptions}}'   # should include name=rootless
```

Two rootless quirks worth knowing about up front:

- **Containers can't dial the host's loopback.** Rootless
  networking deliberately blocks containers from reaching services
  bound to the host's `127.0.0.1` (the network stack runs with
  `--disable-host-loopback`) — services that assume "local caller
  = trusted caller" stay out of containers' reach. The first-conversation chapter's
  `llama-server` binds `127.0.0.1:8080`, and the memories chapter runs a
  container that must call it. That's what the `socat` in the apt
  line above is for: pikuri uses it to relay *one specific host
  service* to *the specific trusted containers that need it* over
  a unix socket file, leaving the loopback sealed for every other
  container — [the memories chapter](memories.md) shows the mechanism. The
  other direction is unaffected: ports a container publishes, like
  Qdrant's `127.0.0.1:6333`, are reachable from the host as usual.
- **Logging out stops your user's systemd services**, the rootless
  daemon included. Irrelevant for pikuri's interactive demos — the
  supervisors start and stop their containers with the agent — but
  if you ever want a container to outlive your session, run
  `sudo loginctl enable-linger "$USER"` once.

Already running the rootful daemon with the `docker` group and not
inclined to redo it? Everything in the guide still works — pikuri
talks to whatever `docker` on `PATH` talks to. The rootless choice
protects *you*, not pikuri; reread the `usermod` paragraph above
and make it deliberately.

## What you deliberately don't need

No API key, no cloud account, no GPU-vendor SDK sign-up. The model
runs on your own hardware and the conversation never leaves your
machine — making that real is [the first-conversation chapter](chat.md)'s job, and
the natural next page.
