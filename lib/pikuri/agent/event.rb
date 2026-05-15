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
    # Pikuri used to ship two parallel channels — a +Message+ stream
    # (User / Thinking / Assistant / ToolCall / ToolResult /
    # FallbackNotice / Cancelled) and an +on_tokens+ side channel for
    # provider-reported usage — plus a special +context_window_cap=+
    # setter that the +ListenerList+ poked just at +TokenLog+. That
    # design forced every new listener to know which hook to override
    # and which to ignore.
    #
    # The new shape collapses all three into one event stream:
    # provider-reported token usage rides as {Tokens}; the detected
    # context-window cap rides as a one-shot {ContextCap} emitted by
    # {Agent#initialize}; everything else maps to a turn-or-tool-call
    # variant. Listeners override a single +on_event+ method and
    # +case+-match on the variant they care about.
    #
    # == Where each variant comes from
    #
    # * {UserTurn} — synthesized by {Agent#run_loop} at the start of
    #   each turn (+mid_loop: false+), or by {Agent}'s
    #   +after_tool_result+ wiring when a queued
    #   {Control::Interloper} item drains into the chat history
    #   (+mid_loop: true+).
    # * {Thinking} / {Assistant} — extracted by {Agent}'s
    #   +after_message+ wiring from a +RubyLLM::Message+ with role
    #   +:assistant+. Empty +thinking.text+ and empty +content+ are
    #   filtered at the dispatch site so listeners never see vacuous
    #   events.
    # * {ToolCall} — emitted by {Agent}'s +before_tool_call+ wiring,
    #   carrying the tool's name and the LLM-supplied argument hash.
    # * {ToolResult} — emitted by {Agent}'s +after_tool_result+ wiring,
    #   carrying the observation string the tool produced.
    # * {Tokens} — emitted by {Agent}'s +after_message+ wiring on every
    #   assistant turn, including pure tool-call turns with empty
    #   content (those are exactly the turns where context-window
    #   growth matters most).
    # * {ContextCap} — emitted once by {Agent#initialize} immediately
    #   after {Agent::ContextWindowDetector} resolves a cap. Carries
    #   +nil+ when no source produced one — listeners that care about
    #   the cap can treat +nil+ as "no cap known."
    # * {FallbackNotice} — emitted by {Agent#run_loop} when the
    #   step-budget rescue fires; carries the reason string the
    #   listener should surface.
    # * {Cancelled} — emitted by {Agent#run_loop} when
    #   {Control::Cancellable} trips; emitted just before the exception
    #   re-raises out of the loop.
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
      UserTurn = Data.define(:content, :mid_loop) do
        # @param content [String] user-supplied text
        # @param mid_loop [Boolean] +false+ for a turn-starting message
        #   (the default); +true+ when drained from
        #   {Control::Interloper}
        def initialize(content:, mid_loop: false)
          super
        end
      end

      # Assistant reasoning ("thinking") block, extracted from the
      # +thinking.text+ field on a +RubyLLM::Message+ with role
      # +:assistant+.
      Thinking = Data.define(:content)

      # Assistant Markdown content, extracted from a +RubyLLM::Message+
      # with role +:assistant+.
      Assistant = Data.define(:content)

      # A tool invocation the LLM has requested but not yet observed.
      # Arguments are the raw hash ruby_llm parsed from the model's
      # +tool_calls+ JSON — no validation has run yet.
      ToolCall = Data.define(:name, :arguments)

      # The observation a tool produced, as returned by {Tool#run}.
      # Recoverable failures arrive here as +"Error: ..."+ strings
      # (per the pikuri error convention), not as exceptions.
      ToolResult = Data.define(:content)

      # Provider-reported token usage for a single assistant turn,
      # copied off a +RubyLLM::Message+'s +tokens+ block. Fires once
      # per assistant +after_message+ event (including pure tool-call
      # turns where {Assistant} would have been filtered for empty
      # content).
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

      # Model's resolved context-window cap, emitted once by
      # {Agent#initialize} immediately after
      # {Agent::ContextWindowDetector} runs. Carries +nil+ when no
      # source produced a value (custom local model with no override
      # and no reachable llama.cpp +/props+). Listeners that care —
      # {Listener::TokenLog} renders +ctx=<used>/<cap>+ when set,
      # +ctx=<used>+ when +nil+ — pick the value off this event and
      # cache it; non-caring listeners ignore.
      ContextCap = Data.define(:cap)

      # Out-of-band notice that the agent had to take a rescue path —
      # currently emitted by {Agent#run_loop} when
      # {Control::StepLimit} trips and the synthesizer fallback runs.
      # Lets listeners (Terminal, future web UI) surface the
      # divergence to the user before the synthesizer's own assistant
      # output flows through.
      FallbackNotice = Data.define(:reason)

      # Out-of-band notice that the user cancelled the in-flight turn
      # via {Control::Cancellable}. Emitted by {Agent#run_loop} just
      # before the +Cancellable::Cancelled+ exception bubbles out so
      # listeners (Terminal renderer, structured recorders) can mark
      # the turn as user-aborted. Unlike {FallbackNotice}, no recovery
      # follows — the exception is re-raised and the caller is
      # expected to return control to the user (typically the REPL
      # prompt).
      Cancelled = Data.define
    end
  end
end
