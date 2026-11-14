# pikuri-html

HTML → Markdown extraction for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit, so
the model reads a web page or an HTML mail attachment as Markdown
instead of inline CSS and layout tables. A 2.5 KB order-confirmation
mail comes out as its 0.7 KB of line items, address and total.

Provides:
- `Pikuri::Extractors::HTML` — an extractor for the
  `Pikuri::Extractor` registry. It claims `text/html` and
  `application/xhtml+xml` by content type, so every pikuri surface
  that carries one picks it up: `web_scrape` and `fetch` (pikuri-web),
  `thunderbird_mail_attachment_read` (pikuri-thunderbird). A local
  `.html` file has no content type and still reads as source.

## Why a separate gem

pikuri-web needs it, but so does an agent that must never reach the
internet: the Thunderbird mail agent reading a forwarded receipt.
Requiring pikuri-web there would make whoever audits an offline mail
agent check that none of the internet tools is wired. pikuri-html is
the HTML half alone, with no HTTP client in it.

It is also an audit surface of its own: every page or attachment it
parses is a stranger's file fed to nokogiri, a native extension.

## Install

```ruby
# Gemfile
gem 'pikuri-html'
```

pikuri-web depends on it, so a web agent already has it.

## Usage

Requiring the gem registers the extractor; there is no rival HTML arm
to choose between:

```ruby
require 'pikuri-core'
require 'pikuri-html'

Pikuri::Extractor.extract(StringIO.new(html), content_type: 'text/html')
```

## Hidden text

An element the markup hides (`hidden`, inline `display: none` or
`visibility: hidden`) stays in the output as
`[hidden in the original: …]`. Most of it is harmless, such as a
mail's inbox preview line, but text no human sees is also where a
prompt injection hides, so the label shows that it was hidden.

This is not a defense. White-on-white text, 1px fonts and stylesheet
classes still get through unlabelled. What contains an injection is
that the agent reading it can't also send your data out; see
[SECURITY.md](../SECURITY.md).

## Limits

Readability is tuned for articles. Mail built from nested layout
tables keeps all its text, but renders as untidy Markdown tables.
