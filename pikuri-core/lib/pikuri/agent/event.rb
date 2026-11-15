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
    # their own namespace (e.g. a task list's +ListChanged+) and emit
    # them via {Configurator#emit_event} onto the same stream;
    # listeners must no-op on variants they don't recognize. A domain event's
    # +#to_s+ is its whole rendering in a generic listener, which never reads
    # its fields — that keeps core ignorant of a gem's payload. Why one open
    # stream: +design/decisions.md+ +D_domain_events+.
    module Event
      # User input for a turn (+mid_loop: false+, the default) or a host
      # injection delivered mid-loop (+mid_loop: true+, drained from
      # {Control::Interloper}). The flag lets a listener treating
      # +UserTurn+ as a turn boundary tell a fresh turn from an in-loop
      # injection. Emitted by {Agent#run_loop} at turn start, and when an
      # interloper item drains in after a tool batch.
      #
      # Carries the attachments themselves, not a handle to look up: a
      # listener has no {Agent::History} to resolve one against, and the bytes are
      # shared with the chat, not copied.
      UserTurn = Data.define(:content, :attachments, :mid_loop) do
        # @param content [String] user-supplied text; +""+ on an
        #   attachment-only turn
        # @param attachments [Array<Pikuri::Attachment>] what the model was
        #   shown; mid-loop, without any it can't take, whose notes are then in
        #   +content+
        # @param mid_loop [Boolean] +true+ when drained from
        #   {Control::Interloper}; default +false+
        def initialize(content:, attachments: [], mid_loop: false)
          super(content: content, attachments: attachments.dup.freeze, mid_loop: mid_loop)
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
      # +""+ renders the call bare — +Name+, not +Name()+.
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
      # exceptions, and their summary is that message. An image observation
      # arrives as its text note (+"Read image: shot.png (2048 bytes, …)"+); the
      # bytes go to the model only.
      #
      # +tool_call_id+ pairs this with its {ToolCall} by key, so a renderer
      # needs no assumption about call→result ordering. Both carry the
      # server's id, the one {History} stores.
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

      # Agent switched model mid-conversation. Emitted by {Agent#run_loop}
      # ahead of that turn's {UserTurn}. Carries both {Agent::ChatTransport}s
      # verbatim and unformatted — each chrome presents them its own way; the
      # new model's stated cap and modalities ride on +to+.
      ModelSwitched = Data.define(:from, :to)

      # Out-of-band notice that the user cancelled the in-flight turn via
      # {Control::Cancellable}. Emitted by {Agent#run_loop} just before the
      # +Cancelled+ exception re-raises. No recovery follows; the caller
      # returns control to the user.
      Cancelled = Data.define

      # The agent was built with a saved conversation (+Agent.new(history:)+)
      # rather than an empty one. Emitted once, at the end of construction,
      # and carries what a listener needs to stop reporting an empty
      # conversation.
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

      # The conversation was swapped for a compacted rendering of itself
      # ({Configurator#replace_compacted_history}); tools, extensions and the
      # system prompt stand as they were.
      #
      # Carries no token counts: what the shorter conversation costs is known
      # only once the next reply reports usage.
      #
      # @!attribute [r] messages_before
      #   @return [Integer] how many messages the conversation held
      # @!attribute [r] messages_after
      #   @return [Integer] how many it holds now
      HistoryCompacted = Data.define(:messages_before, :messages_after)
    end
  end
end
