# frozen_string_literal: true

module Pikuri
  class Agent
    # Sealed value-object hierarchy describing a single event in the
    # +Agent+'s normalized stream. Every listener consumes these through
    # one {Listener::Base#on_event} entry point and pattern-matches on
    # the variant.
    #
    # Each variant is a +Data.define+ with the minimal fields it needs;
    # value equality and pattern-matching support come for free.
    #
    # == One stream, no side channels
    #
    # Provider-reported token usage rides as {Tokens}; the detected
    # context-window cap rides as a one-shot {ContextCap} emitted by
    # {Agent#initialize}; everything else maps to a turn-or-tool-call
    # variant. Listeners override a single +on_event+ method and
    # +case+-match on the variant they care about. The per-variant
    # docs below name the emission site for each (which {Agent}
    # callback wires it and what payload it carries).
    #
    # == Sealed for loop narration; gems add domain events
    #
    # "Sealed" applies to the *loop-narration* vocabulary: the
    # variants below are the complete set, all emitted by {Agent},
    # and new chat-loop observability belongs here, not in a gem.
    # Gems may define their own *domain* events in their own
    # namespace (e.g. +Pikuri::Tasks::ListChanged+) and emit them
    # via {ExtensionContext#emit_event}; they ride the same stream.
    # Listeners must no-op on variants they don't recognize —
    # {Listener::Base#on_event}'s default plus +case+-fallthrough
    # give that for free.
    module Event
      # User's input for a turn (+mid_loop: false+, the default) or a
      # host-supplied injection delivered while the loop is running
      # (+mid_loop: true+, drained from {Control::Interloper}). The
      # flag exists so listeners that treat the +UserTurn+ as a turn
      # boundary can distinguish a fresh turn from an in-loop
      # injection (additional context for the same turn, not a new
      # one). Controls themselves no longer see this event — the
      # +Agent+ pokes their +reset!+ / +tick!+ entry points directly
      # at the right boundaries.
      #
      # Emitted in two places: by {Agent#run_loop} at the start of
      # each turn (with +mid_loop: false+), and by {Agent}'s
      # +after_tool_result+ wiring when a queued
      # {Control::Interloper} item drains into the chat history
      # (with +mid_loop: true+).
      UserTurn = Data.define(:content, :mid_loop) do
        # @param content [String] user-supplied text
        # @param mid_loop [Boolean] +false+ for a turn-starting message
        #   (the default); +true+ when drained from
        #   {Control::Interloper}
        def initialize(content:, mid_loop: false)
          super
        end
      end

      # A system-role block an {Extension#on_user_message} hook
      # injected into the chat log — recalled reference (memory
      # context, retrieved snippets) tagged +role: :system+ so the
      # model reads it as background, not new user input. Carries
      # the injected text verbatim.
      #
      # Emitted by {Agent#dispatch_ext_on_user_message}, once per
      # extension that returns a non-empty block, at the same site
      # that grows the chat log — so the event stream stays a
      # faithful mirror of what the model actually sees. Without it
      # an injection is invisible: it never surfaces in the stream,
      # only as a secondary echo in the assistant's later reasoning.
      # {Listener::Terminal} renders it dim grey with a +⊕+ marker.
      SystemInjected = Data.define(:content)

      # Assistant reasoning ("thinking") block, extracted from the
      # +thinking.text+ field on a +RubyLLM::Message+ with role
      # +:assistant+. Emitted by {Agent}'s +after_message+ wiring;
      # empty +thinking.text+ is filtered at the dispatch site so
      # listeners never see vacuous events.
      Thinking = Data.define(:content)

      # Assistant Markdown content, extracted from a +RubyLLM::Message+
      # with role +:assistant+. Emitted by {Agent}'s +after_message+
      # wiring; empty +content+ is filtered at the dispatch site
      # (pure tool-call turns surface {Tokens} only, no +Assistant+).
      Assistant = Data.define(:content)

      # Streaming fragment of an assistant reasoning block, pulled
      # off a +RubyLLM::Chunk+ during a streaming completion.
      # Emitted by the per-chunk streaming block {Agent#run_loop}
      # passes to +Chat#complete+ when the agent's +streaming:+
      # flag is on; empty fragments are filtered at the dispatch
      # site.
      #
      # Preview-only, not authoritative: the {Thinking} event
      # emitted from +after_message+ at the end of the round-trip
      # is the final reasoning text. Providers may normalize
      # whitespace, and Anthropic thinking blocks include a
      # signature that never appears in deltas, so
      # +concat(deltas) == final.content+ is not guaranteed.
      #
      # == Ordering
      #
      # Per round-trip: all {ThinkingDelta}s (and {AssistantDelta}s)
      # for a round arrive before that round's {Thinking} /
      # {Assistant} / {Tokens} bookend, because the streaming block
      # fires synchronously inside +Chat#ask+'s SSE read and
      # +after_message+ fires once the message is complete. Within
      # the delta stream itself, ordering between {ThinkingDelta}
      # and {AssistantDelta} is provider-dependent (in practice
      # non-interleaved on Anthropic and OpenAI reasoning models,
      # but pikuri does not enforce it).
      ThinkingDelta = Data.define(:content)

      # Streaming fragment of an assistant Markdown content block,
      # pulled off a +RubyLLM::Chunk+ during a streaming
      # completion. Emitted by the per-chunk streaming block
      # {Agent#run_loop} passes to +Chat#complete+ when the
      # agent's +streaming:+ flag is on; empty fragments are
      # filtered at the dispatch site.
      #
      # Preview-only, same semantics as {ThinkingDelta}: the
      # {Assistant} event emitted from +after_message+ at the end
      # of the round-trip is the authoritative final text;
      # listeners that need an exact concat of fragments should
      # consume {Assistant} instead. Per-round-trip ordering is
      # guaranteed; per-modality ordering within the delta stream
      # is best-effort.
      AssistantDelta = Data.define(:content)

      # A tool invocation the LLM has requested but not yet observed.
      # Arguments are the raw hash ruby_llm parsed from the model's
      # +tool_calls+ JSON — no validation has run yet. Emitted by
      # {Agent}'s +before_tool_call+ wiring.
      ToolCall = Data.define(:name, :arguments)

      # The observation a tool produced, as returned by {Tool#run}.
      # Recoverable failures arrive here as +"Error: ..."+ strings
      # (per the pikuri error convention), not as exceptions.
      # Emitted by {Agent}'s +after_tool_result+ wiring.
      ToolResult = Data.define(:content)

      # Provider-reported token usage for a single assistant turn,
      # copied off a +RubyLLM::Message+'s +tokens+ block. Emitted by
      # {Agent}'s +after_message+ wiring on every assistant turn,
      # including pure tool-call turns where {Assistant} would have
      # been filtered for empty content (those are exactly the turns
      # where context-window growth matters most).
      #
      # All counts are +Integer, nil+. +nil+ means the provider did not
      # report that field — common with local llama.cpp / Ollama
      # servers that leave parts of the OpenAI +usage+ block empty.
      # Listeners treat +nil+ as zero.
      #
      # The fields +input+, +cached+, and +cache_creation+ are
      # **exclusive portions of this turn's full prompt** under the
      # shape ruby_llm exposes for llama.cpp and Anthropic: they sum
      # to the total prompt size processed on this request. OpenAI
      # proper nests +cached_tokens+ inside its +prompt_tokens+
      # instead — if pikuri ever talks there directly, the sum formula
      # needs revisiting.
      #
      # - +input+ — newly-processed (uncached) prompt tokens this turn.
      # - +output+ — tokens in this single assistant reply.
      # - +cached+ — portion of this turn's prompt served from the
      #   provider's prompt cache. Still counts against the context
      #   window (caching is a speed/cost optimization, not a context-
      #   savings mechanism).
      # - +cache_creation+ — portion of this turn's prompt written
      #   into the prompt cache. Anthropic-specific; usually +nil+ on
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
      # processed on this turn. Add +output+ to get tokens consumed by
      # the conversation *through* this turn — this turn's prompt plus
      # its reply, both of which the model will re-process on the next
      # turn. That's what climbs toward
      # +RubyLLM::ContextLengthExceededError+ and is the snapshot
      # {Listener::TokenLog#context_window_size} tracks.
      Tokens = Data.define(:input, :output, :cached, :cache_creation, :thinking, :model_id)

      # Model's resolved context-window cap. Emitted at construction
      # by {Agent#initialize}, and again after every model switch
      # (see {Agent#run_loop}'s +transport:+) since the cap is a
      # property of the model. Carries +nil+ when no source produced
      # a value (a non-llama server with no explicit cap). Listeners
      # that care — {Listener::TokenLog} renders +ctx=<used>/<cap>+
      # when set, +ctx=<used>+ when +nil+ — pick the value off this
      # event and cache it; non-caring listeners ignore. A second
      # ContextCap simply overwrites the first; the conversation is
      # not re-baselined (a switch keeps the running context size).
      ContextCap = Data.define(:cap)

      # The agent switched to a different model mid-conversation,
      # emitted by {Agent#run_loop} (via +apply_transport!+) just
      # before the matching {ContextCap} for the new model. Carries
      # the old and new {Agent::ChatTransport}s verbatim — unformatted
      # by design, so each chrome presents them its own way (a TUI
      # adds ANSI off +.model+, a web client adds CSS). The cap rides
      # on the paired {ContextCap}, not here, so {Listener::TokenLog}
      # needs no awareness of this event (its existing {ContextCap}
      # arm picks up the new cap); a renderer wanting "switched to X
      # (128k)" on one line correlates the two.
      ModelSwitched = Data.define(:from, :to)

      # Out-of-band notice that the agent had to take a rescue path.
      # Emitted by {Agent#run_loop} when {Control::StepLimit} trips
      # and the synthesizer fallback runs; carries the reason string
      # the listener should surface. Lets listeners (Terminal, future
      # web UI) surface the divergence to the user before the
      # synthesizer's own assistant output flows through.
      FallbackNotice = Data.define(:reason)

      # Out-of-band notice that the user cancelled the in-flight turn
      # via {Control::Cancellable}. Emitted by {Agent#run_loop} just
      # before the +Cancellable::Cancelled+ exception re-raises out of
      # the loop, so listeners (Terminal renderer, structured
      # recorders) can mark the turn as user-aborted. Unlike
      # {FallbackNotice}, no recovery follows — the exception is
      # re-raised and the caller is expected to return control to the
      # user (typically the REPL prompt).
      Cancelled = Data.define

      # The conversation log was cleared by {Agent#clear_conversation}
      # (a host "/clear"): the chat history is back to just the system
      # prompt, the controls are reset, and each extension's
      # {Extension#on_conversation_reset} has run to drop its
      # conversation-scoped state. Emitted once per clear, *before* the
      # extension sweep, so pure-consumer listeners reset their own
      # display state off it — {Listener::TokenLog} zeroes its running
      # context-size snapshot (otherwise a stale +ctx=+ headline would
      # linger beside an empty conversation until the next turn
      # self-corrected it), and a chrome can render a "context cleared"
      # separator. Extension-owned state is *not* signalled here; those
      # extensions emit their own domain events from
      # {Extension#on_conversation_reset} (e.g. +Tasks::ListChanged+
      # with an empty list). Carries no payload — a clear has nothing to
      # report beyond having happened.
      Reset = Data.define
    end
  end
end
