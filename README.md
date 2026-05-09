# smolagents.rb

A small Ruby reimplementation of HuggingFace's
[smolagents](https://github.com/huggingface/smolagents), built to **demonstrate
the agentic loop** — *Thought → Tool-call → Observation* — end to end against
an OpenAI-compatible backend.

The whole project is a few hundred lines of plain Ruby. The point is the loop,
not the framework.

## Quick start (Ubuntu 26.04)

### 1. Install llama.cpp

```sh
sudo apt install llama.cpp
```

### 2. Start a local OpenAI-compatible server

The demos expect a model that supports tool calling. Qwen3.6-35B-A3B in Q4 GGUF
form is a good default — it's a thinking model, so you'll see the
*reasoning_content* channel light up too:

```sh
llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF \
  --hf-file Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
  -ngl 99 -c 65536 --jinja
```

Leave it running. It listens on `http://127.0.0.1:8080` by default, which is
where the demo scripts will look.

### 3. Install Ruby dependencies

```sh
bundle install
```

### 4. Run the demos

A minimal one-tool smoke test (an inline `get_weather` tool):

```sh
bundle exec ruby run.rb
```

A fuller demo that actually exercises multi-step reasoning — DuckDuckGo web
search + a calculator, asked to estimate how many seconds a leopard at full
speed would take to run the length of the Pont des Arts:

```sh
bundle exec ruby run-leopard.rb
```

You should see the model's hidden reasoning printed dim, its visible messages
rendered as Markdown, and each tool invocation printed in cyan as it happens.

## Project structure

```
lib/
├── agent.rb             # the Thought / Tool-call / Observation loop
├── chat_log.rb          # append-only conversation history (validated Messages)
├── chat_response.rb     # parses one OpenAI choice into a typed ChatResponse
├── openai_client.rb     # thin Faraday wrapper for POST /chat/completions
├── tool.rb              # Tool value object + Tool#run validation
└── tool/
    ├── parameters.rb        # fluent JSON-Schema builder + arg validator
    ├── calculator.rb        # Dentaku-backed arithmetic tool
    └── duckduckgo_search.rb # DuckDuckGo HTML scrape tool

run.rb                   # minimal one-tool demo
run-leopard.rb           # multi-tool demo with the smolagents system prompt
smolagents-system-prompt.txt           # prompt used by run-leopard.rb
smolagents-system-prompt-original.txt  # verbatim upstream prompt, kept for reference
```

## What is the agentic loop?

A bare LLM is a function from text to text. It can reason, but it can't *act*
— it can't fetch a web page, multiply two large numbers reliably, or read a
file. The agentic loop closes that gap by letting the model **request actions**
and feeding the results back into its own context, one step at a time.

The cycle has three phases:

1. **Thought.** The model reads the conversation so far and decides what to do
   next. With thinking models like Qwen3, this reasoning is emitted on a
   separate `reasoning_content` channel — visible to us for debugging, but kept
   distinct from the user-facing answer.
2. **Tool-call.** Instead of (or alongside) writing prose, the model emits a
   structured request: a tool name plus a JSON arguments object. This is the
   OpenAI [function-calling](https://platform.openai.com/docs/guides/function-calling)
   shape — the host advertises tools as JSON Schemas, the model picks one and
   fills in the arguments.
3. **Observation.** The host validates the arguments, runs the tool, and
   appends the result back into the conversation as a `tool`-role message. The
   loop then ticks again: the model sees the new observation and decides what
   to do next.

The loop terminates when the model returns a `finish_reason` of `stop` with no
further tool calls — i.e. it has decided it has enough information to answer.

### A worked example

Ask the leopard demo "How many seconds would it take for a leopard at full
speed to run through Pont des Arts?" and you'll see something like:

- **Step 1.** *Thought:* "I need the leopard's top speed and the bridge's
  length." *Tool-call:* `web_search(query: "leopard top speed km/h")`.
  *Observation:* a Markdown blob of search results saying ~58 km/h.
- **Step 2.** *Tool-call:* `web_search(query: "Pont des Arts length meters")`.
  *Observation:* ~155 m.
- **Step 3.** *Thought:* "I need to convert and divide." *Tool-call:*
  `calculator(expression: "155 / (58 * 1000 / 3600)")`. *Observation:* `9.621`.
- **Step 4.** No tool call, `finish_reason: stop`. *Assistant:* "About 9.6
  seconds."

Each step is one round trip to the LLM. The model never executes anything
itself — it just *requests* tool calls, and the host (`Agent#run_loop`) is the
thing that actually runs them and appends the result. That separation is what
makes the loop safe to reason about: the model's only superpower is structured
output, and every side-effecting capability is a tool you explicitly handed it.

### Why this matters

Once you have this loop, a lot of what looks like "AI magic" reduces to:
*pick the right set of tools, write a clear system prompt, let the model
iterate.* Web research, code analysis, file editing, shell execution, database
queries — they're all just tools wrapped around the same three-phase cycle.
The agent loop is the irreducible kernel; everything else is tool design.

## Using x.ai instead of a local model

The same demos work unchanged against [x.ai](https://x.ai)'s Grok models —
their API speaks the OpenAI Chat Completions shape, so only the `url`, `model`,
and `api_key` need to change.

### 1. Get an API key

Sign in at [console.x.ai](https://console.x.ai), open **API Keys**, and create
a new key. Export it so the demo scripts can pick it up without you committing
it to disk:

```sh
export XAI_API_KEY=xai-...
```

### 2. Point the client at x.ai

In `run.rb` or `run-leopard.rb`, swap the `OpenAIClient.new(...)` block for:

```ruby
client = OpenAIClient.new(
  url: 'https://api.x.ai/v1',
  model: 'grok-4.3',                          # or any current model from console.x.ai/models
  api_key: ENV.fetch('XAI_API_KEY'),
  tools: [...]
)
```

That's it — the agent loop, tools, and system prompt are unchanged. Run the
script the same way:

```sh
bundle exec ruby run-leopard.rb
```

## Further reading

- [HuggingFace smolagents](https://github.com/huggingface/smolagents) — the
  upstream Python project this one is modeled on.
- [Introducing smolagents (HuggingFace blog)](https://huggingface.co/blog/smolagents)
  — the announcement post; good high-level framing.
- [OpenAI function calling guide](https://platform.openai.com/docs/guides/function-calling)
  — the wire format every tool-calling model converges on.
