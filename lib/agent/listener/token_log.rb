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
    # +RubyLLM::ContextLengthExceededError+: +input+ is the climb to
    # watch — it grows monotonically with each round trip because
    # ruby_llm re-sends the full +@messages+ array every iteration —
    # and once it nears the model's window, the next request will fail.
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
    # == Log line shape
    #
    #   msg #5: in=12453 out=320 | session: in=58201 out=1840
    #   msg #6: in=13100 out=288 thinking=120 | session: in=71301 out=2128 thinking=120
    #
    # The +thinking+ and +cached+ fields appear only when non-zero;
    # +in+ and +out+ always appear (zero or +nil+ → 0). Numbers are
    # plain integers — grepping for +session: in=+ tracks the growth
    # curve across a run.
    class TokenLog < MessageListener
      LOGGER = Pikuri.logger_for('Tokens')

      def initialize
        super
        @msg = 0
        @total_input = 0
        @total_output = 0
        @total_cached = 0
        @total_cache_creation = 0
        @total_thinking = 0
      end

      # Update the running session totals and log one +INFO+ line.
      #
      # @param tokens [Agent::Tokens]
      # @return [void]
      def on_tokens(tokens)
        @msg += 1
        @total_input          += tokens.input.to_i
        @total_output         += tokens.output.to_i
        @total_cached         += tokens.cached.to_i
        @total_cache_creation += tokens.cache_creation.to_i
        @total_thinking       += tokens.thinking.to_i

        LOGGER.info(format_line(tokens))
      end

      # @return [String] short label for {Agent#to_s}
      def to_s
        'TokenLog'
      end

      private

      def format_line(t)
        per_msg = +"in=#{t.input.to_i} out=#{t.output.to_i}"
        per_msg << " thinking=#{t.thinking}" if t.thinking&.positive?
        per_msg << " cached=#{t.cached}"     if t.cached&.positive?

        session = +"in=#{@total_input} out=#{@total_output}"
        session << " thinking=#{@total_thinking}" if @total_thinking.positive?
        session << " cached=#{@total_cached}"     if @total_cached.positive?

        "msg ##{@msg}: #{per_msg} | session: #{session}"
      end
    end
  end
end
