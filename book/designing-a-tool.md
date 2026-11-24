# Designing a tool: the calculator

The [first conversation](chat.md) ended with an agent calling tools
somebody else wrote. This chapter is about writing one, and it
teaches that on the smallest tool in pikuri: `calculator`, about a
hundred lines that evaluate an arithmetic expression. It holds no
secrets, touches no network and has no state, so nothing gets in
the way of the design questions every tool answers: what the model
reads, what it writes back, what happens when it gets it wrong, and
what the tool tells pikuri about itself.

Most of those answers in `calculator` weren't designed up front.
They were settled by watching a model use it and fixing what went
wrong, and that habit is the real subject of this chapter.

## Prerequisites

The [first-conversation chapter](chat.md): a running llama-server
and `pikuri-chat`, which already wires `calculator`. There's
nothing new to install.

## A tool is four things the model reads, and one it doesn't

Here is `calculator`, as it's declared in
`pikuri-core/lib/pikuri/tool/calculator.rb`, with the long
parameter description cut:

```ruby
CALCULATOR = Pikuri::Tool.new(
  name: 'calculator',
  description: <<~DESC,
    Evaluates a basic arithmetic expression and returns the numeric result.

    Usage:
    - Use this for any arithmetic beyond simple mental math — do not eyeball multi-digit work.
    - Decimal results are rounded to 3 places; integer results are exact.
  DESC
  parameters: Parameters.build { |p|
    p.required_string :expression,
                      'Arithmetic expression in Python syntax: + - * / (true division), ' \
                      '… E.g. "155 / (58 * 1000.0 / 3600)", "2**10", or "hypot(3, 4)".'
  },
  execute: ->(expression:) {
    value = Calculator.calculate(expression)
    Tool::Result.new(content: value, summary: value)
  },
  trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
)
```

Each field has a different reader, and keeping them straight is
most of tool design:

- **`name`, `description` and the parameter descriptions** are read
  by the model, every turn, as part of the request. They're the
  tool's whole user interface. The model never sees your code.
- **`execute`** runs when the model calls the tool. What it returns,
  the `Result`'s `content`, is what the model reads next.
- **The `Result`'s `summary`** is read by *you*: it's the one-line
  status the terminal prints under the call.
- **`trifecta_legs`** is read by pikuri, never by the model. It's
  how the tool tells the [trifecta detector](trifecta-detector.md)
  what it can reach.

`Pikuri::Tool` is a plain value object: those fields and nothing
else. The one place it turns into ruby_llm's own tool shape is a
single method the agent calls when it wires the tools in, so the
code you write never touches ruby_llm.

## Why have the tool at all

Before designing anything, the question every tool should survive:
does the model need it? The case against `calculator` is
well-known, and a frontier model reviewing a pikuri wiring made it
in two sentences: *if the model can't add, a tool won't save it; if
it can, bash and python already exist.* Neither Claude Code nor
opencode ships a calculator.

Both halves are true of the harness that reviewer was speaking
from, and false here:

- **"Bash already exists."** Claude Code is one binary that always
  has a shell. pikuri is a set of gems you wire, and no wiring in
  this book has a shell at all; that's book 2's. A mail agent
  totalling invoice amounts has no `python3` to reach for. The tool
  is the only way it gets a sum right.
- **"If it can't add, a tool won't save it."** The failure was never
  "can't add". It's digit-level unreliability on long
  multiplications and floats, and that's exactly what a
  deterministic evaluator fixes. The default model in this book is
  a 4-bit-quantized model with about 3 billion parameters active per
  token, not a frontier model. Privacy-first by default makes the
  tool *more* useful here, not less.

And the cost is the smallest a tool can have: one more schema in
each request, and nothing to defend. Which is the first lesson.
**A tool is justified by the harness it lives in, not by an
argument about models in general.** The same tool can be a smell in
one product and load-bearing in another.

## Speak a grammar the model already knows

The parameter is called `expression`, and the most important
decision in the whole tool is what goes in it.

The first version evaluated through a Ruby gem whose grammar used
`^` for powers, so pikuri rewrote the model's `**` into `^` before
evaluating. That's a small translation layer, and it's a sign of
the problem: the model writes Python, because Python is what it has
seen most arithmetic written in, and the tool spoke something else.
The tool now has its own parser, about a hundred lines of Ruby that
implement Python's arithmetic grammar directly, and the model's
native syntax *is* the grammar. `2**-1` is `0.5`, `7 // 2` is `3`,
`/` always divides as a float — all as Python does it, because
that's what the model expects.

The functions came the same way. The first parser had operators
only, on the theory that functions would teach the model a pikuri
dialect. Then a model, asked for a great-circle distance, called it
with

```
6371 * math.acos(math.sin(60.1699) * math.sin(41.3874) + …)
```

