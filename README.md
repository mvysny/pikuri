# pikuri

A small Ruby AI assistant built around the Thought / Tool-call / Observation
loop. Talks to any OpenAI-compatible chat completions backend (local
[llama.cpp](https://github.com/ggml-org/llama.cpp) server, [x.ai](https://x.ai),
…) and ships with a calculator, a web search tool, and sub-agent delegation.

## Running it

Install dependencies:

```sh
bundle install
```

Point `bin/pikuri-chat` at your backend by editing the `OpenAIClient.new(...)` call
(`url`, `model`, `api_key`).

If you want web search via Brave, set `BRAVE_SEARCH_API_KEY`; otherwise it
falls back to scraping DuckDuckGo.

Then ask it something:

```sh
./bin/pikuri-chat "What is 17 * 23, and who won the 2022 World Cup?"
```

Or run it without arguments for an interactive prompt:

```sh
./bin/pikuri-chat
```

## Tests

```sh
bundle exec rspec
```
