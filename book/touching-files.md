# Touching files: the workspace and the confirmer

So far every tool has answered a question: a sum, a search, a page.
This chapter's tools *change* things, on your disk. That brings two
questions the calculator never faced. **Where can the tools reach?**
And **what do you see before a change lands?** pikuri answers each
with one piece: the *workspace*, a folder the file tools can't see
out of, and the *confirmer*, which shows you a change as a diff and
waits for your answer.

Both come back for the rest of the book. A sub-agent's task can be
shown to you before it runs, through the same confirmer. The security chapter's
best test for a human gate, *does the human see the bytes?*, is
about confirmers. And the secretary at the end confirms every note
it writes and every search it sends.

## Prerequisites

The [designing-a-tool chapter](designing-a-tool.md), for what a
tool is and who reads each part of it. Nothing new to install: the
file tools are in `pikuri-workspace`, which the checkout already
has.

## Run it

Make a scratch folder with a few files in it (the transcripts below
use a trip-planning folder with a packing list, a budget and a
README), and point the demo at it:

```sh
pikuri-workspace/bin/pikuri-files --dir ~/trip
```

Leave out `--dir` and it works in the folder you started it from. It
prints the map first:

```
Trifecta: pikuri-files — 1 of 3 legs (untrusted); no private/egress leg found.

pikuri-files [:untrusted_hard]
  read [:untrusted_hard]
  grep [:untrusted_hard]
  glob [:untrusted_hard]
  file_list [:untrusted_hard]
  edit []
  write []
```

Six tools, and two kinds of row. The four that read carry
`:untrusted_hard`: pikuri can't know who wrote the files in your
folder, so it assumes a stranger might have. `edit` and `write`
carry no leg at all: changing a file on your own disk sends nothing
anywhere. There's no network tool, so there's no way out, and the
map is silent. Pass `--private` and the readers gain `:private` too,
because only you can say whether a folder holds secrets; the map
stays silent, since nothing can leave.

That `write []` is worth remembering. The detector grades what can
*leave*, and a write leaves nothing, so the most durable thing this
agent can do, changing your files, is invisible to the map. What
guards it is this chapter's other half.

## Six tools, one workspace

The six are `file_list` (what's in a folder), `glob` (files by name
pattern), `grep` (files by content), `read`, `edit` (replace an
exact piece of text) and `write` (a whole file). They're wired as a
single `Workspace::Extension`, so they share one record of which
files the model has read. You'll see in a moment why that matters
for `edit`.

The extension also hands the model a head start: a one-level listing
of the folder goes into the system prompt at boot. So the first
question needs no exploring:

```
> What's in this folder, and what does the trip cost so far?
→ Read(README.md)
= Read 1 line
→ Read(budget.md)
= Read 7 lines
→ Read(packing.md)
= Read 6 lines
…
So the trip costs **€1,070 so far**, covering flights, cabin accommodation, and car rental.
```

No `file_list`, no `glob`. The model already knew the three files
were there. One level only, deliberately: a deeper listing costs
tokens on every request, and `file_list` is one call away for
anything deeper.

## The workspace: one folder, and nothing outside it

Every path the model passes goes through the workspace before any
file is touched, and the workspace answers one question: is this
inside the folder? A path outside it is refused:

```
Error: path '/etc/hostname' is outside the workspace (roots: /home/alex/trip)
```

`../../.ssh/id_rsa` gets the same answer, and so does a symlink
inside the folder that points out of it: the workspace resolves a
path to where it really is before it checks. That check lives in
the tool's code, not in a prompt line, so a model that's been told
by a file to read your keys can't argue its way past it. That's the
**blast-radius containment** from the security chapter's kit: an
injection in a file the agent reads can reach this folder and
nothing else.

Here is a model running into the edge in practice, asked for a file
in your home folder:

```
> Also check my ~/.bashrc for an alias called trip.
→ Read(~/.bashrc)
= Error: file not found: ~/.bashrc (relative paths resolve against /home/alex/trip)
→ Glob(**/.bashrc)
= Found 0 files
…
- The real `~/.bashrc` lives outside this workspace, so it isn't reachable from here.
```

The refusal held, but notice how: the model wrote `~/.bashrc`, and
`~` is a shell's shorthand for your home folder, not something a
file path means. So the tool read it as a folder literally named
`~` inside the workspace, and answered *not found* rather than
*outside the workspace*. The model got there in the end, but by a
detour. The error does name the folder paths resolve against, which
is what let it work out where it stood. A message that names the
thing that's wrong is what a model recovers from, as the
designing-a-tool chapter found with the calculator.

