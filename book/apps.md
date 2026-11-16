# Apps built on pikuri

> **The book's coda.** The guide ends where pikuri's solid ground
> ends. What an assistant should look like is still being worked out
> by apps that build on these gems, not by this repo.

The book ended on [the secretary](secretary.md): an assistant that
holds all three of the trifecta's legs on purpose, in a plain command
line, giving up every comfort for code you can read in an evening.
An assistant you'd use every day wants the comforts back — a window
you summon with a shortcut, answers that stream in, a history of past
conversations, reminders that fire when you aren't looking. How much
of that fits without weakening the cuts the secretary made isn't a
question a library can answer up front. Only an app people actually
use can answer it.

So pikuri ships what has a solid use case and works, and leaves the
exploration to the apps below. When a piece proves itself in one of
them, it moves back into a gem.

## Puri

[Puri](https://github.com/mvysny/puri) is the secretary with all the
bells and whistles: a Siri-style desktop assistant for GNOME. A global
shortcut opens a search bar, and the bar grows into a conversation,
streamed as it's written. Its trifecta cut is the secretary's, pushed
one step: it searches the web but never opens a URL, so the only way
out is the vouched search, here with each result's page text served
from the engine's own index rather than snippets alone. Beside it sit
your notes, calendar, mail and reminders. Its `design/ideas/` folder is
where the questions this book leaves open are being worked through.
One example is a *federation*: several agents, with you passing text
between them.

## pikuri-tui

[pikuri-tui](https://codeberg.org/mvysny/pikuri-tui) is a set of
terminal front-ends:

- **`pikuri-tui-chat`**: a general-purpose chat with web search and the
  calculator, the TUI version of `pikuri-chat`.
- **`pikuri-tui-code`**: the in-repo coding agent from
  [book 2's coding-agent chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/code.md),
  plus a git diff view and plan mode.
- **`pikuri-tui-computer`**: a desktop assistant for your machine. It
  has the OS helper from
  [book 2's OS-assistant chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/os-assistant.md),
  your Thunderbird mail and calendar, and web research kept behind an
  isolated sub-agent.

Read it for a full wiring with a real UI: one config file naming
several models you switch between at runtime, a log pane beside the
conversation, and a confirmer that asks inside the UI instead of on
stdin.

## pikuri-webui

[pikuri-webui](https://codeberg.org/mvysny/pikuri-webui) is the
browser version of the same chat: a Sinatra page that streams the
conversation over SSE, with many conversations in one process plus the
background jobs that title them.

## Running many conversations

Every binary in this book runs one agent at a time; each app above runs
many, and that changes the rules. An `Agent` is one conversation,
synchronous and thread-unsafe on purpose: drive it from any thread you
like, but never from two at once. From outside its turn, only its two
controls are safe to touch, `Cancellable` to stop it and `Interloper` to
hand it a message mid-turn:

```ruby
agents.map { |a| Thread.new { a.run_loop(user_message: task_for(a)) } }.each(&:join)
```

The rest — which tools two agents may share (each tool's `Sharing:`
line), one server's slots, saving and resuming — is
[book 2's chapter on hosting many conversations](https://github.com/mvysny/pikuri-workshop/blob/master/book/conversations.md),
told through `pikuri-conversations`, the gem pikuri-webui and
pikuri-tui are now built on.

## What's next

This is the end of the guide. You now have the vocabulary to read
any pikuri-\* gem's sources and any of the apps above: `Pikuri::Agent`,
`Tool`, listeners, the Extension protocol, the workspace and the
confirmer, sub-agent privilege separation and the
kit from [the security chapter](security.md).

If you want the power tools (a shell, a coding agent, MCP servers,
language servers) and the cages they need, read
[book 2, the workshop](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md).
