# frozen_string_literal: true

module Pikuri
  class Agent
    # Runs an +around_request:+ hook around every LLM HTTP request, by sitting
    # in ruby_llm's +instrumenter+ slot on one +RubyLLM::Context+ — an agent's
    # own, or any other connection that takes the same hook:
    #
    #   RubyLLM.context do |c|
    #     c.openai_api_base = base
    #     RequestInstrumenter.install(c, hook: around_request, api_base: base, cancellable: nil)
    #   end
    #
    # What a hook looks like is on {Agent#initialize}. {.install} is the one
    # place the slot is assigned: it holds a single instrumenter, so a second
    # assignment would silently displace the hook.
    #
    # Only +request.ruby_llm+ reaches the hook. Every other event ruby_llm emits
    # (+chat.ruby_llm+, +tool_call.ruby_llm+, ...) passes straight through —
    # +chat.ruby_llm+ wraps ruby_llm's *whole* recursive loop, tool calls
    # included, so hooking it would bracket a turn, and a throttle permit held
    # that long deadlocks a parent against the sub-agent its tool spawns.
    #
    # == Implementation details
    #
    # One +request.ruby_llm+ block is exactly one HTTP request *including its
    # streamed response* — measured, not assumed: every delta chunk of a
    # streamed completion landed inside one block (ruby_llm streams through
    # Faraday's +on_data+, driven from inside the +post+), and a forced
    # +Faraday::TimeoutError+ retried inside that same block. So the hook spans
    # the generation and ruby_llm's +retry_interval+ backoff, never just the
    # first byte. Measurements: +design/decisions.md+ +D_llm_request_throttle+.
    #
    # Blocking inside an *instrumentation* hook is a semantic stretch — the name
    # says observe, a throttle gates — accepted because the contract ruby_llm
    # documents is "yield and return the block's result", which is all a gate
    # needs.
    #
    # Immutable.
    class RequestInstrumenter
      # The one instrumented event that is exactly one HTTP request.
      REQUEST_EVENT = 'request.ruby_llm'

      # Install +hook+ on +config+'s instrumenter slot, chaining whatever it
      # displaces (see +chain+ on {#initialize}).
      #
      # @param config [RubyLLM::Configuration] a context's config, inside its
      #   +RubyLLM.context+ block.
      # @param hook [#call] an +around_request:+ hook.
      # @param api_base [String, nil] the base URL the connection dials.
      # @param cancellable [Control::Cancellable, nil] the turn's token, or
      #   +nil+ when no turn owns the requests.
      # @return [RequestInstrumenter] the installed instrumenter.
      def self.install(config, hook:, api_base:, cancellable:)
        config.instrumenter = new(hook: hook, api_base: api_base, cancellable: cancellable,
                                  chain: config.instrumenter)
      end

      # @param hook [#call] an +around_request:+ hook
      # @param api_base [String, nil] the base URL the connection dials, handed
      #   to +hook+
      # @param cancellable [Control::Cancellable, nil] handed to +hook+; +nil+
      #   when no turn owns the requests
      # @param chain [#instrument, nil] the instrumenter this one displaces —
      #   +RubyLLM.context+ dups the global config, so a host that installed
      #   +ActiveSupport::Notifications+ would otherwise have it silently
      #   clobbered. Every event is delegated to it, hooked or not. Anything not
      #   answering +#instrument+ is dropped, as ruby_llm itself does.
      def initialize(hook:, api_base:, cancellable:, chain: nil)
        @hook = hook
        @api_base = api_base
        @cancellable = cancellable
        @chain = chain if chain.respond_to?(:instrument)
        freeze
      end

      # ruby_llm's instrumenter protocol: run the block, return its value —
      # inside the hook when +name+ is {REQUEST_EVENT}.
      #
      # @param name [String] the event name, e.g. +"request.ruby_llm"+
      # @param payload [Hash, nil] ruby_llm's event payload, forwarded verbatim
      # @yield the work being instrumented
      # @return [Object] the block's value, or +nil+ when called without a block
      def instrument(name, payload = nil, &block)
        return pass(name, payload, &block) unless name.to_s == REQUEST_EVENT

        @hook.call(@api_base, @cancellable) { pass(name, payload, &block) }
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
