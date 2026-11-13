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
    # (leg-absence, correct for any level ever added) and matches strength
    # exhaustively across all three graded axes, so introducing a lattice level
    # without placing it in the grid raises on the first wiring that reaches it
    # rather than being silently absorbed into +:soft+.
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

      # Closing pointer of {#advisory}. Names the chapter by *slug*, not by
      # ordinal: book chapters are ordered only by `book/README.md`, so this
      # path survives a reordering that would silently falsify a number.
      #
      # @return [String]
      FOOTER = 'See book/trifecta-detector.md in this repo.'

      # How dangerous *this node* is — the tree's verdict is {#tree_verdict}.
      #
      # +:loud+ needs all three legs at full strength — hard untrusted, and one
      # tool sending unreviewed bytes where the attacker can read them
      # ({Pikuri::Tool::TrifectaLegs#egress_open}); +:soft+ is any other
      # complete trifecta; +:silent+ is a missing leg. Absence of a warning is
      # not evidence of safety: this reasons about capability presence, not
      # data flow.
      #
      # @return [Symbol] +:silent+, +:soft+ or +:loud+
      # @raise [NoMatchingPatternError] if a lattice level exists that this grid
      #   does not place — deliberate, so a new level cannot be absorbed silently
      def verdict
        return :silent unless legs.private && legs.untrusted != :none && legs.egress?

        case [legs.untrusted, legs.egress_open]
        in [:hard,     true]  then :loud
        in [:hard,     false] then :soft
        in [:weakened, true]  then :soft
        in [:weakened, false] then :soft
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
      #   pikuri-computer [:private, :untrusted_hard, :egress_reviewed]
      #     mail_compose [:private, :egress_reviewed]
      #     calculator []
      #     RESEARCHER [gate: human_reviewed] [:untrusted_hard, :egress]
      #       fetch [:untrusted_hard, :egress]
      #
      #   See book/trifecta-detector.md in this repo for ...
      #
      # An agent line carries its *folded* legs and a tool line its own, so
      # propagation shows up as layout: the parent above holds egress that no
      # tool of its own contributes. Plain text by design — a host wanting color
      # or width walks this tree itself rather than asking for styled output.
      #
      # @return [String] newline-separated, no trailing newline
      def render
        [advisory, '', *render_lines].join("\n")
      end

      # The one-line conclusion: what was found, where, and the leg to break.
      # Separate from {#render} because a status line wants this without the
      # tree, and because it is the half that carries *meaning* — the map
      # deliberately carries only facts.
      #
      #   [TRIFECTA: HARD] pikuri-code — private(read, bash) + untrusted(read,
      #   bash) + egress(bash). An injection in what this agent reads can drive
      #   an exfiltration. Break a leg: sever egress (a network-off sandbox), or
      #   privilege-separate the step that reads untrusted content.
      #   See book/trifecta-detector.md in this repo.
      #
      # A clean verdict never says "no trifecta detected". This reasons about
      # capability presence, so a quiet result is not a clean bill of health —
      # it under-warns on a single tool that is all three internally, and on
      # private data staged into a file by one tool and read by another.
      # Reporting the *finding* names what would tip the wiring over and claims
      # nothing it cannot support.
      #
      # @return [String]
      def advisory
        path = worst_path
        where = path.map(&:label).join(' -> ')
        legs = path.last.legs
        return "Trifecta: #{where} — #{presence(legs)}." if tree_verdict == :silent

        "[TRIFECTA: #{tree_verdict == :loud ? 'HARD' : 'soft'}] #{where} — " \
          "#{attribution(path.last)}. An injection in what this agent reads can drive " \
          "an exfiltration. Break a leg: #{advice(legs)}. #{FOOTER}"
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

      private

      # @param legs [Pikuri::Tool::TrifectaLegs]
      # @return [String] e.g. +"2 of 3 legs (private, untrusted); no egress leg found"+
      def presence(legs)
        held = { 'private' => legs.private, 'untrusted' => legs.untrusted != :none,
                 'egress' => legs.egress? }
        "#{held.count { |_, v| v }} of 3 legs (#{held.select { |_, v| v }.keys.join(', ')}); " \
          "no #{held.reject { |_, v| v }.keys.join('/')} leg found"
      end

      # Which tool contributed each leg, so the line names something the reader
      # can actually go and change.
      #
      # @param node [Report]
      # @return [String]
      def attribution(node)
        %i[private untrusted egress].filter_map do |axis|
          contributors = node.tool_legs.select { |_, l| leg_present?(l, axis) }.keys
          "#{axis}(#{contributors.join(', ')})" unless contributors.empty?
        end.join(' + ')
      end

      # @param legs [Pikuri::Tool::TrifectaLegs]
      # @param axis [Symbol] +:private+, +:untrusted+ or +:egress+
      # @return [Boolean]
      def leg_present?(legs, axis)
        case axis
        in :private then legs.private
        in :untrusted then legs.untrusted != :none
        in :egress then legs.egress?
        end
      end

      # The fix, per cell of the verdict grid — the soft cells want different
      # answers, which is why this reads the legs rather than the verdict symbol.
      #
      # @param legs [Pikuri::Tool::TrifectaLegs]
      # @return [String]
      def advice(legs)
        # An unreviewed leak to a vouched destination is fragile in a way the
        # other attenuations are not: it is soft only while no tool beside it
        # both skips review and reaches the attacker. Say so, rather than let
        # the soft verdict read as settled.
        if !legs.egress_open && (legs.egress_payload_review == :unreviewed || legs.egress_destination == :tool_vouched)
          return 'sever egress outright — bytes still leave, they merely reach a destination the attacker ' \
                 'cannot read back, and one unreviewed attacker-reachable tool re-hardens this node'
        end

        case [legs.untrusted, legs.egress_open]
        in [:hard, true]
          'sever egress (a network-off sandbox), or privilege-separate the step that reads untrusted content'
        in [:hard, false]
          'privilege-separate the step that reads untrusted content, or declare the workspace trusted ' \
            'if you vouch for every byte it can reach'
        in [:weakened, true]
          'sever egress — the untrusted leg is already attenuated by delegation'
        in [:weakened, false]
          'both legs are already attenuated; narrow what counts as private, or drop a leg outright'
        end
      end
    end
  end
end
