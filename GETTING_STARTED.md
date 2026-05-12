# Getting started with pikuri-chat

This guide walks you from a fresh checkout to a working privacy-first
chatbot running entirely on your own machine. The assumed platform is
Ubuntu (or another Debian-derived Linux); adapt the package commands if
you're elsewhere.

## 1. Clone and install

```sh
git clone https://github.com/mvysny/pikuri.git
cd pikuri

# Ruby 3.x and Bundler. Pikuri has no Rails or native-extension
# headaches — the stock distro packages are fine.
sudo apt install ruby ruby-bundler

bundle install
```

That installs all the gems pikuri needs (`ruby_llm`, `faraday`,
`nokogiri`, `tty-markdown`, …) into your user gem path.

## 2. Try to run pikuri-chat (and watch it fail)

```sh
./bin/pikuri-chat "Hello"
```

You'll see a connection error. That's expected — pikuri-chat ships
pointed at a local `llama.cpp` server, and you don't have one running
yet. We'll start one in the next step.

This is the privacy property in action: pikuri does not silently fall
back to a cloud provider. No model means no answer.

## 3. Install llama.cpp

`llama.cpp` is the project that actually runs the model. Ubuntu 24.04
and newer have it packaged:

```sh
sudo apt install llama.cpp
```

This gives you `llama-server` on your `$PATH`. If your distro doesn't
package it, follow the build instructions at
<https://github.com/ggml-org/llama.cpp> — pikuri only needs the
`llama-server` binary.

## 4. Start the model

The model `bin/pikuri-chat` is wired for is `unsloth/Qwen3.6-35B-A3B-GGUF`
— a mixture-of-experts model from the Qwen series, quantized by the
folks at Unsloth so it fits in regular hardware. `llama-server` can
download it from Hugging Face for you on first run:

```sh
llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF \
  --hf-file Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
  -c 65536 \
  --jinja
```

What each flag does:

- `-hf unsloth/Qwen3.6-35B-A3B-GGUF` — Hugging Face repo to pull from.
- `--hf-file Qwen3.6-35B-A3B-UD-Q4_K_M.gguf` — pick the
  Q4_K_M quantization (good size/quality tradeoff).
- `-c 65536` — 64K context window. Pikuri's agent loop accumulates
  tool observations into the context, so headroom matters.
- `--jinja` — enable Jinja chat templates. The Qwen3 series needs this
  for correct tool-call formatting.