and got `Error: unexpected character "m"`. That's not something the
model can work around: you can break a long multiplication into
smaller ones, but you can't write a sine in `+ - * /`. Its only
options were to give up or invent a number.

So functions shipped, and the rule that decides which ones is the
rule for the whole tool:

> **Be a superset of Python, never a subset.**

The names are `math`'s, spelled as Python spells them. `math.` is
an optional prefix, because the model wrote `math.cos` unprompted
and also writes bare `cos` (which Python accepts after `from math
import *`); accepting only one would leave one common instinct
erroring for no gain. The failure to avoid is a name the model
already knows being rejected.

**One function is there for safety, not convenience.** That model's
expression was wrong as Python: `sin(60.1699)` feeds degrees to a
function that takes radians. With operators only, it failed
loudly. With `sin` and `cos` but no way to convert, the same call
would return 11,953 km where the answer is 2,603 — a confident wrong
number, which is strictly worse than an error. So `radians` and
`degrees` shipped with the trigonometry, and the parameter
description says it in capitals: *trigonometric functions take
RADIANS, so convert degrees first: `sin(radians(30))`, never
`sin(30)`.* That warning lives in the parameter description because
that's the text the model reads at the moment it writes the
argument.

**Where the line is drawn.** Not by a list of names, which would
need re-arguing per function, but by a shape: *fixed-arity,
real→real, pure.* `sqrt`, `log`, `atan2` and `hypot` fit. `min` and
`max` don't: they take any number of arguments, which pulls toward
lists, which pull toward indexing, which pulls toward variables.
And there's no `Calculator.register` to add your own: nobody asked
for it, and a frozen table you can read in ten seconds is worth
more than configurability.

## Watch it work

Rules like these come from transcripts, so here's one. `pikuri-chat`
running Ornith-1.5, asked a question that needs trigonometry:

```
> How far is Helsinki from Barcelona as the crow flies? Work it out from the coordinates rather than looking it up.
…
→ Calculator(R = 6371 phi1 = radians(60.1699) phi2 = radians(41.3874) dphi = radians(41.3874 - 60.1699) dlambda = radians(2.1686 - 24.9384) a = sin(dphi/2)**…)
= Error: unexpected character "=" in "R = 6371\nphi1 = radians(60.1699)\nphi2 = radians(41.3874)\n…
The calculator doesn't support multi-line statements. Let me do it as a single expression.
→ Calculator(6371 * 2 * atan2(sqrt(sin(radians(41.3874 - 60.1699)/2)**2 + cos(radians(60.1699))*cos(radians(41.3874))*sin(radians(2.1686 - 24.9384)/2)**2), s…)
= 2603.428
**Helsinki to Barcelona: ≈ 2,603 km (about 1,617 miles) as the crow flies.**
```

Three things in it are worth a second look.

**It converted to radians, unprompted.** This model reads the
parameter description; the capitals did their job.

**Its first call was Python the tool doesn't speak.** Variables and
assignment are Python too, so this is the one place the grammar is
deliberately a subset: the shape rule above stops before variables,
because a calculator with variables is an interpreter. The model
found the edge on its first try.

**The error got it back on track in one step.** `unexpected
character "="` names the exact thing that's wrong, and the model
rewrote the formula as one expression on the next call. That's the
design working: a recoverable failure is an *observation*, not a
crash. The model reads it and corrects itself.

Could the error be better, say *"assignment isn't supported; write
one expression"*? Maybe. But this model recovered from the one it
got, and the rule `calculator` lives by is to change a message
when a transcript shows a model *failing* to recover from it, not
when one could imagine a nicer wording. Every change here has a
transcript behind it.

## Errors and descriptions are written for the model

Everything the model reads is a prompt, and that includes the error
strings. Three conventions follow from it.

**A recoverable failure comes back as a result; a bug raises.**
Division by zero, an unknown name, `acos(1.0000000001)` (reachable
from rounding in a real haversine): the model can fix all of those,
so they come back as `Error: …` text for it to read. A broken parser
can't be fixed by the model, so it raises, and you see a stack
trace. In a tool you write, that's `Tool::Result.error(message)` for
the first kind and an ordinary exception for the second. Two
exceptions needed care here: Ruby's `Math` raises a different error
from Python's `math` for a function outside its domain, and it
would have crashed the loop instead of telling the model. Both are
caught and turned into `Error: acos(1.0000000001) is undefined`.

**An error says what to do next.** An unknown name doesn't just say
"unknown": it lists every function and constant the tool has.

```
Error: unknown name "median"; available functions: sin, cos, tan, asin, acos,
atan, atan2, hypot, sqrt, exp, log, log10, log2, floor, ceil, abs, radians,
degrees; constants: pi, e
```

The description lists the same set, but a small model recovers from
the error string on its next turn far more reliably than from a
description it read ten turns ago. It costs tokens only when
something already went wrong. Bad *arguments* get the same
treatment for free: pikuri validates every call against the
parameter list before your code runs, collects every problem, and
suggests the parameter the model probably meant:

