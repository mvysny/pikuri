# frozen_string_literal: true

module Pikuri
  class Agent
    # The composite listener an {Agent} owns: fans {#on_event} out to every
    # wrapped {Listener::Base}, in registration order.
    #
    #   list = ListenerList.new([Listener::Terminal.new, Listener::TokenLog.new])
    #   list.on_event(event)                            # both see it
    #   child = list.for_sub_agent(id: 'sub_agent 0')   # the sub-agent's list
    #
    # Being a listener itself, a list nests in another like any leaf, and
    # {#for_sub_agent} recurses into it.
    class ListenerList < Listener::Base
      # @param listeners [Array<Listener::Base>] listeners that
      #   define +on_event(event)+
      def initialize(listeners)
        super()
        @listeners = listeners.dup
      end

      # @param listener [Listener::Base]
      # @return [void]
      def add(listener)
        @listeners << listener
        nil
      end

      # Dispatch one event to every listener, in registration order.
      #
      # @param event [Object] an {Agent::Event} variant or a gem domain event
      #   (an immutable value, by convention a +Data+)
      # @return [void]
      def on_event(event)
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
