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
  # empty content. Those are exactly the turns where context-window
  # growth matters most.
  #
  # All counts are +Integer, nil+. +nil+ means the provider did not
  # report that field — common with local llama.cpp / Ollama servers
  # that leave parts of the OpenAI +usage+ block empty. Listeners
  # treat +nil+ as zero.
  #
  # The fields +input+, +cached+, and +cache_creation+ are
  # **exclusive portions of this turn's full prompt** under the shape
  # ruby_llm exposes for llama.cpp and Anthropic: they sum to the
  # total prompt size processed on this request. OpenAI proper nests
  # +cached_tokens+ inside its +prompt_tokens+ instead — if pikuri
  # ever talks there directly, the sum formula needs revisiting.
  #
  # - +input+ — newly-processed (uncached) prompt tokens this turn.
  # - +output+ — tokens in this single assistant reply.
  # - +cached+ — portion of this turn's prompt served from the
  #   provider's prompt cache. Still counts against the context
  #   window (caching is a speed/cost optimization, not a context-
  #   savings mechanism).
  # - +cache_creation+ — portion of this turn's prompt written into
  #   the prompt cache. Anthropic-specific; usually +nil+ on
  #   OpenAI-compatible local servers.
  # - +thinking+ — extended-thinking (Anthropic) or reasoning
  #   (OpenAI o-series) tokens produced on this turn. +nil+ on
  #   providers without a reasoning channel.
  # - +model_id+ — provider-side model name as reported on the
  #   response; useful when a process targets multiple models.
  #
  # == Computing "current context window size"
  #
  # +input + cached + cache_creation+ is the size of the prompt
  # processed on this turn. Add +output+ to get tokens consumed by the
  # conversation *through* this turn — this turn's prompt plus its
  # reply, both of which the model will re-process on the next turn.
  # That's what climbs toward +RubyLLM::ContextLengthExceededError+
  # and is the snapshot {Listener::TokenLog#context_window_size}
  # tracks (without the +output+ term, a long reply stays invisible
  # in the headline until the next turn pulls it in as cached prompt).
  Tokens = Data.define(:input, :output, :cached, :cache_creation, :thinking, :model_id)
end
