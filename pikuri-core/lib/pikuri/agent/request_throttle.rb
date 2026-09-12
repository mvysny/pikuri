# frozen_string_literal: true

module Pikuri
  class Agent
    # Holds one {ServerPermits} permit for the length of one LLM HTTP request,
    # by sitting in ruby_llm's +instrumenter+ slot on an agent's own
    # +RubyLLM::Context+:
    #
    #   RubyLLM.context do |c|
    #     c.openai_api_base = 'http://localhost:8080/v1'
    #     c.instrumenter = RequestThrottle.new(key: c.openai_api_base,
    #                                          cancellable: cancellable,
    #                                          chain: c.instrumenter)
    #   end
    #
    # Only +request.ruby_llm+ is gated. Every other event ruby_llm emits
    # (+chat.ruby_llm+, +tool_call.ruby_llm+, +embedding.ruby_llm+, ...) passes
    # through untouched — +chat.ruby_llm+ wraps ruby_llm's *whole* recursive
    # loop, tool calls included, so gating that one would be a whole-turn permit
    # and a parent holding it would deadlock against the sub-agent its tool
    # spawns.
    #
    # == Implementation details
    #
    # One +request.ruby_llm+ block is exactly one HTTP request *including its
    # streamed response* — measured, not assumed: every delta chunk of a
    # streamed completion landed inside one block (ruby_llm streams through
    # Faraday's +on_data+, driven from inside the +post+), and a forced
    # +Faraday::TimeoutError+ retried inside that same block. So the permit
    # spans the generation, and must not be released at the first byte.
    #
    # A retried request therefore holds its permit through ruby_llm's
    # +retry_interval+ backoff, idling the server slot for a moment.
    # Deliberate: releasing across retries re-creates the duplicate-work
    # stampede the throttle exists to prevent, a re-enqueued request piling in
    # behind an original that is still generating.
    #
    # Blocking inside an *instrumentation* hook is a semantic stretch — the name
    # says observe, this gates — accepted because the contract ruby_llm
    # documents is "yield and return the block's result", which is all a gate
    # needs. The measurements and the roads not taken: +design/decisions.md+
    # +D_llm_request_throttle+.
    #
    # Thread-safe: immutable after construction, and the waiting is
    # {ServerPermits::Semaphore}'s.
    class RequestThrottle
      # The one instrumented event that is exactly one HTTP request.
      REQUEST_EVENT = 'request.ruby_llm'

      # @return [String, nil] the {ServerPermits} key this gates on; +nil+ gates
      #   nothing (no server could be resolved, e.g. a provider with a fixed
      #   base — unlimited is the right answer there).
      attr_reader :key

      # @param key [String, nil] the server base URL to take permits for
      # @param cancellable [Control::Cancellable, nil] polled while parked on a
      #   permit
      # @param chain [#instrument, nil] an instrumenter this one displaces —
      #   +RubyLLM.context+ dups the global config, so a host that installed
      #   +ActiveSupport::Notifications+ would otherwise have it silently
      #   clobbered. Every event is delegated to it, gated or not. Anything not
      #   answering +#instrument+ is dropped, as ruby_llm itself does.
      def initialize(key:, cancellable: nil, chain: nil)
        @key = key
        @cancellable = cancellable
        @chain = chain if chain.respond_to?(:instrument)
      end

      # ruby_llm's instrumenter protocol: run the block, return its value —
      # here with a permit held for the duration when +name+ is
      # {REQUEST_EVENT}.
      #
      # @param name [String] the event name, e.g. +"request.ruby_llm"+
      # @param payload [Hash, nil] ruby_llm's event payload (+provider+,
      #   +method+, +url+, and +status+ on the way out), forwarded verbatim
      # @yield the work being instrumented
      # @return [Object] the block's value, or +nil+ when called without a block
      # @raise [Control::Cancellable::Cancelled] if cancelled while waiting for
      #   a permit — raised before the request is sent, so it strands only the
      #   tool batch {Agent#run_loop}'s +ensure+ already repairs
      def instrument(name, payload = nil, &block)
        return pass(name, payload, &block) unless name.to_s == REQUEST_EVENT

        ServerPermits.for(@key).acquire(cancellable: @cancellable) { pass(name, payload, &block) }
      end

      # @return [String] +"RequestThrottle(http://localhost:8080/v1: 1/1 permits)"+.
      def to_s
        "RequestThrottle(#{@key || 'unlimited'}: #{ServerPermits.for(@key)})"
      end

      private

      # @param name [String]
      # @param payload [Hash, nil]
      # @return [Object] the block's value
      def pass(name, payload, &block)
        return @chain.instrument(name, payload, &block) if @chain

        block&.call
      end
    end
  end
end
