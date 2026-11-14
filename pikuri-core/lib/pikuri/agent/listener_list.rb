# frozen_string_literal: true

module Pikuri
  class Agent
    # Listener-list value object an {Agent} owns: wraps an +Array+ of
    # {Listener::Base} and fans {#emit} out to each.
    #
    # One job: fan out. The +Agent+ wires ruby_llm's callbacks itself, the
    # context cap rides the stream as a one-shot {Event::ContextCap}, and the
    # sub-agent derivation rule lives in {#for_sub_agent}. Controls are not
    # listeners and don't appear here.
    class ListenerList
      # @param listeners [Array<Listener::Base>] listeners that
      #   define +on_event(event)+
      def initialize(listeners)
        @listeners = listeners.dup
      end

      # @param listener [Listener::Base]
      # @return [void]
      def add(listener)
        @listeners << listener
        nil
      end

      # Dispatch one event to every listener, in registration order. Exactly two
      # callers: {Agent} (loop-narration {Event}s) and
      # {Configurator#emit_event} (domain events); listeners never call it —
      # the stream is one-way.
      #
      # @param event [Object] an {Agent::Event} variant or a gem domain event
      #   (an immutable value, by convention a +Data+)
      # @return [void]
      def emit(event)
        @listeners.each { |l| l.on_event(event) }
      end

      # Iterate the wrapped listeners in registration order — so a ListenerList
      # can be passed to {Configurator#add_listeners} (the +agent+ tool seeds a
      # sub-agent's Configurator from the parent's list).
      #
      # @yield [listener]
      # @yieldparam listener [Listener::Base]
      # @return [Enumerator] when no block given
      def each(&block)
        @listeners.each(&block)
      end

      # A new {ListenerList} where every listener has been asked for its
      # sub-agent variant: a listener defining +for_sub_agent(**params)+ returns
      # +self+, a replacement, or +nil+ to opt out (compacted away); listeners
      # without the method are kept by reference (stateful sinks keep flowing
      # into the parent's instances). The dispatch lives on each listener so a
      # new listener type needs no change here — see
      # {Listener::Terminal#for_sub_agent} / {Listener::TokenLog#for_sub_agent}.
      #
      # +params+ is forwarded as kwargs; each listener picks what it needs. The
      # only key bundled listeners consume is +id:+ ({Listener::TokenLog}); no
      # params is valid.
      #
      # @param params [Hash{Symbol => Object}]
      # @return [ListenerList]
      def for_sub_agent(**params)
        swapped = @listeners.filter_map do |l|
          l.respond_to?(:for_sub_agent) ? l.for_sub_agent(**params) : l
        end
        self.class.new(swapped)
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
