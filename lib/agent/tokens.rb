# frozen_string_literal: true

class Agent
  # Provider-reported token usage for a single assistant turn, copied
  # off a +RubyLLM::Message+'s +tokens+ block. Delivered to listeners
  # through {Listener::MessageListener#on_tokens} rather than the
  # {Message} stream — it's metadata about an exchange, not an event
  # in it.
  #
  # Emitted by {Listener::MessageListener#dispatch_chat_message} on
  # every assistant +after_message+ event, including pure tool-call
  # turns where {Message::Assistant} would have been filtered out for
  # empty content. Those are exactly the turns where input-token
  # growth matters most.
  #
  # == Field meanings
  #
  # All counts are +Integer, nil+. +nil+ means the provider did not
  # report that field — common with local llama.cpp / Ollama servers
  # that leave parts of the OpenAI +usage+ block empty. Listeners
  # treat +nil+ as "unknown"; {Listener::TokenLog}'s session
  # accumulator coerces it to zero so the running total stays additive.
  #
  # - +input+ — prompt tokens the provider billed for this request.
  #   This is the **conversation's cumulative size as seen by the
  #   model on this turn**: full message history + system prompt +
  #   tool definitions + the latest user / tool-result message. It
  #   grows monotonically across the loop (ruby_llm re-sends the
  #   whole +@messages+ array each iteration), bounded by the
  #   model's context window. This is the number to watch for
  #   approaching +RubyLLM::ContextLengthExceededError+. **Do NOT
  #   sum +input+ across turns** — each value is already cumulative
  #   (a snapshot of the whole prompt), so summing snapshots would
  #   double-count. The other fields below *are* per-turn deltas and
  #   sum normally.
  # - +output+ — tokens in this single assistant reply. Per-turn,
  #   does NOT accumulate across turns. Bounded by the provider's
  #   max-output cap (typically 4-8K for chat completions).
  # - +cached+ — input tokens that hit the provider's prompt cache.
  #   Discounted on the bill but **still counted against the
  #   context window** — caching is a cost optimization, not a
  #   context-savings mechanism. Anthropic-specific; usually +nil+
  #   on OpenAI-compatible local servers.
  # - +cache_creation+ — input tokens *written into* the prompt
  #   cache on this request. Also counts against context.
  #   Anthropic-specific.
  # - +thinking+ — extended-thinking (Anthropic) or reasoning
  #   (OpenAI o-series) tokens produced on this turn. Charged
  #   separately from +output+. +nil+ on providers without a
  #   reasoning channel.
  # - +model_id+ — provider-side model name as reported on the
  #   response; useful when a process targets multiple models.
  Tokens = Data.define(:input, :output, :cached, :cache_creation, :thinking, :model_id)
end
