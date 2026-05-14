# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Recording listener that appends every {Message} the agent emits
      # to an in-memory list. Used by specs to assert on emissions
      # without parsing stdout, and as the rough shape a future
      # structured consumer (web sink, telemetry pipe) would take.
      class InMemoryList < MessageListener
        # @return [Array<Agent::Message>] every message the listener has
        #   seen, in order; never nil
        attr_reader :events

        def initialize
          super
          @events = []
        end

        # @param message [Agent::Message]
        # @return [void]
        def on_message(message)
          @events << message
        end

        # @return [String] short label for {Agent#to_s}
        def to_s
          'InMemoryList'
        end
      end
    end
  end
end
