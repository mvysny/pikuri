# Your first conversation

By the end of this chapter you'll have a working privacy-first
chatbot — model and conversation both running entirely on your own
machine, no cloud account, no API key, no telemetry. The assumed
platform is Linux (Ubuntu / another Debian-derivative makes the
package commands literal; for other distros, adapt them).

This chapter is the foundation for everything that follows: it
establishes the base vocabulary — `Pikuri::Agent`, `Pikuri::Tool`,
listeners, the Thought → Tool-call → Observation loop — that
every later chapter builds on.

The defaults — local llama, no tools that could send your data
out — are designed to be safe even with real data;
[the security chapter](security.md) explains why. If you're uneasy until
then, just follow along with throwaway prompts. The defaults are
tuned for the recommended path: pikuri running on your own
machine, on a project you'd already trust to live there. Within
that path the built-in safeguards are designed to hold without
you thinking about them. The security chapter is the heavyweight
reading for when you want to step outside that path — pointing
pikuri at mail and files strangers wrote, or running it unattended.
Running code you didn't write, a shell or a plugin, is
[book 2's](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md)
subject.

## Prerequisites

You should already have a checkout and `bundle install` finished,
per [the prerequisites chapter](prerequisites.md) (its file-index
section can wait until the recall chapter — nothing here needs it). Quick
verification:

```sh
cd /path/to/pikuri
./pikuri-core/bin/pikuri-chat "Hello"
```

You'll see a connection error. That's expected — `pikuri-chat`
ships pointed at a local `llama.cpp` server, and you don't have
one running yet. This is the privacy property in action: pikuri
does not silently fall back to a cloud provider. **No model means
no answer.** We'll start one next.

## 1. Install llama.cpp

`llama.cpp` is the project that actually runs the model. **Use
Ubuntu 26.04 LTS or newer** — that's the first Ubuntu release
packaging `llama-server` build `b8681`, which is recent enough to
include built-in multi-model routing. We rely on that in step 3
below (and book 2's [vector-DB chapter](https://github.com/mvysny/pikuri-workshop/blob/master/book/vectordb.md) runs a chat model and
an embedding model from the same server). Older Ubuntu
releases ship a `llama.cpp` from before the
[model-management feature](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)
landed in late 2025; on those, you'd have to build from source or
run a separate proxy like `llama-swap` to juggle models.

On Ubuntu 26.04+:

```sh
sudo apt install llama.cpp
```

This gives you `llama-server` on your `$PATH`. If your distro
doesn't package a recent enough version, follow the build
instructions at <https://github.com/ggml-org/llama.cpp> — pikuri
only needs the `llama-server` binary.

## 2. Pull the model

The model `pikuri-chat` is wired for is
`ornith-ai/Ornith-1.5-35B-A3B-GGUF` — a mixture-of-experts model
from the Ornith team, built on the Qwen3.5 architecture: about 35B
parameters, of which about 3B work on each token, and at the
quantization below a 21.7 GB file that fits on regular hardware. (Why *mixture-of-experts* is the property that
makes local-first practical — and what to swap in on bigger or
smaller machines — is explained at the end of step 3.) `llama-server` itself is the download tool: run
it once pointing at the Hugging Face repo, and the GGUF lands in
`~/.cache/llama.cpp/`:

```sh
llama-server -hf ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M
```

The `:Q4_K_M` suffix picks the Q4_K_M quantization (good
size/quality tradeoff) out of the several the repo offers. Once
the progress bar finishes and you see *"server is listening on
port 8080"*, the model is cached — hit `Ctrl+C` to stop. (If you
only ever want one model and don't care about multi-model
serving, you can leave this running and skip step 3.)

## 3. Start llama-server in multi-model mode

Now start `llama-server` with no model specified. It boots into
router mode, scans `~/.cache/llama.cpp/` for GGUFs you've pulled,
and loads each one on demand when an API request names it:

```sh
llama-server --jinja
```

What the flags do — these are now defaults inherited by every
model the router loads, not flags for a single model:

- `--jinja` — enable Jinja chat templates. Ornith-1.5, like the
  Qwen models it's built on, needs this for correct tool-call
  formatting.

The router keeps up to `--models-max` models resident
simultaneously (default: 4) and only unloads the
least-recently-used one when that limit is reached. With just
the chat model that's one model in one process; book 2's
vector-DB chapter adds an embedder and a reranker by pulling more GGUFs
into `~/.cache/llama.cpp/`, and this same router picks them up on
next request without displacing the chat model. The win
over a separate `llama-swap` proxy is that there are no extra
moving parts to configure.

