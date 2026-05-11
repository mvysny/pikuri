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
  # All counts in the +input+ family below (+input+, +cached+,
  # +cache_creation+) are **exclusive portions of this turn's full
  # prompt** under the shape ruby_llm exposes for llama.cpp and
  # Anthropic: they sum to the total prompt size processed on this
  # request. OpenAI proper nests +cached_tokens+ inside its
  # +prompt_tokens+ instead — if pikuri ever talks there directly,
  # the sum formula needs revisiting.
  #
  # Caching is a cost / speed optimization, not a context-window
  # savings mechanism: cached tokens still occupy slots in the
  # model's context window because the model still attends over them.
  #
  # - +input+ — *newly-processed* prompt tokens on this request —
  #   the portion of this turn's prompt that wasn't served from the
  #   cache. Per-turn delta (sums across turns to give total
  #   uncached compute), NOT a cumulative snapshot — each turn's
  #   value fluctuates with how much of the growing prompt is
  #   already cached.
  # - +output+ — tokens in this single assistant reply. Per-turn
  #   delta. Bounded by the provider's max-output cap (typically
  #   4-8K for chat completions). Output of turn N becomes part of
  #   turn N+1's prompt — that's why the loop-wide "context climb"
  #   is measured on the +input+ family, not on +output+.
  # - +cached+ — portion of this turn's prompt served from the
  #   provider's prompt cache. Per-turn delta. Still counted against
  #   the context window (caching is a speed/cost optimization, not
  #   a context-savings mechanism).
  # - +cache_creation+ — portion of this turn's prompt *written into*
  #   the prompt cache. Per-turn delta. Anthropic-specific; usually
  #   +nil+ on OpenAI-compatible local servers.
  # - +thinking+ — extended-thinking (Anthropic) or reasoning
  #   (OpenAI o-series) tokens produced on this turn. Per-turn
  #   delta. Charged separately from +output+. +nil+ on providers
  #   without a reasoning channel.
  # - +model_id+ — provider-side model name as reported on the
  #   response; useful when a process targets multiple models.
  #
  # == Computing "current context window size"
  #
  # The full size of the prompt the model processed on this turn —
  # i.e. the conversation's current consumption against the model's
  # context-window cap — is +input + cached + cache_creation+. That
  # number is what climbs toward +RubyLLM::ContextLengthExceededError+
  # and is the snapshot {Listener::TokenLog#context_window_size}
  # tracks.
  Tokens = Data.define(:input, :output, :cached, :cache_creation, :thinking, :model_id)
end
