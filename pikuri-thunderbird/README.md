# pikuri-thunderbird

Search and read your **local** Thunderbird mail and calendars from a pikuri
agent — reading Thunderbird's own on-disk profile, never touching the
network. Part of the [pikuri](https://codeberg.org/mvysny/pikuri) family.

The v1 surface is read-only and egress-free: four inbound tools
(`thunderbird_mail_search` / `thunderbird_mail_read` /
`thunderbird_calendar_search` / `thunderbird_calendar_read`). An agent wired
with only these has your private mailbox and untrusted message content but no
way to send anything out — the lethal trifecta is broken by construction.
Composing or sending mail is a deliberate non-goal here; that belongs to a
future human-gated hand-off to Thunderbird itself (see `DESIGN.md`).

## Requirements

- Linux, with Thunderbird installed (snap or apt).
- For mail search: Thunderbird's global search index (Gloda) enabled — the
  default. For calendar: events must be cached to disk (a local calendar, or
  a network calendar with "Offline Support" turned on).

## Try it

```sh
./bin/pikuri-thunderbird "what did Alice say about the invoice last month?"
```

It auto-discovers your active Thunderbird profile. Point it elsewhere with
`--profile-dir /path/to/profile`. The demo talks to a local llama.cpp server
by default; put your LLM connection in `~/.pikuri-examples-config.yaml`
(`llm_server`, `llm_model`, `llm_api_key`).

## Wire it into your own agent

```ruby
require 'pikuri-thunderbird'

agent = Pikuri::Agent.new(transport:, system_prompt:) do |c|
  c.add_extension Pikuri::Thunderbird::Extension.new
end
```

Mail tools register only when the Gloda index is present; calendar tools
register whenever a profile is found (and guide you to enable Offline Support
if nothing is cached yet).

## How it works

pikuri copies a consistent snapshot of Thunderbird's SQLite databases (so it
never fights Thunderbird for the lock), builds its own fast full-text index
over the already-decoded mail, and serves ranked search + full reads with no
MIME parsing. Design and threat model: [`DESIGN.md`](DESIGN.md). In-flight
design notes: `ideas/thunderbird.md` in the repo.