**Memory.** Q4_K_M of this 35B-A3B model needs **a bit under
32 GB of memory** for the weights plus KV cache — deliberately,
so it fits a 32 GB VRAM budget with a little room left for the
OS, and for the embedder + reranker book 2's vector-DB chapter adds
(another ~1 GB between them). All three models stay resident at once
and still fit in 32 GB — barely, but they fit.

**Best path on a typical workstation: integrated GPU with 32 GB
allocated as VRAM.** Modern AMD APUs let you carve a chunk of
system RAM out for the iGPU via a BIOS setting (commonly named
*UMA Frame Buffer Size* or *Variable Graphics Memory*) — set it
to 32 GB. Apple Silicon does this automatically. Then pass
`-ngl 99` to push every layer onto the iGPU. Even though it's
the same physical RAM, the iGPU pathway is dramatically faster
than CPU-only inference. A discrete NVIDIA or AMD card with
≥32 GB VRAM works the same way.

### Why a mixture-of-experts model

The model's name decodes as: 35 B parameters *total*, ~3 B
*active* per token (the "A3B"). A **dense** model runs every
parameter it has on every token — so a dense model of comparable
quality would need its entire bulk streamed through the compute
unit thousands of times per sentence, which in practice means the
whole thing sitting in fast VRAM on a serious discrete GPU: the
kind of card that costs more than the rest of your workstation.
A **mixture-of-experts** (MoE) model stores many small "experts"
and routes each token through only a few of them, so each token
reads and computes only ~3 B parameters' worth. The other ~32 B
just have to *exist* in memory — they don't have to be fast.

That asymmetry is what makes the iGPU path above work at all:
total parameters (what the model *knows*) scale with cheap
ordinary RAM, while active parameters (what each token *costs*)
stay small enough for an iGPU — or even a plain CPU — to keep
up. Privacy-savvy users don't generally have a datacenter in the
basement; an MoE sitting in system RAM is what makes local-first
practical without one. When choosing your own model, the shape
to look for is: **MoE, ~3–4 B active parameters, total size
picked by how much memory you have.**

### Picking a different model

The model landscape moves fast — the picks below are current as
of **mid-2026, this book's knowledge cutoff**, and better options
likely exist by the time you read this. The *shape* outlives any
specific pick, and pikuri doesn't care: it serves whatever
`llama-server` loads, so swapping is just a different `-hf …:…`
line in step 2 (and one `llm_model:` line in the config — see
*Configuring the example scripts* below).

- **Less than 32 GB to spare:** use a smaller model — a
  7B-parameter Q4 GGUF fits in 4–6 GB, a 13B in 8–10 GB. **Ask
  your favourite AI assistant to suggest a GGUF that fits your
  CPU, GPU, and RAM** — they're good at this.
