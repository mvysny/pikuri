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
    # This used to do three jobs: fan out, attach listeners to a
    # +RubyLLM::Chat+ (each listener wired its own callbacks), and
    # push the context-window cap onto every +TokenLog+ via a
    # special setter. The first job is the only one that survives:
    # the +Agent+ now wires ruby_llm's callbacks itself, and the
    # context-window cap rides the event stream as a one-shot
    # {Event::ContextCap}.
    #
    # The list is also where the sub-agent derivation rule lives —
    # see {#for_sub_agent}. Controls (step budget, cancellation
    # flag, mid-loop input queue) are not listeners and do not
    # appear in this list; their sub-agent derivation lives on each
    # control class instead.
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
      # with the forwarded +name:+).
      #
      # +params+ is a flat hash forwarded as kwargs to every
      # listener's hook; each listener picks the keys it cares about
      # and ignores the rest. The only key currently consumed by
      # bundled listeners is +name:+ (used by {Listener::TokenLog}).
      # Calling with no params is always valid.
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
