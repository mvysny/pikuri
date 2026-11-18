# pikuri-fileindex — testing

Audience: whoever runs this gem's specs, or measures a backend by hand, on a machine whose own
desktop index must stay untouched. This file owns the testbed: what to install, how the specs
reach a real localsearch or recoll index of their own, and what is safe to do to the user's
index. How `PrivateLocalSearch` isolates itself, line by line, is its own yardoc
(`spec/support/private_local_search.rb`); what the backends do is `architecture.md`.

## What to install

Ubuntu 26.04 packages, all from `main` or `universe`:

| Package | Gives | Needed by |
|---|---|---|
| `localsearch` (pulls `tinysparql`) | the indexer `/usr/libexec/localsearch-3`, the `localsearch` and `tinysparql` CLIs | the localsearch index specs |
| `dbus-daemon` | a session bus of our own | the localsearch index specs |
| `localsearch-extractor-office` | the text of `.docx`, `.odt`, `.xlsx`, epub | an office file in a private index; no spec uses one yet |
| `recollcmd` | `recollindex`, `recollq` | the recoll index specs |

A host without them, CI included, skips the index specs ("no localsearch-3 / dbus-daemon /
tinysparql on this host", "no recollq / recollindex on this host"), and rspec reports them as
pending, never as failures. The unit specs run everywhere.

## The specs

`cd pikuri-fileindex && bundle exec rspec`, or `bundle exec rake check` at the root. Three kinds:

- **Unit specs** stand `FakeBackend` (`spec/support/fake_backend.rb`) in for the index: the two
  tools, `Roots`, `Query`, and each backend's parsing of canned CLI output.
- **`local_search_index_spec.rb`** runs the real indexer and the real SPARQL against a private
  index (below). Booting one takes about 2 s.
- **`recoll_index_spec.rb`** runs the real `recollindex` into a scratch config dir (below).

A measurement worth keeping becomes an example in the matching index spec, so the next
LocalSearch or recoll release re-checks it.

## A private localsearch beside GNOME's

`PrivateLocalSearch` boots an index nobody else uses. It starts a `dbus-daemon --session` of its
own; D-Bus activation starts a second `localsearch-3` on that bus, with a temp `HOME`, temp XDG
dirs and keyfile GSettings, so its database and its list of folders to index are its own. While
it runs, the process's `DBUS_SESSION_BUS_ADDRESS` points at that bus, so every `tinysparql` the
backend spawns asks the private index. GNOME's miner never sees the corpus (it lives under
`~/.cache`, which GNOME skips), and the private miner never sees your files. `stop` kills the
bus's process group, which takes the miner with it, and restores the address.

```ruby
index = PrivateLocalSearch.new({ 'notes/a.txt' => "She was running studies.\n" }).start
Pikuri::Fileindex::LocalSearch.search(query: Pikuri::Fileindex::Query.parse('study'), limit: 5,
                                      folders: [index.corpus])
Pikuri::Fileindex::LocalSearch.read_text(File.join(index.corpus, 'notes/a.txt'))
index.stop
```

What bites:

- **The corpus can't be on tmpfs.** The miner refuses such a folder ("not an indexed folder"),
  and `start` times out after 30 s. The corpus goes under `Pikuri::Paths.new_temp`, that is
  `$XDG_CACHE_HOME/pikuri`, else `~/.cache/pikuri`. A shell that points `XDG_CACHE_HOME` into
  `/tmp`, tmpfs on Ubuntu, breaks it.
- **Pass the corpus in braces**, `PrivateLocalSearch.new({ 'a.txt' => '…' })`. Without them Ruby
  reads the string keys as keywords, since the constructor takes `name_only:`, and raises
  `ArgumentError`.
- **`start` waits for every file's text.** A file the index keeps by name only (source code, a
  `.csv`, an office file without the extractor) must also be listed in `name_only:`, or `start`
  times out waiting for text that never comes.
- **The miner inherits the caller's `LANG`, and `LANG` picks the stemmer** (`architecture.md`,
  "File search"). Set `ENV['LANG']` before `start` to measure another language.
- **One private index per process at a time.** The bus address is process-global, so a second
  index started before the first stops sends every query to the second.

To see what an extractor makes of one file without any index, run `localsearch extract FILE`:
it prints what the miner would store, `nie:plainTextContent` included.

For a one-off measurement, put a script in a scratch folder outside the repo, run it with
`bundle exec ruby` from the repo, and `require_relative` the helper by its absolute path, under
`require 'bundler/setup'` and `require 'pikuri-fileindex'`.

## A scratch recoll index

recoll needs no bus. `RECOLL_CONFDIR` (or `recollindex -c DIR`) names a config dir, and the
spec writes `recoll.conf` with `topdirs = <folder>` into a `Dir.mktmpdir`, runs
`recollindex -c DIR`, and sets `RECOLL_CONFDIR` around each example. The user's `~/.recoll` is
never read, and tmpfs is fine.

## The user's own index

The dev VM's GNOME index is a real one: `dev/demo-home/build` puts the demo `~/Documents` there,
and the binaries search it. A shell without the desktop session's bus reaches it with
`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus`.

Read-only, safe anywhere:

- `localsearch status`: whether the miner is idle, and the files it failed to extract.
- `localsearch info FILE`: what the index stores for one file. No `nie:mimeType` means the miner
  never handed it to an extractor.
- `tinysparql query -b org.freedesktop.LocalSearch3 'SELECT …'`.

Changes, each limited to what it names:

- `localsearch reset --file FILE` drops one file from the index and indexes it again. On
  LocalSearch 3.11 a folder argument changed nothing (measured 2026-11), so pass files. This is
  how an office file indexed before `localsearch-extractor-office` was installed gets its text:
  it stays name-only even across a miner restart.
- `systemctl --user restart localsearch-3` restarts the miner. Harmless. It does not re-extract
  a file already indexed (see the line above), but it does crawl for files it missed: after
  `dev/demo-home/build` (or the testbed's build) recreated `~/Documents`, the miner knew the
  folder and none of its files, idle, until a restart indexed them in seconds (measured
  2026-11-18). The binaries then exit with "nothing under … is indexed".

Never on someone else's machine: `localsearch reset` without `--file`, which erases the whole
index and has the miner crawl the home folder again, and `localsearch index --add` / `--remove`,
which persistently change what GNOME indexes.
