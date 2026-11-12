# pikuri-web

The tools that reach the internet, for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit:

- `Pikuri::Web::Search.build` (`web_search`) — a search across
  DuckDuckGo, plus Brave and Exa when you pass their keys. Built per
  wiring, since the keys come from you, never from the environment.
- `Pikuri::Web::SCRAPE` (`web_scrape`) — a web page as readable
  Markdown.
- `Pikuri::Web::FETCH` (`fetch`) — a URL's body verbatim, for JSON,
  CSV, `robots.txt` and source files.
- `Pikuri::Web::READ_CACHED` (`web_read_cached`) — the page text a
  `page_text: true` search brought back, read by handle, with no
  request of its own.

Every one of them puts text written by strangers into the
conversation, and `web_scrape` / `fetch` will request any URL the
model types — which is a way to send your data out. That is why they
live here rather than in pikuri-core: an agent that doesn't need the
internet doesn't load them, and one that does shows it on the
trifecta map printed at boot.

## Install

```ruby
# Gemfile
gem 'pikuri-web'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-web'

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_tool Pikuri::Web::Search.build(brave_key: 'BSA...')
  c.add_tool Pikuri::Web::SCRAPE
  c.add_tool Pikuri::Web::FETCH
end
```

For a search-only agent, swap the scraper for the cached reader, so
the only request that leaves the machine is the search itself:

```ruby
c.add_tool Pikuri::Web::Search.build(engines: [:exa], exa_key: 'xyz', page_text: true)
c.add_tool Pikuri::Web::READ_CACHED
```

For an agent that reads your mail or notes, give it the snippets and
nothing else, and show yourself every query before it goes out. The
model may otherwise put "Jan Novák chemo side effects" into a search,
straight from a mail it just read, and that query then sits in the
search engine's logs:

```ruby
c.add_tool Pikuri::Web::Search.build(snippets_only: true,
                                     confirmer: Pikuri::Workspace::Confirmer::Terminal.new)
```

## Further reading

- [The first-conversation chapter](../book/chat.md) — the tools in a
  working chat agent, and each search provider's privacy posture.
- [The sub-agents chapter](../book/subagents.md) — keeping these
  tools off an agent that reads your files, behind a `RESEARCHER`.
