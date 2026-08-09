# frozen_string_literal: true

module Pikuri
  # The lethal-trifecta detector: does one agent simultaneously hold private
  # data, exposure to attacker-influenceable content, and a way to send bytes
  # out? Any two legs are fine; all three is the live wire, because an injection
  # hidden in the untrusted content can drive the exfiltration.
  #
  # Build a {Node} tree — the agent, its tools, its sub-agents — and walk it:
  #
  #   report = Pikuri::Trifecta.walk(node)
  #   report.tree_verdict   # => :loud
  #   puts report.render    # the map a bin script prints
  #
  # == This is a smoke alarm, not a firewall
  #
  # It reasons about *capability presence*, never data flow, so it both
  # over-warns (an egress query too narrow to carry anything) and under-warns
  # (one tool that is all three internally; private data staged into a file by
  # one tool and read out by another). It can prove you hold the ingredients. It
  # can prove neither that you are exploitable nor that you are safe — which is
  # why nothing here ever blocks execution, and why the absence of a warning is
  # never reported as an assurance.
  #
  # == Implementation details
  #
  # {.walk} is a pure function of the tree, so the whole rule set is testable
  # from hand-built {Node}s with no agent, no LLM and no sandbox probe.
  #
  # Two operations move legs between nodes, and their asymmetry is the design:
  # +max+ in *parallel* (legs meeting at one node, {Pikuri::Tool::TrifectaLegs#|})
  # and +min+ in *series* (a leg squeezed through a delegation channel,
  # {Pikuri::Tool::TrifectaLegs#cap_egress}). Severity is evaluated at every node
  # rather than only at the root, and the tree's verdict is the max over all of
  # them — which localizes a finding to the agent that actually holds it instead
  # of smearing a sub-agent's danger across its parent.
  module Trifecta
    class << self
      # Fold a {Node} tree into a {Report} tree: each node's own tools unioned,
      # then every sub-agent's legs propagated up.
      #
      # @param node [Node] root of the tree, usually the main agent
      # @return [Report] mirrors the input tree, legs folded
      def walk(node)
        children = node.children.map { |child| walk(child) }
        legs = node.tool_legs.values.reduce(Tool::TrifectaLegs::NONE) { |acc, tool| acc | tool }
        legs = children.reduce(legs) { |acc, child| acc | propagated(child) }

        Report.new(label: node.label, legs: legs, tool_legs: node.tool_legs,
                   children: children, channel_egress: node.channel_egress)
      end

      private

      # What +child+ contributes to its parent: untrusted attenuated by the
      # boundary, egress capped by the gate on the delegation channel.
      #
      # The cap is skipped when the child holds private data of its own, and
      # that precondition is load-bearing rather than a nicety. A child with
      # file tools can be handed an innocuous approved task, read secrets
      # *after* the gate, and egress a derivative of bytes no human ever saw —
      # so the channel no longer bounds what can leave.
      #
      # @param child [Report]
      # @return [Pikuri::Tool::TrifectaLegs]
      def propagated(child)
        contribution = child.legs.relabel_inbound
        return contribution if child.legs.private

        # A child with no recorded edge is treated as ungated: absent evidence
        # of a gate is not evidence of one.
        contribution.cap_egress(child.channel_egress || :autonomous)
      end
    end
  end
end