```
Error: Invalid arguments:
- Unknown parameter `expresion`. Did you mean `expression`?
- Missing required parameter `expression` (string): Arithmetic expression in Python syntax: …
```

**A description says only what the model acts on.** pikuri's tool
descriptions follow one shape, borrowed from opencode: a one-line
summary, a blank line, then `Usage:` bullets. Constraints on one
argument go in *that parameter's* description, with an example
value, because that's where the model is looking when it fills it
in. And the description carries nothing the model can't act on.
"Hand-rolled because the previous gem pulled in 16,000 lines of
dependencies" is true and matters to you, so it's in the code's
comments, where you'll read it. In the description it would only
cost tokens on every request.

## Names: say what's different

The name is the first thing a model reads when it picks a tool,
often the only thing. pikuri has two rules for names. **A verb every
agent already knows goes bare**: `read`, `fetch`, `calculator`. **A
prefix marks a family** sharing one backing resource:
`web_search` and `web_scrape`, `thunderbird_mail_search` and
`thunderbird_calendar_read`.

The rule that matters more came from a transcript. `pikuri-rag`'s
two search tools, now in book 2's
[hybrid-retrieval chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/rag.md),
shipped as `rag_search` and `rag_find`. The owner read a session, watched the
model pick between them, and couldn't tell the two apart either:
*search* and *find* are synonyms, so the names said nothing the
descriptions didn't. One returns a ranked sample by meaning, the
other every document containing the exact words. The second is now
`rag_search_keywords`: named by its mechanism, with the plain name
kept for the default, as `web_search` is the default in its family.
A model scanning names picks the plain one unless it needs exact
words. **Name a tool by what makes it different from its
neighbours.**

The same session changed what that tool says when it finds nothing.
An all-words search with no match used to answer "no documents".
Now it answers with each word's own count:

```
No indexed document contains all of: "solar" (3 documents), "array" (2 documents), "wattage" (0 documents). …
```

and the model retries without the word that emptied the set,
instead of guessing which one it was. An empty result is an
observation too, and it can say what to try next.

## The line you read is the tool's

Under every call, the terminal prints a short status line:

```
→ Calculator(2**10)
= 1024
```

The tool composes it, in code, at the moment it runs, never the
model and never the renderer. A `web_search` summary is
`Returned 10 search results`: a count, computed from the results.
Two rules, and the reason for both is that you read this line as
status. It is **structural, never excerpted**: counts, sizes, exit
codes, never the first line of a fetched page, because those bytes
belong to whoever wrote the page. And it's **code, never the
model's**: a status line the model narrated could be steered by a
page the model read.

`calculator` is the one tool where the summary *is* the
observation: `Tool::Result.new(content: value, summary: value)`.
The value was computed here, from the argument, so echoing it is as
structural as a count.

## Declaring the legs of a tool that holds none

The last field is `trifecta_legs: TrifectaLegs::NONE`. The calculator
reads no private data, takes in no content from outside the
conversation, and sends nothing anywhere. On every boot map that
prints as

```
  calculator []
```

and `[]` means *checked and clear*, not *forgot to say*. Leave
the field out, and pikuri assumes the worst it can determine for
itself: hard untrusted content and an unreviewed way out that
reaches anywhere. An undeclared tool is presumed hostile, because
silence from a tool's author isn't evidence of safety. So even the
most harmless tool declares, and a tool you write declares too. The
[trifecta chapter](trifecta-detector.md) has how to tag one that
does hold legs.

Declaring nothing has a benefit beyond the map. In a harness that
does have a shell, running an interpreter like `python3` always goes
past a human for approval, since approving one is approving
arbitrary code, and an approval prompt is spent from the human's
attention. A calculator that grants no capability can run with no
prompt at all, which keeps `python3 -c '17.5 * 3'` off the prompt
stream and the prompts that remain worth reading.

## One more property: who may share it

One line in the tool's comments answers a question you'll only meet
when a program runs several agents at once: *Sharing: P_stateless.*
The calculator keeps no state between calls, so one instance can
serve every agent in the process. A tool that remembers things per
conversation can't. Every tool in pikuri answers it with one of four
postures; the four, and the app that runs many conversations where they
matter, are in
[book 2's hosting chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/conversations.md#a-tool-two-agents-can-reach).

## What's next

A calculator is the easy case: one argument, one answer, no memory.
A tool that *changes* something adds questions this one never
faces — how the model refers to the thing it changed, how a change
is shown to you before it lands. Stateful tools, a task list above
all, are [book 2's](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md).
Book 1's tools that change something change files, and
[Touching files](touching-files.md) is about where they can reach
and what you see before a change lands.

→ Continue to [Touching files](touching-files.md).
