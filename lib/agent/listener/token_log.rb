# frozen_string_literal: true

class Agent
  module Listener
    # Logs the conversation's context-window consumption per assistant
    # turn via +Pikuri.logger_for('Tokens')+. Overrides
    # {MessageListener#on_tokens} and emits one +INFO+ line per turn.
    #
    # Existence rationale: catch context-window growth before the
    # provider raises +RubyLLM::ContextLengthExceededError+. +ctx+ is
    # the headline number — the size of the prompt the model processed
    # this turn. The +Δ+ field shows the climb between turns; +↑+ /
    # +↓+ are the per-turn input / output sizes that drove it
    # (matching Claude Code's convention: +↑+ is what's sent to the
    # model, +↓+ is what comes back).
    #
    # == State and scope
    #
    # The latest snapshot lives on the instance, so one +TokenLog+ is
    # per-conversation. Sub-agents (with their own +RubyLLM::Chat+) get
    # a fresh instance via {#for_sub_agent} (dispatched by
    # {ListenerList#for_sub_agent}) so their counts log against their
    # own chat. The synthesizer rescue keeps using the parent's
    # instance because synth turns extend the same conversation.
    #
    # == Log line shape
    #
    # Without a cap (no detection source — see {Agent::ContextWindowDetector}):
    #
    #   msg #1: ctx=6.8k  Δ+6.8k  ↑6.8k  ↓0.0k
    #   msg #2: ctx=9.1k  Δ+2.3k  ↑1.0k  ↓0.6k
    #
    # With a cap of e.g. 32k (set by {Agent#initialize} after detection):
    #
    #   msg #1: ctx=6.8k/32.0k  Δ+6.8k  ↑6.8k  ↓0.0k
    #
    # When the owning {Agent} has a non-empty {Agent#name} (i.e. a
    # sub-agent), the line is prefixed with +[name] +:
    #
    #   [sub_agent 0] msg #1: ctx=4.2k  Δ+4.2k  ↑4.2k  ↓0.0k
    #
    # +ctx+ is the snapshot (+input + cached + cache_creation+; see
    # {Agent::Tokens}), optionally suffixed with +/<cap>+ when
    # {#context_window_cap} is set so the operator can see how close
    # the conversation is to the limit. +Δ+ is signed: +Δ+X+ for growth,
    # +Δ-X+ for shrinkage (legitimate if ruby_llm ever prunes between
    # turns). On the first message the baseline is implicitly zero, so
    # +Δ+ equals +ctx+. Sizes are scaled by 1024 and shown with one
    # decimal + a +k+ suffix.
    class TokenLog < MessageListener
      LOGGER = Pikuri.logger_for('Tokens')

      # Size of the prompt the model processed on the most recent
      # turn — the conversation's current consumption against the
      # model's context-window cap. Equals
      # +input + cached + cache_creation+ from the latest
      # {#on_tokens}. Zero until the first {#on_tokens} fires.
      #
      # @return [Integer]
      attr_reader :context_window_size

      # Model's context-window cap, or +nil+ if no source could supply
      # one (see {Agent::ContextWindowDetector}). When set, the +ctx=+
      # field renders as +ctx=<used>/<cap>+ instead of just +ctx=<used>+.
      # {Agent#initialize} pushes the detected value here via
      # {ListenerList#context_window_cap=} once it has run the detector,
      # so an instance constructed bare (e.g. by callers, in tests, or
      # by {#for_sub_agent}) defaults to +nil+.
      #
      # @return [Integer, nil]
      attr_accessor :context_window_cap

      # @return [String] owning agent's identifier. Empty by default
      #   (main agent); set by {#for_sub_agent} from the sub-agent's
      #   generated name so the log lines can be prefixed with
      #   +[<name>] +. Read-only — for a sub-agent's listener you get a
      #   fresh instance via {#for_sub_agent}.
      attr_reader :name

      # @param name [String] agent identifier prepended to each log
      #   line as +[<name>] + when non-empty. Defaults to +""+ for the
      #   main agent.
      def initialize(name: '')
        super()
        @name = name
        @msg = 0
        @context_window_size = 0
        @context_window_cap = nil
      end

      # Sub-agent variant: a fresh +TokenLog+ with a zeroed snapshot so
      # the sub-agent's context-window readings track its own
      # +RubyLLM::Chat+ rather than continuing the parent's. Picks the
      # sub-agent's +name:+ out of the forwarded params so its log
      # lines carry the +[<name>] + prefix; defaults to +""+ when
      # absent. The cap is left +nil+ here; the sub-agent's
      # {Agent#initialize} pushes the resolved cap onto every
      # +TokenLog+ in its list via {ListenerList#context_window_cap=}
      # immediately after construction.
      #
      # @param name [String] sub-agent's identifier
      # @return [TokenLog]
      def for_sub_agent(name: '', **)
        self.class.new(name: name)
      end

      # Update the context-window snapshot, then log one +INFO+ line.
      #
      # @param tokens [Agent::Tokens]
      # @return [void]
      def on_tokens(tokens)
        @msg += 1
        input_now          = tokens.input.to_i
        cached_now         = tokens.cached.to_i
        cache_creation_now = tokens.cache_creation.to_i

        prev_ctx = @context_window_size
        @context_window_size = input_now + cached_now + cache_creation_now
        delta = @context_window_size - prev_ctx

        LOGGER.info(format_line(input_now, tokens.output.to_i, delta))
      end

      # @return [String] short label for {Agent#to_s}, including the
      #   current context-window size (with cap suffix when set)
      def to_s
        "TokenLog(ctx=#{format_ctx})"
      end

      private

      def format_line(input, output, delta)
        sign = delta.negative? ? '-' : '+'
        prefix = @name.empty? ? '' : "[#{@name}] "
        "#{prefix}msg ##{@msg}: ctx=#{format_ctx}  Δ#{sign}#{format_k(delta.abs)}  ↑#{format_k(input)}  ↓#{format_k(output)}"
      end

      # +<used>+ when no cap is set, +<used>/<cap>+ when one is. Shared
      # between {#format_line} and {#to_s} so the headline reads the same
      # in the log stream and in {Agent#to_s} banners.
      def format_ctx
        base = format_k(@context_window_size)
        return base if @context_window_cap.nil?

        "#{base}/#{format_k(@context_window_cap)}"
      end

      # Format a token count as a 1024-scaled +k+-suffixed string.
      # +nil+ → +0.0k+; +0+ → +0.0k+; 12_453 → +12.2k+. Uniform
      # format keeps lines easy to scan at the cost of looking odd
      # for very small per-turn outputs (+↓0.0k+ on tool-call acks).
      #
      # @param n [Integer, nil]
      # @return [String]
      def format_k(n)
        format('%.1fk', n.to_i / 1024.0)
      end
    end
  end
end