**Expect this to be slow on CPU.** A 35B-parameter mixture-of-experts
model running on CPU can manage a few tokens per second. If you have
an NVIDIA or AMD GPU with enough VRAM, add `-ngl 99` to offload all
layers onto the GPU — this is the single biggest speedup you can get.
See `llama-server --help` and the
[llama.cpp docs](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
for tuning options (`-t` for thread count, `-ngl N` for partial GPU
offload, `--mlock`, and friends).

The server binds to `127.0.0.1:8080` by default, and `bin/pikuri-chat`
is wired to `http://localhost:8080/v1` — so if you're running both on
the same machine, no further configuration is needed. If your
`llama-server` lives on another host, edit the `openai_api_base`
string near the top of `bin/pikuri-chat` to match.

## 5. Talk to it

In a second terminal, leaving `llama-server` running:

```sh
./bin/pikuri-chat
```

You'll get a `>` prompt. Try something the model can't answer from
memory alone — that's where the tools come in:

```
> What is 1837 * 4291, and what's the current Ruby stable version?
```

You should see the model emit reasoning, call the `calculator` tool
for the multiplication, call `web_search` (and likely `web_scrape`)
for the Ruby version, then reply in plain text. Use Ctrl+D or Ctrl+C
to exit.

## How the agentic loop works (and why it's private)

Pikuri runs the standard *Thought → Tool-call → Observation* loop:

1. The model receives your message plus the running conversation.
2. It produces either a final answer (and the turn ends) or a tool
   call — a structured request like *"call `web_search` with query
   `…`"*.
3. Pikuri executes the requested tool locally, capturing its output as
   an *observation*.
4. The observation is appended to the conversation and the model is
   called again.

The model itself runs entirely inside your `llama-server` process. It
has **no network access** of its own — it can only reason and emit
text. The single way information leaves your machine is when the model
asks pikuri to call a network-touching tool, and pikuri actually
performs that call on your behalf. If you never give the model network
tools, nothing the model "thinks about" can ever leave the box.

This is meaningfully stronger than the typical hosted-assistant
arrangement: there is no provider receiving your prompts, no telemetry
pipeline, and no fine-tuning corpus being assembled from your chats.

If you'd like to *see* this loop implemented in a handful of files
with nothing else in the way, the sister project
[agentic-loop-demo](https://codeberg.org/mvysny/agentic-loop-demo) is
written exactly for that. Pikuri uses the same shape, just wrapped in
tools, listeners, and sub-agents.

## What tools `bin/pikuri-chat` ships with

Four tools, all defined in `lib/tool/` and wired in `bin/pikuri-chat`:

- **`calculator`** — evaluates an arithmetic expression with Dentaku.
  Local, no network.
- **`web_search`** — runs a search query through one of the configured
  search providers and returns a Markdown list of titles, URLs, and
  snippets. See below for the privacy posture of each provider.
- **`web_scrape`** — fetches an HTML page or PDF, strips the chrome
  with readability extraction, and returns the main content as
  Markdown. The model typically chains `web_search` → pick a URL →
  `web_scrape` to read the full article.
- **`fetch`** — downloads a URL verbatim (JSON, CSV, robots.txt,
  source files) without any rendering pass that would corrupt the
  bytes.

Plus a built-in *sub-agent* facility (enabled by
`agent.allow_sub_agent`): the model can dispatch a focused side-quest
to a fresh agent so the noisy intermediate observations don't pollute
the main context.

## Search providers and their privacy trade-offs

`web_search` is a cascade across whichever providers you have
configured. The orchestration lives in `lib/tool/search/engines.rb`;
each provider's privacy posture is documented in detail at the top of
its source file.

### DuckDuckGo (default, no setup)

Always available — no API key, no registration. Pikuri scrapes the
public HTML endpoint at `html.duckduckgo.com`. DuckDuckGo's policy is
that they don't save your IP alongside searches, don't sell personal
information, and proxy the request so downstream content providers
can't profile you. The catch: DDG is largely a relay over Bing for
web results, so the *query content* still reaches Microsoft for
fulfillment, even though identifying info is stripped on the way out.

Good enough for everyday curiosity. See
`lib/tool/search/duckduckgo.rb` for the full write-up.

### Brave Search API (recommended for sensitive queries)

The best privacy posture of the three. Brave does **not** train its
models on your queries, does not link queries to identifiers, and
retains query logs for 90 days by default (Zero Data Retention is
available on their Enterprise plan).

To enable it, register for a free API key at
<https://api-dashboard.search.brave.com> — the "Data for Search" tier
gives you 1 query/sec and ~2k queries/month at no cost. Then export
the key before starting pikuri:

```sh
export BRAVE_SEARCH_API_KEY=your-key-here
./bin/pikuri-chat
```

Once the env var is set, Brave joins the cascade and may be chosen
over DuckDuckGo for any given query. See `lib/tool/search/brave.rb`.

### Exa (paid, weakest privacy)

Optional. Exa is a paid neural-search API; activate it by setting
`EXA_API_KEY`. Be aware that Exa's Terms grant them a
*perpetual, irrevocable, sub-licensable* license over the queries you
submit, and their privacy policy explicitly says queries are used for
training. Don't enable Exa if your search history would be
embarrassing or sensitive in a training set.

See `lib/tool/search/exa.rb` for the full privacy posture.

### Recommended setup for best privacy

1. Run `llama-server` locally (Step 4 above).
2. Register a free Brave Search API key and `export
   BRAVE_SEARCH_API_KEY=…`.
3. Leave Exa unset.

With this configuration, your prompts never leave your machine, and
your search queries hit Brave under a clear no-training-on-queries
commitment.
