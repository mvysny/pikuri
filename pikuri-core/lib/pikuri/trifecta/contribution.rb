# frozen_string_literal: true

module Pikuri
  module Trifecta
    # What an extension adds to the tree, returned from
    # {Pikuri::Agent::Extension#trifecta_contribution}. Two independent things,
    # either of which may be empty:
    #
    #   # a sub-agent extension: one child per persona, nothing of its own
    #   Contribution.new(legs: Pikuri::Tool::TrifectaLegs::NONE, children: nodes)
    #
    #   # an MCP extension: legs no tool can declare, no children
    #   Contribution.new(label: '(mcp)', legs: assumed_with_private, children: [])
    #
    # Needed because two things in the tree are invisible to per-tool tagging:
    # a sub-agent is a whole node the tools cannot describe, and a foreign tool
    # surface (MCP) arrives as raw +RubyLLM::Tool+ subclasses with no leg
    # surface at all.
    #
    # Immutable.
    #
    # @!attribute [r] label
    #   @return [String] name of the row these +legs+ appear under in the
    #     report, parenthesized to mark it as not-a-tool. It is what
    #     {Pikuri::Trifecta::Report#attribution} points the reader at, so it
    #     has to name the surface they can actually go and change — two
    #     extensions declaring under one label would blame each other's
    #     wiring.
    # @!attribute [r] legs
    #   @return [Pikuri::Tool::TrifectaLegs] legs this extension adds to the
    #     node it is wired into, over and above that node's own tools
    # @!attribute [r] children
    #   @return [Array<Node>] child nodes this extension introduces
    class Contribution < Data.define(:label, :legs, :children)
      # @param label [String] row name for +legs+; ignored when they are +NONE+
      # @param legs [Pikuri::Tool::TrifectaLegs]
      # @param children [Array<Node>]
      def initialize(label: '(extension)', legs: Pikuri::Tool::TrifectaLegs::NONE, children: [])
        super
      end
    end
  end
end
