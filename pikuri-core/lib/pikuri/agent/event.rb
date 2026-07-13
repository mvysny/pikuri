# frozen_string_literal: true

module Pikuri
  class Agent
    # Sealed value-object hierarchy for the +Agent+'s normalized event
    # stream. Listeners consume every variant through one
    # {Listener::Base#on_event} and +case+-match on it.
    #
    # "Sealed" scopes the *loop-narration* vocabulary: the variants below
    # are the complete set, all emitted by {Agent}, and new chat-loop
    # observability belongs here. Gems define their own *domain* events in
    # their own namespace (e.g. +Pikuri::Tasks::ListChanged+) and emit
    # them via {ExtensionContext#emit_event} onto the same stream;
    # listeners must no-op on variants they don't recognize.
    module Event
      # User input for a turn (+mid_loop: false+, the default) or a host
      # injection delivered mid-loop (+mid_loop: true+, drained from
      # {Control::Interloper}). The flag lets a listener treating
      # +UserTurn+ as a turn boundary tell a fresh turn from an in-loop
      # injection. Emitted by {Agent#run_loop} at turn start, and by
      # +after_tool_result+ when an interloper item drains in.
      UserTurn = Data.define(:content, :mid_loop) do
        # @param content [String] user-supplied text
        # @param mid_loop [Boolean] +true+ when drained from
        #   {Control::Interloper}; default +false+
        def initialize(content:, mid_loop: false)
          super
        end
      end

      # A +role: :system+ block an {Extension#on_user_message} hook
      # injected into the chat log (recalled memory, retrieved snippets) —
      # tagged system so the model reads it as background, not new user
      # input. Carries the injected text verbatim. Emitted by
      # {Agent#dispatch_ext_on_user_message} at the site that grows the
      # chat log, once per extension returning a non-empty block, so the
      # stream mirrors what the model actually sees.
      SystemInjected = Data.define(:content)

      # Assistant reasoning ("thinking") block, from +thinking.text+ on a
      # +RubyLLM::Message+. Emitted by +after_message+; empty text is
      # filtered at the dispatch site.
      Thinking = Data.define(:content)

      # Assistant Markdown content, from a +RubyLLM::Message+. Emitted by
      # +after_message+; empty content is filtered (pure tool-call turns
      # surface {Tokens} only).
      Assistant = Data.define(:content)

      # Streaming fragment of a reasoning block, off a +RubyLLM::Chunk+
      # when +streaming:+ is on. Emitted per-chunk by {Agent#run_loop};
      # empty fragments filtered.
      #
      # Preview-only: the {Thinking} from +after_message+ is
      # authoritative. +concat(deltas) == final+ is not guaranteed
      # (whitespace normalization, Anthropic signature blocks). All of a
      # round's deltas arrive before that round's
      # {Thinking}/{Assistant}/{Tokens} bookend; {ThinkingDelta} vs
      # {AssistantDelta} interleave order is provider-dependent.
      ThinkingDelta = Data.define(:content)

      # Streaming fragment of assistant Markdown, off a +RubyLLM::Chunk+
      # when +streaming:+ is on. Same preview-only semantics as
      # {ThinkingDelta}; consume {Assistant} for the authoritative text.
      AssistantDelta = Data.define(:content)

      # A tool the LLM requested but hasn't observed yet. +arguments+ is
      # the raw hash ruby_llm parsed from the model's +tool_calls+ JSON —
      # unvalidated. Emitted by +before_tool_call+.
      ToolCall = Data.define(:name, :arguments)

      # The observation a tool produced ({Tool#run}'s return). Recoverable
      # failures arrive as +"Error: ..."+ strings, not exceptions. Emitted
      # by +after_tool_result+.
      ToolResult = Data.define(:content)

      # Provider-reported token usage for one assistant turn, off a
      # +RubyLLM::Message+'s +tokens+ block. Emitted by +after_message+ on
      # every assistant turn (including pure tool-call turns, where
      # context growth matters most).
      #
      # Every count is +Integer, nil+; +nil+ means the provider omitted
      # the field (common on local llama.cpp/Ollama) and is treated as
      # zero. +input+/+cached+/+cache_creation+ are *exclusive* slices of
      # this turn's prompt and sum to its total size (llama.cpp +
      # Anthropic shape; OpenAI nests +cached+ inside +input+, so revisit
      # the sum if pikuri ever targets it directly). +cached+ still counts
      # against the context window.
      #
      # - +input+ — newly-processed (uncached) prompt tokens this turn.
      # - +output+ — tokens in this reply.
      # - +cached+ — prompt tokens served from the provider's cache.
      # - +cache_creation+ — prompt tokens written to the cache (Anthropic).
      # - +thinking+ — reasoning tokens (Anthropic thinking / OpenAI
      #   o-series); +nil+ without a reasoning channel.
      # - +model_id+ — provider-side model name on the response.
      Tokens = Data.define(:input, :output, :cached, :cache_creation, :thinking, :model_id)

      # Model's resolved context-window cap (+nil+ if unknown). Emitted at
      # construction and after each model switch. A later ContextCap
      # overwrites the prior; the running context size is not re-baselined.
      ContextCap = Data.define(:cap)

      # Agent switched model mid-conversation. Emitted by {Agent#run_loop}
      # just before the new model's {ContextCap}. Carries both
      # {Agent::ChatTransport}s verbatim and unformatted — each chrome
      # presents them its own way. The new cap rides on the paired
      # {ContextCap}, not here.
      ModelSwitched = Data.define(:from, :to)

      # Out-of-band notice that a rescue path was taken: emitted by
      # {Agent#run_loop} when {Control::StepLimit} trips and the
      # {Synthesizer} fallback runs. Carries the reason to surface before
      # the synthesizer's own output flows through.
      FallbackNotice = Data.define(:reason)

      # Out-of-band notice that the user cancelled the in-flight turn via
      # {Control::Cancellable}. Emitted by {Agent#run_loop} just before the
      # +Cancelled+ exception re-raises — unlike {FallbackNotice}, no
      # recovery follows; the caller returns control to the user.
      Cancelled = Data.define

      # The conversation was cleared by {Agent#clear_conversation}: history
      # is back to the system prompt, controls are reset, and each
      # extension's {Extension#on_conversation_reset} has run. Emitted
      # once, *before* the extension sweep, so pure-consumer listeners can
      # reset display state; extension-owned state is signalled by the
      # extensions' own domain events, not here. No payload.
      Reset = Data.define
    end
  end
end