A workspace can also be the whole machine, for an assistant whose
job is your computer. Then nothing is "outside", and a fixed list of
places is refused instead: `~/.ssh`, `~/.aws`, `~/.gnupg` and their
like. That's a floor, not a wall, and it's
[book 2's](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md)
territory. In this book a workspace is one folder.

## Read before you edit

`edit` replaces one exact piece of text with another. The model
passes the old text and the new, and the edit applies only if the
old text is in the file exactly once, unless the model says which
match it means or asks to replace them all. That's strict on purpose: an
edit that guessed at the surrounding text would change the wrong
line in a file the model only half remembered.

And `edit` works only on a file the model has read through `read`
in this conversation. That's the shared record from earlier. Without
it, a model could edit a file from what it *thinks* is in it, and
the first sign would be a broken file.

Both rules show up in the next transcript, recovering from a wrong
assumption.

## The confirmer: you see the change before it lands

Every change this demo makes is shown to you first, as a diff:

```
> Add a ski mask and hand warmers to the packing list.
→ Edit(packing.md)

OK to edit packing.md (1 occurrence)?
--- a/packing.md
+++ b/packing.md
@@ -4,3 +4,5 @@
 - wool socks (4 pairs)
 - down jacket
 - headlamp
+- ski mask
+- hand warmers
[y] approve  [n] reject  [r] redirect
y
= Added 4 lines, removed 2 lines
```

Three answers. **`y`** applies it. **`n`** declines it, and the model
is told the decline is final: it shouldn't try to get the same
change in some other way, and should wait for you. **`r`** declines
it *and* tells the model what to do instead, which is the one you'll
use most:

```
> Add fuel to the budget, about 150.
→ Edit(budget.md)

OK to edit budget.md (1 occurrence)?
…
+| Fuel | 150 |
[y] approve  [n] reject  [r] redirect
r
Tell the agent (blank just rejects): Make it 220, it's a long drive from Rovaniemi. And add a total row.
= Redirected by the user
→ Edit(budget.md)
= Error: old_string not found in budget.md. It must match the file exactly, including whitespace and indentation; re-read with the read tool if uncertain.
→ Read(budget.md)
= Read 7 lines
→ Edit(budget.md)

OK to edit budget.md (1 occurrence)?
…
+| Fuel | 220 |
+| **Total** | **1,290** |
[y] approve  [n] reject  [r] redirect
```

The model's first retry assumed the declined line had landed, and
tried to edit around it. The exact-match rule refused, the error
said what to do (*re-read with the read tool*), and the model did,
then proposed the right change. Nothing reached the file until the
diff on screen was the one you wanted.

### Why a diff, and not a question

The confirmer could have asked "edit `budget.md`?". It shows the diff
because of the test the [trifecta chapter](trifecta-detector.md)
builds its human gates on: **does the human see the bytes, or a
proxy for them?** A filename is a proxy. You'd be approving a
*name*, and the content that lands is whatever the model wrote,
which you never saw. A diff is the bytes. Approve a diff and you
know exactly what's now in the file.

It matters most when the file is one something else will trust
later. A note the model writes from a mail it read, saying "invoices
from this supplier now go to a new account", is an attack that
waits on your disk until a later conversation reads it back as your
own words. The diff is where you catch it. The secretary chapter
shows that one for real.

### How much to confirm

This demo confirms *every* change, because it's a demo and you
should see each one. That's a choice the host makes, with
`confirm_all_writes: true`. By default the file tools are quieter:
`write` asks only before it overwrites a file that already exists,
and `edit` doesn't ask at all, since it can only touch a file the
model read and change text that's exactly there.

Which is right depends on the job, and on attention. Every prompt is
spent from yours, and a confirmer that asks about everything trains
you to press `y` without reading, at which point it protects nothing.
The [security chapter](security.md) has the numbers on that. The
rule of thumb: confirm what's durable or consequential, and let
structure, a folder the tools can't see out of, carry the routine.

### One seam, many screens

The tools never print a prompt or read your answer themselves. They
hand a request to whatever confirmer the host wired, and get back an
answer: approved (perhaps with the text you edited), rejected, or
redirected with your words. The terminal one in this demo is one
implementation; a graphical app hands in its own, with buttons, and
not one tool changes.

Some requests let you edit what's proposed before approving, shown
as an extra `[e] edit`. That's for a request whose payload is plain
text you might want to tweak, like the task a parent agent hands a
sub-agent, or a search query about to leave your machine. A diff
isn't offered for editing; you redirect instead.

## What's next

You now have tools that read and change files, a folder they can't
see out of, and a human who sees every change. [Sub-agents](subagents.md)
hand a whole job to another agent with its own narrow set of tools,
and a host can show you that job, through the same confirmer, before
it starts.

→ Continue to [Sub-agents](subagents.md).
