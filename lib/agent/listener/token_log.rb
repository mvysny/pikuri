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
    # +RubyLLM::ContextLengthExceededError+: the +ctx=+ field is the
    # climb to watch — full prompt size this turn = +input + cached
    # + cache_creation+ (the three exclusive portions of the prompt
    # ruby_llm exposes for our provider shape; see {Agent::Tokens}).
    # Once +ctx+ nears the model's window, the next request fails.
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
    # +ctx+ is **not** summed across turns: it is a snapshot of the
    # current prompt size, and the session's +ctx+ field is just the
    # latest one. The +input+/+output+/+cached+/+cache_creation+/
    # +thinking+ fields are per-turn deltas and DO sum into the
    # +session:+ totals.
    #
    # == Log line shape
    #
    #   msg #5: ctx=12.2k in=2.0k cached=10.2k out=0.3k | session: ctx=12.2k in=8.4k cached=30.0k out=1.8k
    #
    # Per-msg portion: +ctx+ (this turn's full prompt size — the
    # headline), then the per-turn breakdown (+in+, +cached+,
    # +cache_creation+, +out+, +thinking+). Session portion: +ctx+
    # (latest, same value as per-msg +ctx+), then running sums of
    # the deltas.
    #
    # +ctx+, +in+, and +out+ always appear (zero or +nil+ → +0.0k+).
    # +cached+, +cache_creation+, and +thinking+ appear only when
    # non-zero so the line stays compact for providers / configs that
    # don't use those features. Sizes are scaled by 1024 and shown
    # with one decimal + a +k+ suffix.
    class TokenLog < MessageListener
      LOGGER = Pikuri.logger_for('Tokens')

      # Size of the prompt the model processed on the most recent
      # turn — the conversation's current consumption against the
      # model's context-window cap. Equals
      # +input + cached + cache_creation+ from the latest
      # {#on_tokens}, the three exclusive portions of this turn's
      # prompt under ruby_llm's shape for our provider (see
      # {Agent::Tokens}). Zero until the first {#on_tokens} fires.
      #
      # Not summed across turns: each turn carries its own snapshot,
      # and "current size" means the latest one.
      #
      # @return [Integer]
      attr_reader :context_window_size

      def initialize
        super
        @msg = 0
        @context_window_size = 0
        @total_input = 0
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
        input_now          = tokens.input.to_i
        cached_now         = tokens.cached.to_i
        cache_creation_now = tokens.cache_creation.to_i

        @context_window_size   = input_now + cached_now + cache_creation_now
        @total_input          += input_now
        @total_output         += tokens.output.to_i
        @total_cached         += cached_now
        @total_cache_creation += cache_creation_now
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
        per_msg = +"ctx=#{format_k(@context_window_size)} in=#{format_k(t.input.to_i)} out=#{format_k(t.output.to_i)}"
        per_msg << " cached=#{format_k(t.cached)}"                 if t.cached&.positive?
        per_msg << " cache_creation=#{format_k(t.cache_creation)}" if t.cache_creation&.positive?
        per_msg << " thinking=#{format_k(t.thinking)}"             if t.thinking&.positive?

        session = +"ctx=#{format_k(@context_window_size)} in=#{format_k(@total_input)} out=#{format_k(@total_output)}"
        session << " cached=#{format_k(@total_cached)}"                 if @total_cached.positive?
        session << " cache_creation=#{format_k(@total_cache_creation)}" if @total_cache_creation.positive?
        session << " thinking=#{format_k(@total_thinking)}"             if @total_thinking.positive?

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
