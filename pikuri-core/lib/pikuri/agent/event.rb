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
      # injection. Emitted by {Agent#run_loop} at turn start, and when an
      # interloper item drains in after a tool batch.
      UserTurn = Data.define(:content, :mid_loop) do
        # @param content [String] user-supplied text
        # @param mid_loop [Boolean] +true+ when drained from
        #   {Control::Interloper}; default +false+
        def initialize(content:, mid_loop: false)
          super
        end
      end

      # A reference block injected into the chat log — recalled memory, a
      # host-loaded skill, a path-activation promotion, retrieved snippets.
      # Carries the block *unwrapped*, without the +<system-reminder>+
      # envelope {Agent#append_reference_block} sends it under, so a listener
      # renders what the host wrote rather than pikuri's framing.
      #
      # Named for the *role it plays* (background reference, not new user
      # input), not the wire role it lands under — which is +:user+, because a
      # mid-conversation +:system+ message is unportable.
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

      # A tool the LLM requested but hasn't observed yet. +display_name+ and
      # +argument+ are what a chrome puts on the screen:
      #
      #   → Write(lib/shared/config.rb)
      #
      # +arguments+ is the raw hash ruby_llm parsed from the model's
      # +tool_calls+ JSON — unvalidated; the two display strings are the tool's
      # own ({Tool#display_name} / {Tool#describe_call}), so every chrome prints
      # the same line and only styles, caps and defangs it. An +argument+ of
      # +""+ renders the call bare — +EnterPlanMode+, not +EnterPlanMode()+.
      #
      # Strings rather than a +tool:+ reference a renderer could query: the
      # event must stay plain serializable +Data+, and three cases have no
      # {Pikuri::Tool} to query at all — an MCP tool, ruby_llm's
      # unavailable-tool error, a replayed conversation.
      #
      # Emitted by +before_tool_call+.
      ToolCall = Data.define(:tool_call_id, :name, :arguments, :display_name, :argument)

      # The observation a tool produced ({Tool#run}'s return), plus the
      # one-line +summary+ a chrome shows in its place (+"Returned 23 search
      # results"+). Recoverable failures arrive as +"Error: ..."+ strings, not
      # exceptions, and their summary is that message.
      #
      # +tool_call_id+ pairs this with its {ToolCall} by key, so a renderer
      # needs no assumption about call→result ordering.
      #
      # Emitted by +after_tool_result+, and by {Agent#run_loop}'s
      # dangling-call repair (summary +"Interrupted"+).
      ToolResult = Data.define(:tool_call_id, :name, :content, :summary)

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

      # Out-of-band notice that the user cancelled the in-flight turn via
      # {Control::Cancellable}. Emitted by {Agent#run_loop} just before the
      # +Cancelled+ exception re-raises. No recovery follows; the caller
      # returns control to the user.
      Cancelled = Data.define

      # Marks a *domain* event whose successor **replaces** it rather than adding
      # to a log: an indexing bar, a download percentage. A chrome that can
      # rewrite a line does; one that cannot shows only the final state.
      #
      #   Progress = Data.define(:title, :done) do
      #     include Pikuri::Agent::Event::Transient
      #     def to_s = done ? "#{title} — done" : title
      #   end
      #
      # The contract is two methods, both of which a +Data.define+ already
      # answers: +#to_s+ is the whole rendering — a listener never inspects the
      # fields, which is what keeps core ignorant of a gem's payload — and
      # +#done+ says the sequence is over and its line may go away.
      module Transient
      end

      # The conversation was cleared by {Agent#clear_conversation}: history
      # is back to the system prompt, controls are reset, and each
      # extension's {Extension#on_conversation_reset} has run. Emitted
      # once, *before* the extension sweep, so pure-consumer listeners can
      # reset display state; extension-owned state is signalled by the
      # extensions' own domain events, not here. No payload.
      Reset = Data.define

      # A saved conversation was restored by {Agent#load_history!}. Always
      # follows a {Reset}, which is the part that clears display state — this
      # one says the conversation is *not* empty after all, and carries what a
      # listener needs to stop lying about it.
      #
      # +tokens+ is the last assistant message's usage as recorded when the
      # conversation was exported, so a running context readout can pick up
      # where it left off instead of showing +0+ against 40k of restored
      # history. +nil+ when the history holds no assistant turn, or was
      # exported without usage.
      #
      # @!attribute [r] messages
      #   @return [Integer] how many messages were restored
      # @!attribute [r] tokens
      #   @return [Tokens, nil] usage of the last restored assistant message
      HistoryLoaded = Data.define(:messages, :tokens)
    end
  end
end
