# frozen_string_literal: true

module Pikuri
  module Trifecta
    # The result of walking one agent tree: a {Node} with its legs folded — its
    # own tools unioned with everything propagated up from its sub-agents. What
    # {Pikuri::Trifecta.walk} returns, mirroring the tree shape so a host can
    # both classify and display it:
    #
    #   report = Pikuri::Trifecta.walk(node)
    #   report.tree_verdict                  # => :soft
    #   report.worst_path.map(&:label)       # => ["pikuri-computer", "RESEARCHER"]
    #   puts report.render                   # the human-readable map
    #
    # == Implementation details
    #
    # {#verdict} is *derived, never stored*: +Data#with+ would otherwise let a
    # copy carry a severity that contradicts its own legs. It reads presence
    # (+!= :none+, correct for any level ever added) and matches strength
    # exhaustively, so introducing a lattice level without placing it in the
    # grid raises on the first wiring that reaches it rather than being silently
    # absorbed into +:soft+.
    #
    # Immutable.
    #
    # @!attribute [r] label
    #   @return [String] this agent's name (see {Node#label})
    # @!attribute [r] legs
    #   @return [Pikuri::Tool::TrifectaLegs] folded legs — own tools plus
    #     everything propagated up from {#children}. What {#verdict} reads.
    # @!attribute [r] tool_legs
    #   @return [Hash{String=>Pikuri::Tool::TrifectaLegs}] carried through from
    #     the {Node} so {#render} can print the tools as leaves
    # @!attribute [r] children
    #   @return [Array<Report>] one per sub-agent, already walked
    # @!attribute [r] channel_egress
    #   @return [Symbol, nil] the parent edge's gate level (see
    #     {Node#channel_egress})
    class Report < Data.define(:label, :legs, :tool_legs, :children, :channel_egress)
      # Verdicts, least to most severe. The only ordering outside
      # {Pikuri::Tool::TrifectaLegs}.
      #
      # @return [Array<Symbol>]
      SEVERITY = %i[silent soft loud].freeze

      # Closing line of {#render}. Deliberately names no chapter: the owning
      # book chapter is still unwritten, and a placeholder would outlive it.
      #
      # @return [String]
      FOOTER = 'See the book in this repo for what the lethal trifecta is and how to break a leg.'

      # How dangerous *this node* is — the tree's verdict is {#tree_verdict}.
      #
      # +:loud+ needs all three legs at full strength; +:soft+ is any complete
      # trifecta whose untrusted or egress leg is attenuated; +:silent+ is a
      # missing leg. Absence of a warning is not evidence of safety: this
      # reasons about capability presence, not data flow.
      #
      # @return [Symbol] +:silent+, +:soft+ or +:loud+
      # @raise [NoMatchingPatternError] if a lattice level exists that this grid
      #   does not place — deliberate, so a new level cannot be absorbed silently
      def verdict
        return :silent unless legs.private && legs.untrusted != :none && legs.egress != :none

        case [legs.untrusted, legs.egress]
        in [:hard, :autonomous]     then :loud
        in [:hard, :human_approver] then :soft
        in [:weakened, :autonomous] then :soft
        in [:weakened, :human_approver] then :soft
        end
      end

      # Root-first path of Reports down to the most severe node in this subtree,
      # so the caller can both attribute the finding and read its cell:
      #
      #   path = report.worst_path
      #   path.map(&:label).join(' -> ')   # => "pikuri-computer -> RESEARCHER"
      #   path.last.legs                   # the cell that decided the verdict
      #
      # Ties go to the node encountered first in pre-order — the parent over its
      # own children, since a parent's trifecta is the more actionable finding.
      #
      # @return [Array<Report>] never empty; +[self]+ when nothing below is worse
      def worst_path
        best = [self]
        children.each do |child|
          candidate = [self, *child.worst_path]
          best = candidate if SEVERITY.index(candidate.last.verdict) > SEVERITY.index(best.last.verdict)
        end
        best
      end

      # @return [Symbol] the most severe {#verdict} anywhere in this subtree
      def tree_verdict = worst_path.last.verdict

      # The human-readable map: one line per agent and per tool, indented by
      # depth, with each entry's legs as tags.
      #
      #   Trifecta: soft
      #
      #   pikuri-computer [:private, :untrusted_hard, :egress_human_approver]
      #     mail_compose [:private, :egress_human_approver]
      #     calculator []
      #     RESEARCHER [gate: human_approver] [:untrusted_hard, :egress]
      #       fetch [:untrusted_hard, :egress]
      #
      #   See the book in this repo for ...
      #
      # An agent line carries its *folded* legs and a tool line its own, so
      # propagation shows up as layout: the parent above holds egress that no
      # tool of its own contributes. Plain text by design — a host wanting color
      # or width walks this tree itself rather than asking for styled output.
      #
      # @return [String] newline-separated, no trailing newline
      def render
        ["Trifecta: #{tree_verdict}", '', *render_lines, '', FOOTER].join("\n")
      end

      protected

      # @param depth [Integer] indentation level
      # @return [Array<String>]
      def render_lines(depth = 0)
        indent = '  ' * depth
        gate = channel_egress ? " [gate: #{channel_egress}]" : ''
        lines = ["#{indent}#{label}#{gate} #{legs.to_tags.inspect}"]
        tool_legs.each { |name, tool| lines << "#{indent}  #{name} #{tool.to_tags.inspect}" }
        children.each { |child| lines.concat(child.render_lines(depth + 1)) }
        lines
      end
    end
  end
end
