# frozen_string_literal: true

module Pikuri
  class Agent
    # Listener-list value object that an {Agent} owns. Wraps an
    # +Array+ of {Listener::Base} instances and fans {#emit} out to
    # each; {Agent#initialize} stores one of these and is the sole
    # caller of {#emit}.
    #
    # == What this is, what it isn't
    #
    # One job: fan out. The +Agent+ wires ruby_llm's callbacks
    # itself, the context-window cap rides the event stream as a
    # one-shot {Event::ContextCap}, and the sub-agent derivation
    # rule lives in {#for_sub_agent}. Controls (step budget,
    # cancellation flag, mid-loop input queue) are not listeners
    # and do not appear in this list; their sub-agent derivation
    # lives on each control class instead.
    class ListenerList
      # @param listeners [Array<Listener::Base>] listeners that
      #   define +on_event(event)+
      def initialize(listeners)
        @listeners = listeners.dup
      end

      # Dispatch one event to every listener, in registration order.
      # Called exclusively by {Agent} — listeners themselves never
      # call this; the stream is one-way.
      #
      # @param event [Agent::Event]
      # @return [void]
      def emit(event)
        @listeners.each { |l| l.on_event(event) }
      end

      # Iterate over the wrapped listeners in registration order. The
      # method exists so a ListenerList can be passed directly to
      # {Configurator#add_listeners} (used by the +agent+ tool from
      # +pikuri-subagents+ when seeding a sub-agent's Configurator
      # from the parent's list).
      #
      # @yield [listener]
      # @yieldparam listener [Listener::Base]
      # @return [Enumerator] when no block given
      def each(&block)
        @listeners.each(&block)
      end

      # Return a new {ListenerList} in which every listener has been
      # asked for its sub-agent variant. Each listener that defines
      # +for_sub_agent(**params)+ receives the forwarded +params+
      # and returns either +self+, a replacement instance, or +nil+
      # to opt out of propagation entirely — the resulting list
      # compacts +nil+ entries away. Listeners that don't define the
      # method are kept by reference (structured capture and other
      # stateful sinks continue to flow into the parent's instances).
      #
      # The dispatch lives on each listener so adding a new
      # listener type with sub-agent-specific behavior doesn't
      # change this class — see {Listener::Terminal#for_sub_agent}
      # (fresh padded instance) and
      # {Listener::TokenLog#for_sub_agent} (fresh, zeroed snapshot
      # with the forwarded +id:+).
      #
      # +params+ is a flat hash forwarded as kwargs to every
      # listener's hook; each listener picks the keys it cares about
      # and ignores the rest. The only key currently consumed by
      # bundled listeners is +id:+ (used by {Listener::TokenLog} to
      # prefix its log lines with the sub-agent's id). Calling with
      # no params is always valid.
      #
      # @param params [Hash{Symbol => Object}]
      # @return [ListenerList]
      def for_sub_agent(**params)
        swapped = @listeners.filter_map do |l|
          l.respond_to?(:for_sub_agent) ? l.for_sub_agent(**params) : l
        end
        self.class.new(swapped)
      end

      # Return a new {ListenerList} containing this list's listeners
      # plus the given extras, in order. Used by {Synthesizer} and
      # other internal consumers to derive a list from an existing
      # one. Returns +self+ when +extras+ is empty so the common
      # no-op case allocates nothing.
      #
      # @param extras [Array<Listener::Base>] listeners to append
      # @return [ListenerList]
      def with(*extras)
        return self if extras.empty?

        self.class.new(@listeners + extras)
      end

      # @example
      #   list.to_s # => "[Terminal, TokenLog(ctx=0.0k)]"
      #
      # @return [String]
      def to_s
        "[#{@listeners.map(&:to_s).join(', ')}]"
      end
    end
  end
end
