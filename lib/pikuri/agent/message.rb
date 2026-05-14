# frozen_string_literal: true

module Pikuri
  class Agent
    # Sealed value-object hierarchy describing a single event in the
    # +Agent+'s normalized stream. Listeners (Terminal renderer,
    # in-memory recorder, future web sink) receive these through one
    # +Listener::MessageListener#on_message+ entry point and dispatch on
    # the variant's class.
    #
    # Each variant is a +Data.define+ with the minimal fields it needs;
    # value equality and pattern-matching support come for free.
    #
    # == Where each variant comes from
    #
    # * {User} — synthesized by {Agent#run_loop} before forwarding the
    #   turn to +Chat#ask+. Never appears in ruby_llm's listener stream.
    # * {Thinking} / {Assistant} — extracted from a +Chat#after_message+
    #   payload when the role is +:assistant+. Empty +thinking.text+ and
    #   empty +content+ are filtered out at the dispatch site so
    #   listeners never see vacuous events.
    # * {ToolCall} — emitted on +Chat#before_tool_call+, carrying the
    #   tool's name and the LLM-supplied argument hash.
    # * {ToolResult} — emitted on +Chat#after_tool_result+, carrying the
    #   observation string the tool produced.
    # * {FallbackNotice} — synthesized by {Agent#run_loop} when the
    #   step-budget rescue fires; carries the reason string the listener
    #   should surface.
    # * {Cancelled} — synthesized by {Agent#run_loop} when
    #   {Listener::Cancellable} trips; emitted just before the exception
    #   re-raises out of the loop.
    #
    # Provider-reported token usage is *not* a {Message} variant — it's
    # metadata about an exchange, not an event in it. See {Agent::Tokens}
    # and {Listener::MessageListener#on_tokens}.
    module Message
      # User's input for a turn, as passed to {Agent#run_loop}.
      User = Data.define(:content)

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

      # The observation a tool produced, as returned by
      # {Tool#run}. Recoverable failures arrive here as +"Error: ..."+
      # strings (per the pikuri error convention), not as exceptions.
      ToolResult = Data.define(:content)

      # Out-of-band notice that the agent had to take a rescue path —
      # currently emitted by {Agent#run_loop} when {Listener::StepLimit}
      # trips and the synthesizer fallback runs. Lets listeners (Terminal,
      # future web UI) surface the divergence to the user before the
      # synthesizer's own assistant output flows through.
      FallbackNotice = Data.define(:reason)

      # Out-of-band notice that the user cancelled the in-flight turn via
      # {Listener::Cancellable}. Emitted by {Agent#run_loop} just before
      # the +Cancellable::Cancelled+ exception bubbles out so listeners
      # (Terminal renderer, structured recorders) can mark the turn as
      # user-aborted. Unlike {FallbackNotice}, no recovery follows — the
      # exception is re-raised and the caller is expected to return
      # control to the user (typically the REPL prompt).
      Cancelled = Data.define
    end
  end
end
