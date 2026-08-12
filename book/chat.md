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
out, verified MCPs — are designed to be safe even with real data;
[the security chapter](security.md) explains why. If you're uneasy until
then, just follow along with throwaway prompts. The defaults are
tuned for the recommended path: pikuri running on your own
machine, on a project you'd already trust to live there. Within
that path the built-in safeguards are designed to hold without
you thinking about them. The security chapter (and its code-track companion,
[the security-revisited chapter](security-revisited.md)) is the heavyweight reading
for when you want to step outside that path — pulling in
third-party plugins, pointing pikuri at code you don't already
trust, or running it unattended.

## Prerequisites

You should already have a checkout and `bundle install` finished,
per [the prerequisites chapter](prerequisites.md) (its Docker section
can wait until the vector-DB chapter — nothing here needs it). Quick
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
below (and in [the vector-DB chapter](vectordb.md), where we run a chat
model and an embedding model from the same server). Older Ubuntu
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
`unsloth/Qwen3.6-35B-A3B-GGUF` — a mixture-of-experts model from
the Qwen series, quantized by the folks at Unsloth so it fits on
regular hardware. (Why *mixture-of-experts* is the property that
makes local-first practical — and what to swap in on bigger or
smaller machines — is explained at the end of step 3.) `llama-server` itself is the download tool: run
it once pointing at the Hugging Face repo, and the GGUF lands in
`~/.cache/llama.cpp/`:

```sh
llama-server -hf unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M
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

- `--jinja` — enable Jinja chat templates. The Qwen3 series needs
  this for correct tool-call formatting.

The router keeps up to `--models-max` models resident
simultaneously (default: 4) and only unloads the
least-recently-used one when that limit is reached. With just
the chat model so far that's one model in one process; the
vector-DB chapter will add an embedder and a reranker by pulling more GGUFs
into `~/.cache/llama.cpp/`, and this same router will pick them
up on next request without displacing the chat model. The win
over a separate `llama-swap` proxy is that there are no extra
moving parts to configure.

**Memory.** Q4_K_M of this 35B-A3B model needs **a bit under
32 GB of memory** for the weights plus KV cache — deliberately,
so it fits a 32 GB VRAM budget with a little room left for the
OS and for the embedder + reranker the vector-DB chapter adds (another
~1 GB between them). All three models stay resident at once and
still fit in 32 GB — barely, but they fit.

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
  (30B-A3B) trades some of Qwen's general knowledge for stronger
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

You'll get a `>` prompt. Try something the model can't answer from
memory alone — that's where the tools come in:

```
> What is 1837 * 4291, and what's the current Ruby stable version?
```

You should see the model emit reasoning, call the `calculator`
tool for the multiplication, call `web_search` (and likely
`web_scrape`) for the Ruby version, then reply in plain text. Use
Ctrl+D or Ctrl+C to exit.

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

## The four bundled tools

All defined in `pikuri-core/lib/pikuri/tool/` and wired into
`pikuri-chat`:

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
the vector-DB chapter opens by plugging one in with two lines. Remember this
moment when you get there.

## Configuring the example scripts

The bundled `bin/pikuri-*` scripts read their settings — which LLM
server and model to use, the API key for a hosted provider, and the
optional search-provider keys — from a single YAML file at
`~/.pikuri-examples-config.yaml`. YAML (rather than JSON) so you can
keep several LLM blocks in the file and `#`-comment out the ones
you're not using — handy when testing against more than one model or
server. There are deliberately **no
`--server` / `--model` / API-key command-line flags**: pikuri the
library never reads keys from the environment (a rogue tool or MCP
server could otherwise harvest them out of `ENV` — see the project's
*Environment is not a secret store* rule), so the example scripts keep
their configuration in a file you own and lock down.

Create it, and restrict its permissions since it holds secrets:

```sh
cat > ~/.pikuri-examples-config.yaml <<'YAML'
llm_server: http://localhost:8080
llm_model: unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M

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
The recognized keys:

| Key | Used by | Meaning |
|-----|---------|---------|
| `llm_server` | all scripts | LLM server base URL; a trailing `/v1` is optional (`https://api.x.ai` and `https://api.x.ai/v1` both work) |
| `llm_model` | all scripts | chat model identifier |
| `llm_api_key` | all scripts | API key for a hosted provider; omit for a keyless local server |
| `brave_search_api_key` | chat, code, assistant | enables Brave web search (below) |
| `exa_api_key` | chat, code, assistant | enables Exa web search (below) |
| `embed_model` | corpus, memory | embedding model |
| `extraction_model` | memory | mem0 extraction model |
| `reranker_model`, `reranker_server` | corpus | reranker model / its server |

What stays on the command line is what changes *per run*: the prompt
itself, and operational toggles like `--no-sandbox` (the coding-agent chapter) — a
security switch you'd never want silently persisted in a file.

## Search providers and their privacy trade-offs

`web_search` is a cascade across whichever providers you have
configured. The orchestration lives in
`pikuri-core/lib/pikuri/tool/search/engines.rb`; each provider's
privacy posture is documented in detail at the top of its source
file.

### DuckDuckGo (default, no setup)

Always available — no API key, no registration. Pikuri scrapes the
public HTML endpoint at `html.duckduckgo.com`. DuckDuckGo's policy
is that they don't save your IP alongside searches, don't sell
personal information, and proxy the request so downstream content
providers can't profile you. The catch: DDG is largely a relay
over Bing for web results, so the *query content* still reaches
Microsoft for fulfillment, even though identifying info is
stripped on the way out.

Good enough for everyday curiosity. See
`pikuri-core/lib/pikuri/tool/search/duckduckgo.rb` for the full
write-up.

### Brave Search API (recommended for sensitive queries)

The best privacy posture of the three. Brave does **not** train
its models on your queries, does not link queries to identifiers,
and retains query logs for 90 days by default (Zero Data Retention
is available on their Enterprise plan).

To enable it, register for a free API key at
<https://api-dashboard.search.brave.com> — the "Data for Search"
tier gives you 1 query/sec and ~2k queries/month at no cost. Then
add it to your config file under `brave_search_api_key`:

```yaml
brave_search_api_key: your-key-here
```

Once the key is present, Brave joins the cascade and may be chosen
over DuckDuckGo for any given query. See
`pikuri-core/lib/pikuri/tool/search/brave.rb`.

### Exa (paid, weakest privacy)

Optional. Exa is a paid neural-search API; activate it by adding an
`exa_api_key` to your config file. Be aware that Exa's Terms grant them a *perpetual,
irrevocable, sub-licensable* license over the queries you submit,
and their privacy policy explicitly says queries are used for
training. Don't enable Exa if your search history would be
embarrassing or sensitive in a training set.

See `pikuri-core/lib/pikuri/tool/search/exa.rb` for the full
privacy posture.

### Recommended setup for best privacy

1. Run `llama-server` locally (Steps 2–3 above).
2. Register a free Brave Search API key and put it in
   `~/.pikuri-examples-config.yaml` under `brave_search_api_key`.
3. Leave Exa unset.

With this configuration, your prompts never leave your machine,
and your search queries hit Brave under a clear
no-training-on-queries commitment.

## Next chapter — sub-agents

You now have a working chat agent with four tools. The next
concept on top is **delegation**: letting the model spawn a
sub-agent with a narrow toolset and a focused system prompt, then
absorb only its summary back into the parent conversation. It's
the smallest extension you can wire onto an agent, and the demo
binary (`pikuri-minions`) makes the fan-out concrete.

→ Continue to [sub-agents](subagents.md).