- **Same 32 GB budget, tuned for agents:**
  [GLM-4.7-Flash](https://huggingface.co/unsloth/GLM-4.7-Flash-GGUF)
  (30B-A3B) trades some of Ornith's general knowledge for stronger
  tool-calling — and driving tools in a loop is most of what a
  pikuri agent does. Same memory budget, so trying it is free:
  `llama-server -hf unsloth/GLM-4.7-Flash-GGUF:Q4_K_M`.
- **A dedicated LLM box with 64 GB:** the active-param budget is
  a per-token cost floor, not a ceiling on total size — more RAM
  buys more *knowledge* at the same speed.
  [Qwen3-Coder-Next](https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF)
  (80B-A3B) is the same ~3 B-active class with 80 B total
  parameters, trained specifically for long tool-use loops and
  recovering from failed commands; its Q4_K_M weighs ~49 GB, a
  comfortable fit in a 64 GB machine:
  `llama-server -hf unsloth/Qwen3-Coder-Next-GGUF:Q4_K_M`.

Without GPU offload you can still run on CPU: the model will run
a bit slower but still reasonably fast - plenty enough for our experiments.
See `llama-server --help`
and the [llama.cpp docs](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
for tuning options (`-t` thread count, `-ngl N` partial GPU
offload, `--mlock`, and friends). In router mode, every flag you
pass here becomes a default for the models the router loads.

The server binds to `127.0.0.1:8080` by default, and `pikuri-chat`
is wired to `http://localhost:8080/v1` — so if you're running both
on the same machine, no further configuration is needed. To talk
to a server elsewhere — or use a hosted provider, or turn on the
paid search engines — see *Configuring the example scripts* below.

## 4. Talk to it

In a second terminal, leaving `llama-server` running:

```sh
./pikuri-core/bin/pikuri-chat
```

Before the prompt appears, a short report scrolls past:

```
Trifecta: pikuri-chat — 2 of 3 legs (untrusted, egress); no private leg found.

pikuri-chat [:untrusted_hard, :egress]
  web_search [:untrusted_hard, :egress_vouched]
  calculator []
  web_scrape [:untrusted_hard, :egress]
  fetch [:untrusted_hard, :egress]
```

That's pikuri auditing the agent it just wired, and every demo
binary prints it. The one-sentence version: this agent can read
web pages someone else wrote and can send bytes out, but nothing
of yours is wired in for it to leak — two of the three
capabilities that make prompt injection dangerous, so the set is
incomplete.

One line hints at how fine-grained the reading gets. `web_search`
says `:egress_vouched` where `web_scrape` and `fetch` say plain
`:egress`: all three send bytes out, but a search query can only
reach an engine pikuri picked, while the other two fetch whatever
host they're pointed at — so if a web page ever talked this agent
into leaking something, only two of the three could hand it to
whoever wrote that page.

The [security chapter](security.md) explains why those three legs,
and [Measuring the trifecta](trifecta-detector.md) explains how to
read the map in full. For now you can scroll past it.

You'll get a `>` prompt. Try something the model can't answer from
memory alone — that's where the tools come in:

```
> What is 1837 * 4291, and what's the current Ruby stable version?
```

You should see the model emit reasoning, call the `calculator`
tool for the multiplication, call `web_search` (and likely
`web_scrape`) for the Ruby version, then reply in plain text. Use
Ctrl+D or Ctrl+C to exit.

To show it a picture, put `@` before the image's path anywhere in the
line:

```
> @~/Pictures/error-dialog.png what does this dialog want from me?
📎 error-dialog.png (image/png, 48.3 kB)
```

Dragging a file onto most terminals pastes its path, so type `@` and
drop the file. A path with spaces gets quotes, `@'/tmp/my shot.png'`,
which is what the drop pastes anyway. PNG, JPEG, GIF and WebP up to
5 MB work. A PDF doesn't: it's text rather than a picture, and
turning a PDF into text is a tool's job, which the recall chapter
wires.

The model has to be able to see: a `-hf` model on
`llama-server` downloads its vision projector by itself, but one
started with `--no-mmproj-auto` can't. `pikuri-chat` doesn't ask the
server which one it is talking to, so a blind model's server answers
the picture with an error, and the picture stays in the conversation
— start `pikuri-chat` afresh. A host that knows its model is blind
says so on the transport, `modalities: { vision: false }`, and gets
`Not sent: … takes no vision input` instead, before anything goes
out.

A picture is not free. It goes into the context window like text
does: on Ornith-1.5 about one token per 32×32 pixels, capped at
roughly 4,000 tokens however big the image is, so a full-screen
screenshot costs about as much as a dozen pages of text. Other model
families count differently. The usual `ctx=` readout already includes
it.

## How the agentic loop works (and why it's private)

Pikuri runs the standard *Thought → Tool-call → Observation* loop:

1. The model receives your message plus the running conversation.
2. It produces either a final answer (and the turn ends) or a tool
   call — a structured request like *"call `web_search` with query
   `…`"*.
3. Pikuri executes the requested tool locally, capturing its
   output as an *observation*.
4. The observation is appended to the conversation and the model
   is called again.

The model itself runs entirely inside your `llama-server` process.
It has **no network access** of its own — it can only reason and
emit text. The single way information leaves your machine is when
the model asks pikuri to call a network-touching tool, and pikuri
actually performs that call on your behalf. If you never give the
model network tools, nothing the model "thinks about" can ever
leave the box.

This is meaningfully stronger than the typical hosted-assistant
arrangement: there is no provider receiving your prompts, no
telemetry pipeline, and no fine-tuning corpus being assembled from
your chats.

If you'd like to *see* this loop implemented in a handful of files
with nothing else in the way, the sister project
[agentic-loop-demo](https://codeberg.org/mvysny/agentic-loop-demo)
is written exactly for that. Pikuri uses the same shape, just
wrapped in tools, listeners, and sub-agents.

Step 1 hides one thing. "The running conversation" is a list of
messages, one per turn, tool call and observation, but the model
reads one string. Turning the list into that string is the job of
a **chat template**, a small program that ships inside the GGUF
file and that `llama-server --jinja` runs on every request. It's
code you didn't write, and it doesn't have to keep every message:
Ornith-1.5's template, like Qwen3.6's, quietly drops a `system`
message anywhere but the very start of the conversation. Nothing
errors; the model just never sees it. That's why pikuri never adds
a system message mid-conversation, and why, when an agent behaves
as though it's ignoring you, the first thing to check is what the
model actually read. Book 2's
[The messages array is not the prompt](https://github.com/mvysny/pikuri-workshop/blob/master/book/wire.md)
shows how to look.

## The bundled tools

The ones `pikuri-chat` wires. `calculator` is pikuri-core's one
bundled tool; the three that reach the internet come from the
[`pikuri-web`](../pikuri-web/README.md) gem, which an agent that
should stay offline simply doesn't load:

- **`calculator`** — evaluates a Python-syntax arithmetic
  expression with a small built-in parser. Local, no network.
- **`web_search`** — runs a search query through one of the
  configured search providers and returns a Markdown list of
  titles, URLs, and snippets. See below for each provider's
  privacy posture.
- **`web_scrape`** — fetches an HTML page, strips the chrome with
  readability extraction, and returns the main content as Markdown.
  The model typically chains `web_search` → pick a URL →
  `web_scrape` to read the full article.
- **`fetch`** — downloads a URL verbatim (JSON, CSV, robots.txt,
  source files) without any rendering pass that would corrupt the
  bytes.

Try one more thing before moving on: ask the agent to summarize a
PDF — an arXiv paper, an RFC rendered as PDF, anything. Watch it
scrape the URL and report back something like *"Error: unsupported
content-type \"application/pdf\""*, then tell you it can't read the
document. That error string is the whole failure mode: tools hand
the model observations, including failed ones, and the model reacts
instead of crashing. pikuri-core deliberately ships no PDF parser —
it's the kind of dependency you should opt into, not inherit — and
the recall chapter plugs one in with two lines. Remember this moment
when you get there.

## Configuring the example scripts

The bundled `bin/pikuri-*` scripts read their settings — which LLM
server and model to use, the API key for a hosted provider, and the
optional search-provider keys — from a single YAML file at
`~/.pikuri-examples-config.yaml`. YAML (rather than JSON) so you can
keep several LLM blocks in the file and `#`-comment out the ones
you're not using — handy when testing against more than one model or
server. There are deliberately **no
`--server` / `--model` / API-key command-line flags**: pikuri the
library never reads keys from the environment (a rogue tool could
otherwise harvest them out of `ENV` — see the project's
*Environment is not a secret store* rule), so the example scripts keep
their configuration in a file you own and lock down.

Create it, and restrict its permissions since it holds secrets:

```sh
cat > ~/.pikuri-examples-config.yaml <<'YAML'
llm_server: http://localhost:8080
llm_model: ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M

# A second model, parked. Uncomment these (and comment the two
# lines above) to switch — no need to retype anything.
# llm_server: https://api.openai.com
# llm_model: gpt-4o
# llm_api_key: sk-...
YAML
chmod 600 ~/.pikuri-examples-config.yaml
```

Every key is optional — with no file at all, the scripts fall back to
a local `llama-server` at `http://localhost:8080` and need no API key.
A key is not a cloud opt-in: if you start your own server with
`llama-server --api-key YOUR_SECRET` (worth doing the moment it listens
on anything but loopback), put that same secret in `llm_api_key` and
everything stays on your machine. The recognized keys:

| Key | Used by | Meaning |
|-----|---------|---------|
| `llm_server` | all scripts | LLM server base URL; a trailing `/v1` is optional (`https://api.x.ai` and `https://api.x.ai/v1` both work) |
| `llm_model` | all scripts | chat model identifier |
| `llm_api_key` | all scripts | API key the server expects — a hosted provider's, or the secret of a local `llama-server --api-key`; omit for a keyless local server |
| `search` | chat, minions, secretary | the search block: `brave_key`, `exa_key`, `engines` (below) |

What stays on the command line is what changes *per run*: the prompt
itself, and operational toggles like the secretary's
`--no-search-confirm` — a privacy switch you'd never want silently
persisted in a file.

Most demo scripts also take `--system-prompt FILE`, which swaps the
script's own system prompt for the contents of `FILE` — say, a
`pirate.txt` holding *"You are a pirate. Answer every question in
pirate speak."* Two things still get appended after yours: the facts
the script knows about this run (today's date, say), and the
sections each extension adds — the Thunderbird mail rules, the list
of sub-agents it can hand work to, and so on. Your prompt changes
what the agent is told, never which tools it holds: the trifecta map
the script prints is the same with or without it.

## Search providers and their privacy trade-offs

`web_search` is a cascade across whichever providers you selected. The
orchestration lives in
`pikuri-web/lib/pikuri/web/search/engines.rb`; each provider's
privacy posture is documented in detail at the top of its source
file.

### Choosing which engines run

The `engines:` list under `search:` names the engines you want, out of
`duckduckgo`, `brave` and `exa`:

```yaml
search:
  brave_key: your-key-here
  exa_key: xyz            # parked: a key you don't list is simply unused
  engines: [brave]        # only Brave runs
```

Two things to know about it. **It is a set, not a preference order** —
the cascade picks at random per query, so `[brave, duckduckgo]` sends
roughly half your searches to each, and does *not* mean "Brave first".
That randomness is deliberate: every paid provider meters you, so
spreading queries stretches the free tiers. If you want one engine,
list one engine.

And **naming an engine whose key you haven't supplied is an error**,
not a shrug — the scripts refuse to start rather than quietly search
with fewer engines than you asked for. So is an empty list, a repeat,
and a name that isn't one of the three.

Leave `engines:` out and you get the old behavior: DuckDuckGo plus
whichever keyed providers you configured.

### DuckDuckGo (the no-setup default)

No API key, no registration — the only engine that works with no
config file at all, which is why it runs unless your `engines:` list
says otherwise. Pikuri scrapes the
public HTML endpoint at `html.duckduckgo.com`. DuckDuckGo's policy
is that they don't save your IP alongside searches, don't sell
personal information, and proxy the request so downstream content
providers can't profile you. The catch: DDG is largely a relay
over Bing for web results, so the *query content* still reaches
Microsoft for fulfillment, even though identifying info is
stripped on the way out.

Good enough for everyday curiosity. See
`pikuri-web/lib/pikuri/web/search/duckduckgo.rb` for the full
write-up.

### Brave Search API (recommended for sensitive queries)

The best privacy posture of the three. Brave does **not** train
its models on your queries, does not link queries to identifiers,
and retains query logs for 90 days by default (Zero Data Retention
is available on their Enterprise plan).

To enable it, register for a free API key at
<https://api-dashboard.search.brave.com> — the "Data for Search"
tier gives you 1 query/sec and ~2k queries/month at no cost. Then
add it to your config file under `search:`:

```yaml
search:
  brave_key: your-key-here
```

Once the key is present, Brave joins the cascade and may be chosen
over DuckDuckGo for any given query — add `engines: [brave]` to leave
DuckDuckGo out entirely. See
`pikuri-web/lib/pikuri/web/search/brave.rb`.

### Exa (paid, weakest privacy)

Optional. Exa is a paid neural-search API; activate it by adding an
`exa_key` under `search:` and listing `exa` in `engines:` (or leaving
`engines:` out). Be aware that Exa's Terms grant them a *perpetual,
irrevocable, sub-licensable* license over the queries you submit,
and their privacy policy explicitly says queries are used for
training. Don't enable Exa if your search history would be
embarrassing or sensitive in a training set.

See `pikuri-web/lib/pikuri/web/search/exa.rb` for the full
privacy posture.

### Recommended setup for best privacy

1. Run `llama-server` locally (Steps 2–3 above).
2. Register a free Brave Search API key and put it in
   `~/.pikuri-examples-config.yaml` under `search: brave_key:`.
3. Set `engines: [brave]`, so nothing falls back to DuckDuckGo (and
   therefore Bing) behind your back.
4. Leave Exa unset.

```yaml
search:
  brave_key: your-key-here
  engines: [brave]
```

With this configuration, your prompts never leave your machine,
and *every* search query hits Brave under a clear
no-training-on-queries commitment. The trade-off is that Brave's free
tier is ~2k queries/month with no second engine to absorb the
overflow: when it's exhausted, `web_search` returns an error instead
of quietly asking someone else.

## Next chapter — designing a tool

You now have a working chat agent with a handful of tools, all of
them written by somebody else. The next chapter writes one: what the
model reads in a tool, what it gets back when it calls one wrong, and
what a tool tells pikuri about itself, all on the smallest tool there
is, the `calculator` you just watched the model call.

→ Continue to [Designing a tool](designing-a-tool.md).
