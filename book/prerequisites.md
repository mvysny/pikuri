# Prerequisites

This chapter is the one-time machine setup: Ruby, the pikuri
checkout, and a container runtime that doesn't hand root to
everything running under your account. Each later chapter installs
its own *subject matter* when it first appears (llama.cpp and the
models are the first-conversation chapter's job), but these three
are boring enough to front-load — and the container section
contains a security decision that deserves more than a
parenthetical in a later chapter.

In a hurry? Everything up to [the vector-DB chapter](vectordb.md)
needs only Ruby and the checkout. Containers first earn their keep
there (persisting the vector index), and [the secretary](secretary.md)
at the end of the book needs one for the same reason — skipping the
container section now and coming back at the vector-DB chapter is a
perfectly fine reading order.

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
git clone https://github.com/mvysny/pikuri.git
cd pikuri
bundle install
```

Every demo binary self-bootstraps Bundler, so you run them
directly (`./pikuri-core/bin/pikuri-chat "Hello"`) — no
`bundle exec` prefix.

## Containers: Podman, or rootless Docker

### Meet containers (the sixty-second version)

A **container** runs a program in its own little world: its own
filesystem, its own process table, its own view of the network,
all walled off from your real machine unless you explicitly punch
a hole. The program inside thinks it has a whole Linux box; in
reality it can't see your files, your other processes, or your
keys. Most server software ships as a container image now, so it's
worth having a runtime installed regardless.

That's the whole mental model you need. For now: it's a box, the
program runs in the box, the box can't see your stuff.

The guide leans on that box from the vector-DB chapter on: that
chapter, and the secretary after it, keep your vector index in a
Qdrant container. pikuri starts and stops it for you, with `podman`
when it's on your `PATH` and `docker` otherwise. It doesn't care how
the runtime behind that command runs. But *you* should.

### Podman: the short path

```sh
sudo apt install podman
```

That's it. Podman runs containers as *your* user, with no daemon and
no root anywhere in the chain, so a container — or anything that can
start one — reaches at most what your account can already reach.
Same images as Docker, mostly the same command line. Verify:

```sh
podman run --rm docker.io/library/hello-world
```

### Docker, if you already have it

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

If you want Docker anyway, run it **rootless**: the daemon itself
runs as your user inside a user namespace, with the same reach
Podman has. On Ubuntu 26.04 with the distro package:

```sh
sudo apt install docker.io docker-compose-v2 rootlesskit slirp4netns uidmap
# don't run the system-wide root daemon at all — we won't use it
sudo systemctl disable --now docker.service docker.socket

# set up the per-user daemon (the script ships with docker.io)
/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh install

# point the docker CLI at your user's daemon socket, persistently
docker context create rootless --docker "host=unix:///run/user/$(id -u)/docker.sock"
docker context use rootless
```

Then, in a fresh shell, `docker info --format '{{.SecurityOptions}}'`
should include `name=rootless`. (A stray `DOCKER_HOST` environment
variable overrides the context — unset it if you had one.) If
anything balks, the long-form walkthrough with troubleshooting is
[*Rootless Docker*](https://mvysny.github.io/docker-rootless/).
Logging out stops your user's services, the rootless daemon
included; that's irrelevant here, since pikuri starts and stops its
containers with the agent.

Already running the rootful daemon with the `docker` group and not
inclined to redo it? Everything in the guide still works — pikuri
talks to whatever `docker` on `PATH` talks to, when there's no
`podman`. The rootless choice protects *you*, not pikuri; reread the
`usermod` paragraph above and make it deliberately.

## What you deliberately don't need

No API key, no cloud account, no GPU-vendor SDK sign-up. The model
runs on your own hardware and the conversation never leaves your
machine — making that real is [the first-conversation chapter](chat.md)'s job, and
the natural next page.
