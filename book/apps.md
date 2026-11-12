# Apps built on pikuri

> **The book's coda.** The guide ends where pikuri's solid ground
> ends. What an assistant should look like is still being worked out
> by apps that build on these gems, not by this repo.

Every agent in this book holds at most two of the trifecta's three
legs. The OS assistant ([the OS-assistant chapter](os-assistant.md))
keeps the disk and severs the network; the coding agent
([the coding-agent chapter](code.md)) keeps the network and confines
the disk. An everyday assistant wants all three at once: it remembers
things about you, reads your mail, which anyone can write to, and
looks things up on the web. Where to cut, and whether it is still
useful once it's cut, isn't a question a library can answer up front.
Only an app people actually use can answer it.

So pikuri ships what has a solid use case and works, and leaves the
exploration to the apps below. When a piece proves itself in one of
them, it moves back into a gem.

## pikuri-tui

[pikuri-tui](https://codeberg.org/mvysny/pikuri-tui) is a set of
terminal front-ends:

- **`pikuri-tui-chat`**: a general-purpose chat with web search and the
  calculator, the TUI version of `pikuri-chat`.
- **`pikuri-tui-code`**: the in-repo coding agent from
  [the coding-agent chapter](code.md), plus a git diff view and plan
  mode.
- **`pikuri-tui-computer`**: a desktop assistant for your machine. It
  has the OS helper from [the OS-assistant chapter](os-assistant.md),
  your Thunderbird mail and calendar, and web research kept behind an
  isolated sub-agent.

Read it for a full wiring with a real UI: one config file naming
several models you switch between at runtime, a log pane beside the
conversation, and a confirmer that asks inside the UI instead of on
stdin.

## pikuri-web

[pikuri-web](https://codeberg.org/mvysny/pikuri-web) is the browser
version of the same chat: a Sinatra page that streams the conversation
over SSE. It is the host [the hosting chapter](hosting.md) was written
from, with many conversations in one process plus the background jobs
that title them. (Don't confuse it with the `pikuri-web` *gem* that
ships the web tools; the app uses that gem.)

## Puri

[Puri](https://github.com/mvysny/puri) is a Siri-style desktop
assistant for GNOME. A global shortcut opens a search bar, and the bar
grows into a conversation. Its trifecta cut is the interesting part.
It is meant to search the web but never open a URL, so the only way
out is the vouched search (`web_search` with page text served from the
engine's own index), next to notes, reminders, calendar and mail. Its
`design/ideas/` folder is where the questions this book leaves open are
being worked through. One example is a *federation*: several agents,
with you passing text between them.

## What's next

This is the end of the guide. You now have the vocabulary to read
any pikuri-\* gem's sources and any of the apps above: `Pikuri::Agent`,
`Tool`, listeners, the Extension protocol, configure/bind, sub-agent
privilege separation, the kit from [the security chapter](security.md),
and MCP's verifier, synthesizer and per-agent `mcp_connect`.
