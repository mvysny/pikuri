# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Recording listener that appends every {Event} the agent
      # emits to an in-memory list. Used by specs to assert on
      # emissions without parsing stdout, and as the rough shape a
      # future structured consumer (web sink, telemetry pipe) would
      # take.
      class InMemoryEventList < Base
        # @return [Array<Agent::Event>] every event the listener
        #   has seen, in order; never nil
        attr_reader :events

        def initialize
          super
          @events = []
        end

        # @param event [Agent::Event]
        # @return [void]
        def on_event(event)
          @events << event
        end

        # @return [String] short label for {Agent#to_s}
        def to_s
          'InMemoryEventList'
        end
      end
    end
  end
end
