# Recall: searching the index your desktop keeps

By the end of this chapter you'll have an agent that briefs you on a
customer from your own hand-written meeting notes: the timeline, what
was discussed last, what was promised and is still open. And you'll
know why it searches the index your desktop already keeps, rather than
one pikuri builds.

This is also the first chapter that points you at your *own* private
data and hands you something you'd run on a Monday morning. Every demo
so far worked on the web or on a folder you pointed it at for
practice. This one wants your notes folder. The agent it builds has no
internet, no mail, no shell: it searches your notes and talks to you,
and that's the whole of it. (It grows a second source later, behind an
explicit flag, and that's the [detector chapter](trifecta-detector.md)'s
worked example rather than this one's.)

## Prerequisites

The `llama-server` and chat model from
[your first conversation](chat.md), and a desktop file index: GNOME's
localsearch, which an Ubuntu desktop already runs, or recoll with an
index you built. [The prerequisites chapter](prerequisites.md#a-desktop-file-index)
says which systems qualify and what to install. No embedding model, no
container, nothing else to download.

## Retrieval, then generation

*RAG*, retrieval-augmented generation, names something simple: before
the model answers, fetch the text the answer depends on and put it in
the context. The model can't know what your notes say. It can read
them, if something hands them over.

Most RAG tutorials go straight from that definition to embeddings and
a vector database. Nothing in the definition needs either. It needs a
search, and in an agent it's the model that runs it: it writes a
query, reads the hits, and searches again when they're wrong. That's
*agentic* retrieval, the same Thought → Tool-call → Observation loop as
every other tool, and it changes what the index has to be good at. A
person typing into a search box gets one shot, so the index had better
guess what they meant. A model can rephrase, try a synonym, try
another language, and read what came back each time. The index only
has to be complete, exact and fresh.

So the questions for this chapter are which index, who builds it, and
what it misses.

## Borrow the index, don't build one

Your desktop already indexes your files. On GNOME, localsearch (the
daemon that used to be called Tracker) watches your home folder,
extracts the text of every document it understands, and keeps a
full-text index of it: that's what the Files app and the Activities
overview search. On KDE, Xfce or a headless box, recoll does the same
job once you point it at your folders. `pikuri-fileindex` reads
whichever of the two is ready, and never builds, configures or
refreshes either.

**Who keeps it fresh.** localsearch is a daemon watching the disk. A
note saved into a watched folder was searchable half a second later,
and a deleted one was gone as fast. recoll is that fresh only while
`recollindex -m` runs; otherwise run `recollindex` before you need it.

**Who pays.** The alternative is an index of your own, and pikuri had
one: every file cut into chunks, each chunk turned into a vector by an
embedding model, all of them in a vector database. On a laptop's
integrated GPU (a Radeon 890M), a 137-page PDF took 36 seconds to
embed: 242 chunks, about seven a second. That's the GPU's ceiling, not
a setting: bge-m3, the embedder it used, costs about 0.65 billion
operations per token, so seven 500-token chunks a second is some 2.3
trillion operations a second, about what llama.cpp gets out of a GPU
that size. Pointed at a
real `~/Documents` of 11,685 files, many of them books, that meant
minutes of silence and then hours of the GPU at 100%. The chat model
shares that GPU the whole time: an answer that took 21 seconds alone
took 78 while the embedder ran. Keeping the vectors on disk pays the
bill once, at the price of a database in a container. Nobody wants to
watch their GPU burn so that an assistant can look up an invoice.

The desktop's index costs none of that. It extracted the text while
you weren't looking, and it keeps up as you save.

**What borrowing costs.** What gets indexed is the desktop's call, not
yours. localsearch skips hidden folders and any folder tree holding a
`.git`, and it keeps source code and `.csv` files by name only, never
their text. On Ubuntu it reads `.docx` and `.odt` text only once
`localsearch-extractor-office` is installed, and a file it indexed
before that stays name-only until you run `localsearch reset --file`
on it. The folders you give the agent can narrow what it sees; they
can't add a folder or a format the desktop skips. recoll has the
opposite blind spot: everything in the folders you configured, code
included, and nothing outside them.

## Two tools

`pikuri-fileindex` gives the model two tools. `fileindex_search`
finds files by the words in them, and `fileindex_read` reads one. Here
is a search for `acme` over the six made-up meeting notes this
chapter's demo uses, paths shortened:

```
~/notes/acme-2026-03-11.md  (470 B of text, shown whole)
  # Acme — kickoff call With Dana Reyes (ops lead) and Sam Okafor (IT). They run 14 …
~/notes/acme-2026-05-20.md  (514 B of text, shown whole)
  # Acme — pilot scope Dana, Sam, and their finance contact Priya Shah. Sam's list …
~/notes/acme-2026-07-02.md  (497 B of text, shown whole)
  # Acme — pilot check-in Dana only, Sam on holiday. Pilot live since 2026-06-17 …
~/notes/acme-2026-08-14.md  (567 B of text, shown whole)
  # Acme — rollout and pricing Dana, Priya, and their CFO, Mikael Lind. They want …
~/notes/team-retro-2026-07-10.md  (174 B of text, shown whole)
  # Team retro Pilot sites went live late twice this quarter because of customer …

Found 5 files, all shown. One match shown per file, or the whole text of a short
one; the index may be slightly stale. Read a file to see its full text and any
other matches.
```

One hit per file. Under localsearch a short file, up to 600
characters, comes whole, so a note like these needs no second call; a
longer one shows forty words around the match, with the matched words
marked `>>like this<<`, and the size of its text says whether to read
it whole or search inside it. The team retro is in the list because
it says "Acme's Oulu site"; a brief about Acme should know about it.

### Every match, and the exact word

Two promises make a keyword index the right first tool for a brief.

**Completeness.** *Found 5 files, all shown* is a promise: no other
note in the folder contains the word. A keyword match is boolean, the
word is in the file or it isn't, so the tool can count. When more
match than it shows, it says so (*Showing 10 of 37 matching files*),
and the model narrows the query. That matters more than it sounds. A
brief assembled from a ranked handful of notes is *quietly* wrong: the
note it didn't see is the commitment nobody remembers, and nothing in
the answer shows the gap.

**Exactness.** *"Which note has invoice #4471?"* is one search for
`4471`, and one file comes back. Rare literal tokens (invoice numbers,
ticket ids, a product code, a surname) are what a keyword index is best
at.

Both promises are what a search by *meaning* can't make. A vector
search returns the top few chunks nearest to the question, a sample by
construction, with no score you could set a cutoff on; and a number
has no meaning to be near, so the note holding `4471` can rank below
one that discusses invoices at length. Book 2's
[hybrid-retrieval chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/rag.md)
adds a keyword index beside its vectors for exactly these two
questions.

### Any word, every word first

Ask localsearch for several words and it wants every one of them in
the same file. That sounds right and works badly with a model, which
writes the query a search engine taught it: *"dental appointment"* for
a note that says *"Dentist … checkup"*. One word the file lacks and
the whole query comes back empty. Over a hundred lookups on a small
demo home folder, 71 of the 140 queries the model wrote found nothing.

So `fileindex_search` matches a file holding *any* of the words, puts
the files holding all of them first, and counts those:

```
Found 2 files, all shown. 2 contain all of your words, shown first.
```

Double quotes group words that must all appear, in any order:
`"notice period" tenant`. The tool's description tells the model to
list the words a file might use, synonyms and other languages
included, which is what a rephrase was going to do anyway, in one call.
Empty searches fell from half to a fifth.

### Reading a file

`fileindex_read` returns the text the index extracted, a PDF's or a
`.docx`'s as much as a note's, line-numbered and paged like the file
tools' `read`. With a `pattern`, a regular expression, it returns only
the lines that match, which is how the model finds a total in a
forty-page contract without reading forty pages. It reads the index,
not the disk: under localsearch that's the note you saved a second
ago, and an agent that writes files (the [secretary](secretary.md))
also gets `read` for a file as it is now.

## The folder limit is the boundary

A stock GNOME install indexes your whole home folder: `~/work`,
`~/snap`, your backups, your Downloads. The index has no idea which of
those an agent may see. One object does:

```ruby
roots = Pikuri::Fileindex::Roots.new(dirs: ['~/notes'], private: true, trusted: true)
backend = Pikuri::Fileindex.pick(roots)   # localsearch, else recoll; raises if neither is ready
agent = Pikuri::Agent.new(transport:, system_prompt:) do |c|
  c.add_extension Pikuri::Fileindex::Extension.new(roots: roots, backend: backend)
end
```

The roots are checked three times. The query asks the index only
about files under them. The folder or path the model names must
resolve inside one, by its real path, so neither `..` nor a symlink
leads out, and a path outside is refused before anything checks
whether it exists. And every hit is checked against the roots before
the model sees it. That last check is the guarantee; the other two
save work. A hidden file or folder below a root is never returned
either: localsearch never indexes one, and recoll does.

Everything else inside a root is reachable. A `passwords.txt` in your
notes folder is as readable as the meeting note beside it. Choosing
the roots is choosing what the agent may see, which is why a host
always names them, and why this demo's folder is your notes and not
your home.

`private:` and `trusted:` are the pair you met on the workspace in
[the files chapter](touching-files.md): whether the folders hold data
worth stealing, and whether every byte in them is yours. Nothing
inspects the files to find out. Both tools take their trifecta legs
from that declaration, and both default to the pessimistic answer.

## The model's words never become a query

The model's search words have to reach the index somehow, and the
obvious way is to paste them into a query string. That's SQL
injection's cousin: a word with a quote in it becomes syntax, and
syntax can widen the search past the folder you meant.

localsearch is queried in SPARQL, a database query language, and every
word group, every folder and the limit go in as *bound parameters*:
the query text says `~group0` and `~folder0`, and the values travel
separately, the way a prepared SQL statement takes its `?`
placeholders. The query text depends only on how many groups and
folders there are. recoll's command line has no parameters, so the
model's words are spliced into recoll's own query language, and a word
can still carry its syntax (`dir:/`, `-word`). That's why the check on
every hit is the guarantee rather than the query's own folder clause:
when you can't keep model text out of the syntax, check what comes
back.

## Whose parser reads a hostile file

A PDF or a `.docx` is a program for its parser to run, and parsers
have bugs. Somebody else wrote some of the files on your disk: the
invoice, the contract, the attachment you saved. Whichever process
parses them is the one a malicious file attacks.

With a borrowed index, that isn't pikuri. localsearch runs its
extractors in a separate process, under a seccomp sandbox. recoll runs
them in `recollindex`, outside pikuri but unsandboxed, which is your
choice of indexer. `fileindex_read` hands the model text the index
already extracted; no parser of pikuri's ever opens the file.

pikuri does read bytes itself elsewhere: the workspace's `read` on a
PDF, a mail attachment, a page the web tools fetched. Those go through
pikuri's own extractor registry, `Pikuri::Extractor`. Remember the
first conversation, where the agent fetched a PDF and got back
*"unsupported content-type"*? Two lines fix it:

```ruby
require 'pikuri-pdf'

Pikuri::Extractors::PDF.register
```

pikuri-core routes every conversion from a format to text through that
one registry, so everything that reads documents (`read`, `web_scrape`,
the mail tools) speaks PDF after one `register` call. Requiring the gem
changes nothing; registering is an explicit call, the same opt-in as
every pikuri extension. And PDF support is a gem of its own because
its parser pulls in five more gems, audit surface a deployment that
never sees a PDF shouldn't carry.

pikuri-pdf is the training-wheels extractor: pure Ruby, in pikuri's
own process. That's acceptable for documents you chose. An agent that
parses whatever strangers send wants each conversion sandboxed, which
is what book 2's `pikuri-extractors` does, in the same registry slot,
with office formats along. The desktop's index already gives you that
sandbox for search, for free.

## What keyword search misses

When `fileindex_search` misses, the cause is one of three, and each
has a different fix. The numbers below come from the secretary's
evaluation: ten lookups (an invoice, a lease, an insurance deductible,
a budget line…), each asked of a fresh agent ten times over a made-up
home folder of 212 files, built so that browsing the folders couldn't
find the answers.

**The text isn't in the index.** The budget was a `.csv`, which
localsearch keeps by name only: every search for it missed, and every
run reached it by listing folders, in 7 to 35 calls. The lease was an
`.odt`; without the office extractor the model met "not in the index",
then a binary file, then found the PDF copy. With the extractor
installed, search found it in under two calls. No search technique
fixes this, embeddings included, since they'd need the same text. The
fixes are another indexer (recoll reads both), or browsing, which is
why the secretary keeps its folder-listing tools.

**The file says it in other words.** *"dental appointment"* against a
note saying *"Dentist … checkup"*. The index stems words, so "study"
finds "studies", and every word also matches as a prefix ("talo"
finds "talossa"), but "dental" isn't "dentist". This one the model
fixes itself, by rephrasing, and any-word matching made the rephrase
cheap.

**A real gap in meaning.** Asked in Finnish about a lease written in
English, no word of the question is in the file. localsearch stems in
one language, your session's, and even a perfect Finnish stemmer
wouldn't turn *vuokrasopimus* into *lease*. On the evaluation's home
the model translated its own query: every run's first, all-Finnish
search missed the lease, and its second, in English, found it in all
ten runs. (A note in the folder that translated *vuokra* as "rent" may
have helped.) The same gap opens without a second language: "the note
about being frugal", meaning a budget spreadsheet that never says
"frugal". A vector index puts a question next to an answer that shares
none of its words, Finnish next to English included, and these are
the only misses that need it. That's what book 2's
[vector-DB chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/vectordb.md)
builds, with its bill.

On that home, outside the two tasks the index couldn't see into, the
file index matched the vector stack: about two calls a lookup, 79 of
80 lookups answered.

### Why your desktop doesn't search by meaning yet

Apple's Core Spotlight has kept a semantic index since 2024, built
while the device sits idle. Linux has proposals: a GNOME
one that would run a small English-only model on the CPU beside
localsearch, and an experimental mode in recoll that its own author
calls orders of magnitude slower than plain indexing. Everyone who
tries hits the bill measured above, and answers it with a tiny model,
idle time or special hardware. If GNOME's index does gain meaning, it
will most likely arrive as one more query function beside the keyword
match, and `pikuri-fileindex` would pick it up without changing shape.

## The demo: a briefing from your own notes

```
./pikuri-fileindex/bin/pikuri-briefing --source ~/notes
```

Point it at a folder of meeting notes and ask it to brief you. The
transcripts below come from the six made-up notes about a made-up
customer, Acme; your own notes are the point of running it.

```
> brief me on Acme — what did we discuss last, and what did we commit to?
→ FileindexSearch(Acme)
= Found 5 files
…
## What we discussed most recently (14 August)

- **Full rollout:** they want all 14 sites live before 1 November 2026.
- **Discount negotiation:** Mikael pushed for a **15%** discount on a two-year term.
  We **agreed to 10%** on a two-year term. The note is explicit that *"the 15% was
  discussed and declined."*
…
## What's unresolved going into the next conversation

- **A recording gap is the headline.** There are no notes after 14 August 2026.
  Today is 18 November. Every August/September commitment — the rollout plan (due
  28 Aug), the handheld quote (due 21 Aug), the signed contract (due 30 Sept) — has
  no follow-up note, so I can't tell you whether any of them happened. I'm not
  guessing.
…
```

One search and no reads: every note was short enough to come whole,
and the footer said there was no sixth. It ordered the notes by the
dates in their names, kept what was discussed (15%) apart from what
was agreed (10%), and its best line is about absence. "No note since
14 August" is a claim it can stand behind only because the search was
complete; a ranked handful couldn't have told it so.

It isn't flawless. Its last bullet says the Oulu VPN delayed go-lives
twice this quarter, where the team retro says two pilots went live
late, Oulu's among them. The brief cites every note it drew on, and
that's how you'd catch it.

The two promises from earlier, each asked of a fresh briefing:

```
> which note has invoice #4471?
→ FileindexSearch(4471 invoice)
= Found 3 files
Invoice #4471 appears in **`acme-2026-08-14.md`** — the Acme conversation of 14 August 2026.
…
> list every note that mentions Oulu
→ FileindexSearch(Oulu)
= Found 4 files
…
That's the complete set — the index reports 4 matches total, all shown.
```

The model added "invoice" to the search on its own; the two other
notes it matched say "invoicing", and the one holding both words came
first.

### Name your notes so a date can be read off them

A search hit carries a path and no date. For the agent to answer "what
did we discuss *last*", the date has to live somewhere it can read,
and the requirement is the **filename**, not a folder structure:

```
~/notes/acme-2026-08-14.md
~/notes/acme-2026-07-02.md
~/notes/initech-2026-08-01.md
```

One flat folder is enough, because the path rides every hit.
Name-before-date is the better order: it groups a customer's notes
together for the question that dominates ("everything about Acme"),
and the date reads just as well off the string.
`customers/acme/2026-08-14.md` is the same idea, not the requirement:
a convention that asks you to reorganize your notes is one you won't
adopt.

Why not the file's modification time? Because it would be wrong the
first time you copy your notes to a new machine. Why not a date on the
note's first line? It works, weakly: a short note comes whole and
shows it, but a long one's hit is forty words around the match, which
may not be the first line.

### Keep the notes folder out of git

localsearch skips any folder tree holding a `.git`, so a notes folder
kept in git is invisible to it, and the briefing exits at boot saying
nothing under the folder is indexed. Sync it some other way, or use
recoll, which indexes what you tell it to. With recoll, run
`recollindex -m` so this morning's note is in the brief, or re-index
before you ask.

### The one-legged agent

The briefing prints its trifecta map at boot, and you get something no
other demo in this book has shown:

```
Trifecta: pikuri-briefing — 1 of 3 legs (private); no untrusted/egress leg found.

pikuri-briefing [:private]
  fileindex_search [:private]
  fileindex_read [:private]
```

**One leg.** Private data, unambiguously: every note is a record of a
customer relationship. Untrusted input: no, because you wrote every
byte. Egress: no, because nothing here can send anything anywhere, no
web search, no page fetch, no shell.

And a private leg *alone is inert*. Private data with no exit and no
untrusted input is a personal tool, not an attack surface. No
confirmer, no sandbox, no gate: "start slowly" in its purest form,
and the [detector chapter](trifecta-detector.md) explains why the map
stays quiet rather than warning you about the one leg it found.

Two details in that map were choices.

**The declarations are hardcoded, not flags.** `Roots` defaults both
`private:` and `trusted:` to `false`, because pessimism is honest for a
folder nobody vouched for. The briefing has no honest non-private
reading, so a flag would make the documented invocation the flagged
one and the true map opt-in. A forgotten flag would fail *silent*,
and an agent that prints the wrong leg teaches its operator to stop
reading the map.

**And the binary says the claim out loud**, beside the map:

```
Searching /home/you/notes as PRIVATE and TRUSTED — that means: you reviewed every note in the
  form the model reads it, and nobody else writes into that folder. The desktop indexes
  your whole home folder; only this folder limit keeps the rest out of the brief.
  Paste nothing from a customer; paraphrase.
```

### What `trusted: true` signs you up for

`trusted: true` is a claim about a folder *you* supplied, and it's one
paste away from false. Three clauses:

- *You reviewed every note in the form the model reads it.* For a
  Markdown note that's the file, read in an editor rather than a
  rendered preview, which hides HTML comments the model sees. For a
  PDF or a `.docx` it's the *extracted text*, and the gap is wide:
  white-on-white text, hidden text, comments, tracked changes and
  metadata are all invisible in the rendered document and all present
  in what the index holds. Reading the PDF approved a picture of the
  payload, not the payload. `fileindex_read` shows you exactly what the
  model reads.
- *Nobody else writes into that folder.* The claim is about who can
  write, not what's there today: the desktop indexes a new file within
  a second. A shared Nextcloud folder, a team drive, the scanner's
  output folder, your mail client's attachment folder: each falsifies
  the flag the moment someone else drops a file in.
- *Only the folder limit keeps the rest out.* The index holds your
  whole home folder, Downloads included. The roots are the one thing
  between a stranger's file and a brief that treats it as yours, which
  is why the boot line names them as the boundary.

The one-line rule: **the trusted folder holds only what you typed or
reviewed as text.** Paste a customer's e-mail into a note and that
folder holds text somebody else wrote, retrieved as vouched content
from then on, and nothing can detect it. Paraphrase.

### Local inference is this agent's first invariant

The trifecta model doesn't count the inference provider as egress. A
user who says "these notes stay on my machine" does, and they're the
ones who are right about their own threat model.

Point this binary at a hosted model and every customer note ships to
that provider by design. The one-legged story becomes false at the
transport level, and no tool wiring fixes it. So local inference here
isn't a preference or a default worth overriding; it's the first
invariant, and the binary's header says so. There's nothing to build,
since `Agent::ChatTransport` already makes the connection a wiring
choice, but it's worth writing down before someone "just tries it with
a bigger model".

### Which gem *not* to wire

Two absences are deliberate, and their reasons are more interesting
than the wiring.

**No automatic memory.** The notes folder *is* the durable memory
here: human-written, human-curated, already distilled. A memory that
quietly extracted facts from it would summarize a summary. To remember
something, write a note. (The secretary at the end of the book takes
the same line one step further: its memory is a note too, and it
changes only through a diff you approve.)

**No write tool.** Not because writing is dangerous in general, but
because of what it would become. This agent *can* read your mail: the
`--with-mail` flag wires it read-only, and the
[detector chapter](trifecta-detector.md) runs that as its worked
example. Give it a write tool as well and an agent reading untrusted
mail can write into the folder your whole setup declares *trusted*. A
hostile e-mail's content lands in a note, the desktop indexes it
within a second, and it's retrieved as vouched content from then on,
surviving into sessions with no mail wired at all. A corrupted brief
bounded to one conversation becomes durable poisoning of your notes,
and **the detector says nothing**, because `write` carries no
trifecta leg at all. That one needed reasoning rather than the map.

There's a version of that pipe no tool decision can close: *you*,
pasting a customer's e-mail into a note, move the same bytes from a
source nobody vouched for into a folder everything treats as vouched,
by hand, with nothing able to tell afterwards. That's why the
paraphrase rule keeps coming back.

Which is also the honest trade to record about mail: the
hand-curation you already do (reading correspondence, deciding what
matters, writing it down in your own words) *is* the human-author step
that makes `trusted: true` true. Adding mail access automates away the
step that made the agent one-legged. That's a real feature with a real
cost, not a free upgrade.

## What's next

You now have recall over your own files, through an index you didn't
have to build, and an agent that reads your private notes and can't
send them anywhere. [Security](security.md) is the chapter that says
why that's safe: why there's no NX flag for tokens, the lethal
trifecta, and why pikuri breaks it by construction rather than by
filtering.

Search by meaning, its embedding models, chunking, rerankers and rank
fusion, is
[book 2](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md)'s,
starting from where this chapter's third cause left off.

→ Continue to [Security](security.md).
