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

Point `pikuri.rb` at your backend by editing the `OpenAIClient.new(...)` call
(`url`, `model`, `api_key`).

If you want web search via Brave, set `BRAVE_SEARCH_API_KEY`; otherwise it
falls back to scraping DuckDuckGo.

Then ask it something:

```sh
bundle exec ruby pikuri.rb "What is 17 * 23, and who won the 2022 World Cup?"
```

Or run it without arguments for an interactive prompt:

```sh
bundle exec ruby pikuri.rb
```

## Tests

```sh
bundle exec rspec
```
