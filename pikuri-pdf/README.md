# pikuri-pdf

PDF text extraction for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit:
in-process, pure Ruby, and **lazy** — paged reads parse only the
pages the window needs, so showing the first page of a 500-page PDF
never pays for the other 499.

Provides:
- `Pikuri::Extractors::PDF` — an extractor for the
  `Pikuri::Extractor` registry, wrapping the pure-Ruby
  [pdf-reader](https://github.com/yob/pdf-reader) gem. Once
  registered, every pikuri surface that routes through the registry
  picks PDFs up for free: the `read` tool pages through a local
  `.pdf` with `--- Page N ---` markers, `web_scrape` extracts a
  downloaded paper, the pikuri-vectordb indexer ingests a PDF
  corpus.

## Why a separate gem

pikuri-core's pitch is a dependency tree you can audit in an
evening. pdf-reader brings five transitive gems (Ascii85, afm,
hashery, ruby-rc4, ttfunk) that serve nothing else in core — the
largest single bite in that tree, for one file format. So PDF
support is an opt-in sibling instead: install it when your agent
needs PDFs, skip it (and its whole subtree) when it doesn't.

Everything is pure Ruby, so the worst a malicious PDF can do to the
parser is burn CPU and memory — there's no native code to corrupt.

**This gem or [pikuri-extractors](https://github.com/mvysny/pikuri-workshop/blob/master/pikuri-extractors) — pick one
per wiring.** pikuri-extractors' converter container also has a PDF
arm (poppler's `pdftotext`, sandboxed, same `--- Page N ---`
markers): on an agent that fetches untrusted documents from the
web, parsing them in the networkless container is the stronger
posture. This gem is the no-infrastructure wiring — in-process
means no docker and no host CLIs, and it's what makes the lazy
page-windowed reads possible (a subprocess converter must convert
the whole document before emitting anything, and re-converts it on
every paged read). The guide's vector-DB chapter wires this gem and
shows when to swap in pikuri-extractors.

## Install

```ruby
# Gemfile
gem 'pikuri-pdf'
```

## Usage

Requiring the gem changes nothing — registration is an explicit
opt-in your script makes, same philosophy as `c.add_extension`:

```ruby
require 'pikuri-core'
require 'pikuri-pdf'

Pikuri::Extractors::PDF.register

# From here on, the registry handles PDFs everywhere:
text = Pikuri::FileType.read_as_text(Pathname.new('paper.pdf'))
```

`register` inserts the extractor at the *front* of the registry: the
`%PDF-` magic-byte sniff is the strongest signal there — it never
misfires on text, and it must win over the HTML extractor's
content-type match so a PDF served under a lying `Content-Type`
header still extracts.

## Limits

Best-effort by design: pdf-reader produces clean text from PDFs
generated from a digital source (LaTeX, Word export, ...) but
nothing useful from scanned documents — those extract to the empty
string, and the `read` tool words that as a scanned-image hint to
the model. No OCR. Encrypted and XFA-form PDFs surface as
`Error: ...` observations the model can react to.
