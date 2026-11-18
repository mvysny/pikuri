# pikuri-fileindex

Search your files through the index your desktop already keeps, for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit. Ask
"find the Kettle & Co. invoice" and the agent gets back the PDF's path
and a 40-word snippet with the amount in it, without pikuri ever opening
the PDF itself.

Provides:
- `fileindex_search` (`Pikuri::Fileindex::Search`): keyword search,
  ranked, one snippet per file, optionally limited to one folder. It
  says how many files match in all ("Showing 10 of 37"), so "all shown"
  means there is no other.
- `fileindex_read` (`Pikuri::Fileindex::Read`): a file's full text as the
  index extracted it, paged like `read`, with an optional `pattern` that
  returns only the matching lines.
- `Pikuri::Fileindex::Roots`: the folders you let the agent reach. The
  agent can't search or read anything outside them, or any hidden file
  inside them.
- Two backends: GNOME's **localsearch** (queried through `tinysparql`)
  and **recoll** (through `recollq`). `Pikuri::Fileindex.pick` takes the
  first one that is ready.

## Why borrow the desktop's index

- **No GPU bill, no daemon of ours.** GNOME already indexes your files
  and keeps the index fresh as you save. Building our own embedding
  index of `~/Documents` kept a laptop GPU at 100% for hours.
- **The desktop parses the hostile files, not pikuri.** localsearch
  extracts the text of a `.docx` or a PDF in its own sandboxed process.
  A malicious file in Downloads is never parsed by pikuri.
- **Office documents come free**: the index already holds the text of
  `.docx`, `.odt` and spreadsheets (on Ubuntu, once
  `localsearch-extractor-office` is installed).
- **Keyword search can say "that's every match"**, which a vector search
  can't.

It never builds, configures or refreshes an index; it only reads one.

## Requirements

One of:
- **localsearch 3.8 or newer** with the `tinysparql` CLI (Ubuntu 26.04
  LTS and newer; Debian/Ubuntu's `localsearch` package pulls in
  `tinysparql`). Older Tracker 3 (`tracker3`) is not supported. On Ubuntu,
  also install `localsearch-extractor-office`: without it, `.docx`, `.odt`,
  `.xlsx` and epub files are found by name only, never by their text.
- **recoll** with an index you built (`recollindex`). Run
  `recollindex -m` to keep it fresh as files change.

What the index doesn't cover, the agent can't find: localsearch skips
hidden folders, anything inside a git checkout, and the text of source
code and `.csv` files; recoll covers only the folders in its `topdirs`.

## Install

```ruby
# Gemfile
gem 'pikuri-fileindex'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-fileindex'

roots = Pikuri::Fileindex::Roots.new(dirs: %w[~/Desktop ~/Documents], private: true)
backend = Pikuri::Fileindex.pick(roots)   # raises Pikuri::Fileindex::Unavailable, saying why
agent = Pikuri::Agent.new(transport:, system_prompt:) do |c|
  c.add_extension Pikuri::Fileindex::Extension.new(roots:, backend:)
end
```

**Name your folders.** A stock GNOME install indexes your whole home
folder: `~/work`, `~/snap`, your backups. Only the roots keep an agent
you gave `~/Documents` out of the rest.

`private:` says the folders hold data worth stealing; `trusted:` says
every file in them is your own, so nothing a stranger wrote (not
Downloads, not a folder an agent that reads your mail writes into).
Both default to `false`, and they set the tools' trifecta legs.

Pick once per process and hand the backend to every agent: checking
readiness runs one query per root. When neither index holds a file
under the roots, the `Unavailable` message names what is missing for
each index and how to fix it; show it to the user. An empty Desktop
among other roots is fine, and only logs a warning.

Design notes and the backend survey:
[`design/architecture.md`](design/architecture.md).
