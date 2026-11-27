# pikuri-thunderbird

Search and read your **local** Thunderbird mail and calendars from a pikuri
agent — reading Thunderbird's own on-disk profile, never touching the
network. Part of the [pikuri](https://github.com/mvysny/pikuri) family.

The default surface is read-only and egress-free: the inbound tools
(`thunderbird_mail_search` / `thunderbird_mail_read` /
`thunderbird_mail_attachment_read` / `thunderbird_contact_search` /
`thunderbird_calendar_search` / `thunderbird_calendar_read`). The attachment
reader opens a PDF or text attachment from the mail Thunderbird keeps on your
disk; it never downloads one. An agent wired
with only these has your private mailbox and untrusted message content but no
way to send anything out — the lethal trifecta is broken by construction.

pikuri never sends mail on its own. If you turn on the opt-in compose tools,
`thunderbird_mail_compose` and `thunderbird_mail_reply` (which answers a
message in its thread, quoting it, from the address it reached), the most
they can do is **open a pre-filled Thunderbird compose window** — you read it,
and *you* click Send. They draw the draft in plain text (no hidden HTML, no
tracking images), refuse a body laced with invisible characters, drop
look-alike recipient addresses for you to retype, and flag a domain you've
never sent mail to. For now that flag reaches you through the assistant's
reply, so an assistant manipulated by a message it read can leave it out. See
[`design/architecture.md`](design/architecture.md).

## Requirements

- Linux, with Thunderbird installed (snap or apt).
- For mail search: Thunderbird's global search index (Gloda) enabled — the
  default.
- For full messages and attachments: mail kept on this computer ("Keep
  messages in all folders for this account on this computer" under the
  account's Synchronization & Storage, the IMAP default). A message Thunderbird
  holds only the headers of shows as headers, and the tool tells the model
  which setting to change. A PDF needs a PDF reader
  registered — the demo registers pikuri-pdf. An HTML attachment reads as raw
  markup unless pikuri-html is loaded — the demo loads it. For calendar: events must be cached to disk (a local calendar, or
  a network calendar with "Offline Support" turned on).

## Try it

```sh
./bin/pikuri-thunderbird "what did Alice say about the invoice last month?"
```

It auto-discovers your active Thunderbird profile. Point it elsewhere with
`--profile-dir /path/to/profile`. This demo wires the full surface, including
the compose hand-off — ask it to reply to a message and it opens a pre-filled
Thunderbird window for you to send (it never sends by itself). The demo talks
to a local llama.cpp server by default; put your LLM connection in
`~/.pikuri-examples-config.yaml` (`llm_server`, `llm_model`, `llm_api_key`).

## Wire it into your own agent

```ruby
require 'pikuri-thunderbird'

agent = Pikuri::Agent.new(transport:, system_prompt:) do |c|
  c.add_extension Pikuri::Thunderbird::Extension.new
end
```

Mail tools register only when the Gloda index is present; calendar tools
register whenever a profile is found (and guide you to enable Offline Support
if nothing is cached yet). To add an outbound hand-off, pass
`Extension.new(allow_compose_mail: true)` (draft a message or a reply) or
`allow_create_calendar_event: true` (draft a calendar event) — each stays off
unless you ask for it, and your `system_prompt` should then tell the model it
may draft for you to send/import (an inbound-only prompt that forbids sending
will keep the tools unused).

## How it works

pikuri copies a consistent snapshot of Thunderbird's SQLite databases (so it
never fights Thunderbird for the lock), builds its own fast full-text index
over the already-decoded mail, and serves ranked search + full reads with no
MIME parsing. Design and threat model: [`design/architecture.md`](design/architecture.md).
