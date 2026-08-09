# frozen_string_literal: true

module Pikuri
  module Trifecta
    # One agent in the tree the detector walks: the main agent at the root, a
    # persona per sub-agent below it. Built by {Pikuri::Trifecta.build} from a
    # wired +Agent+, and hand-built in specs — which is the point of carrying
    # plain data rather than live objects:
    #
    #   Node.new(label: 'demo',
    #            tool_legs: { 'read' => read_legs },
    #            children: [Node.new(label: 'RESEARCHER',
    #                                tool_legs: { 'fetch' => fetch_legs },
    #                                channel_egress: :human_approver)])
    #
    # Immutable.
    #
    # @!attribute [r] label
    #   @return [String] name shown in the report — the binary/agent name at the
    #     root, the persona name for a sub-agent
    # @!attribute [r] tool_legs
    #   @return [Hash{String=>Pikuri::Tool::TrifectaLegs}] this agent's own
    #     tools, in wiring order. The per-tool breakdown is kept rather than
    #     pre-unioned so the rendered tree can show *which* tool contributes a
    #     leg instead of a bare total.
    # @!attribute [r] children
    #   @return [Array<Node>] sub-agents this agent can dispatch to
    # @!attribute [r] channel_egress
    #   @return [Symbol, nil] how much egress the delegation channel *from the
    #     parent* permits — +:human_approver+ when a human gates the hand-off,
    #     +:autonomous+ otherwise. A property of the edge, stored on the child
    #     because every child has exactly one parent edge; +nil+ at the root,
    #     which has none.
    class Node < Data.define(:label, :tool_legs, :children, :channel_egress)
      # @param label [String]
      # @param tool_legs [Hash{String=>Pikuri::Tool::TrifectaLegs}]
      # @param children [Array<Node>]
      # @param channel_egress [Symbol, nil]
      def initialize(label:, tool_legs: {}, children: [], channel_egress: nil)
        super
      end
    end
  end
end
