# Prerequisites

This chapter is the one-time machine setup: Ruby, the pikuri
checkout, and the desktop file index the recall chapter searches.
Each later chapter installs its own *subject matter* when it first
appears (llama.cpp and the models are the first-conversation
chapter's job), but these are boring enough to front-load.

In a hurry? Everything up to [the recall chapter](recall.md) needs
only Ruby and the checkout. The file index matters from there on,
for the briefing agent and for [the secretary](secretary.md) at the
end of the book, and on an Ubuntu desktop you already have it.

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

## A desktop file index

The recall chapter's agents search your files through the index your
desktop already keeps, rather than one pikuri builds. One of these:

- **Ubuntu 26.04 LTS or newer, on its GNOME desktop.** GNOME's
  localsearch is already running and already indexing your home
  folder. Add one package so it reads office documents too:

  ```sh
  sudo apt install localsearch-extractor-office
  ```

  Without it, `.docx`, `.odt`, `.xlsx` and epub files are found by
  name only. Files indexed before you install it stay that way, even
  after a restart
  ([a localsearch bug](https://gitlab.gnome.org/GNOME/localsearch/-/work_items/476)),
  so rebuild the index once afterwards:

  ```sh
  localsearch reset
  ```

  It asks before erasing the index, then localsearch reads your home
  folder again from scratch, office text included. That can take a
  while; `localsearch status` says "Data is still being indexed" until
  it's done.
- **Any Linux with localsearch 3.8 or newer** and its `tinysparql`
  command, which Debian and Ubuntu's `localsearch` package pulls in.
  The older Tracker 3 (Ubuntu 24.04 LTS and earlier) isn't supported.
- **recoll, anywhere**: KDE, Xfce, a headless box. It indexes only the
  folders you configure, and only when you tell it to:

  ```sh
  sudo apt install recollcmd
  recollindex           # build the index once
  recollindex -m        # or keep it fresh as files change
  ```

Whichever you have, pikuri only reads it: it never builds, configures
or refreshes an index. And the index reaching your whole home folder
doesn't mean an agent does: every binary names the folders it may
search, and the recall chapter says why that limit is the security
boundary.

## What you deliberately don't need

No API key, no cloud account, no GPU-vendor SDK sign-up, no
container runtime. (Containers come in
[book 2](https://github.com/mvysny/pikuri-workshop/blob/master/book/containers.md),
whose chapters are the first to need one.) The model runs on your own
hardware and the conversation never leaves your
machine — making that real is [the first-conversation chapter](chat.md)'s job, and
the natural next page.
