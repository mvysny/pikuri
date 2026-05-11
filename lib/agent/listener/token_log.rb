# frozen_string_literal: true

class Agent
  module Listener
    # Logs per-message and cumulative session token usage via
    # +Pikuri.logger_for('Tokens')+. Overrides
    # {MessageListener#on_tokens} and emits one +INFO+ line per
    # assistant turn that includes both the turn's numbers and the
    # running session totals.
    #
    # Use this to spot context-window growth before the provider raises
    # +RubyLLM::ContextLengthExceededError+: the per-msg +in=+ is the
    # climb to watch — it grows monotonically with each round trip
    # because ruby_llm re-sends the full +@messages+ array every
    # iteration — and once it nears the model's window, the next
    # request will fail.
    #
    # == State and scope
    #
    # Cumulative totals live on the instance, so one +TokenLog+ is
    # per-conversation. Sub-agents (with their own +RubyLLM::Chat+)
    # get a fresh instance via {ListenerList#with_zero_tokens} so
    # their counts log against their own chat. The synthesizer rescue
    # keeps using the parent's instance because synth tokens are part
    # of the same user-question's cost and should accumulate.
    #
    # +input+ is **not** summed across turns: each turn's +input+ is
    # already the whole prompt seen by the model (history + system +
    # tools + new message), so summing snapshots would double-count.
    # The per-msg +in=+ field already shows it climbing. The +session:+
    # portion only carries fields that are genuinely per-turn deltas
    # — +out+, +thinking+, +cached+, +cache_creation+ — and therefore
    # additive across the run.
    #
    # == Log line shape
    #
    #   msg #5: ctx=12.2k out=0.3k | session: out=1.8k
    #   msg #6: ctx=12.8k out=0.3k thinking=0.1k | session: out=2.1k thinking=0.1k
    #
    # The +ctx=+ field is the value of {#context_window_size} at this
    # turn — placed first because it's the number that signals how
    # close the conversation is to the model's context cap.
    # +thinking+ and +cached+ appear only when non-zero; +ctx+ and
    # +out+ always appear (zero or +nil+ → +0.0k+). Sizes are scaled
    # by 1024 and shown with one decimal + a +k+ suffix; grepping for
    # +msg #+ and watching +ctx=+ tracks the growth curve.
    class TokenLog < MessageListener
      LOGGER = Pikuri.logger_for('Tokens')

      # Latest +input+ token count reported by the provider — the size
      # of the prompt as the model saw it on the most recent turn,
      # which is also the conversation's current consumption against
      # the model's context window. Zero until the first {#on_tokens}
      # fires.
      #
      # Not summed across turns: each +input+ is already a cumulative
      # snapshot (full history re-sent every iteration), so latest is
      # what "current size" means. See {Agent::Tokens} for the
      # invariant in full.
      #
      # @return [Integer]
      attr_reader :context_window_size

      def initialize
        super
        @msg = 0
        @context_window_size = 0
        @total_output = 0
        @total_cached = 0
        @total_cache_creation = 0
        @total_thinking = 0
      end

      # Update the running session totals + the context-window
      # snapshot, then log one +INFO+ line.
      #
      # @param tokens [Agent::Tokens]
      # @return [void]
      def on_tokens(tokens)
        @msg += 1
        @context_window_size   = tokens.input.to_i
        @total_output         += tokens.output.to_i
        @total_cached         += tokens.cached.to_i
        @total_cache_creation += tokens.cache_creation.to_i
        @total_thinking       += tokens.thinking.to_i

        LOGGER.info(format_line(tokens))
      end

      # @return [String] short label for {Agent#to_s}, including the
      #   current context-window size
      def to_s
        "TokenLog(ctx=#{format_k(@context_window_size)})"
      end

      private

      def format_line(t)
        per_msg = +"ctx=#{format_k(t.input.to_i)} out=#{format_k(t.output.to_i)}"
        per_msg << " thinking=#{format_k(t.thinking)}" if t.thinking&.positive?
        per_msg << " cached=#{format_k(t.cached)}"     if t.cached&.positive?

        session = +"out=#{format_k(@total_output)}"
        session << " thinking=#{format_k(@total_thinking)}" if @total_thinking.positive?
        session << " cached=#{format_k(@total_cached)}"     if @total_cached.positive?

        "msg ##{@msg}: #{per_msg} | session: #{session}"
      end

      # Format a token count as a 1024-scaled +k+-suffixed string.
      # +nil+ → +0.0k+; +0+ → +0.0k+; 12_453 → +12.2k+. Uniform
      # format keeps lines easy to scan at the cost of looking odd
      # for very small per-turn outputs (+out=0.0k+ on tool-call acks).
      #
      # @param n [Integer, nil]
      # @return [String]
      def format_k(n)
        format('%.1fk', n.to_i / 1024.0)
      end
    end
  end
end
