# frozen_string_literal: true

module Pikuri
  class Tool
    # Which of the lethal trifecta's three legs a tool contributes — private
    # data in, attacker-influenceable content in, bytes out. A tool declares its
    # legs in its own constructor, where every collaborator that decides them
    # (workspace, sandbox, confirmer) is already a kwarg:
    #
    #   super(name: 'read', ..., trifecta_legs: Tool::TrifectaLegs.new(
    #     private:   fs.private?,
    #     untrusted: fs.trusted? ? :none : :hard,
    #     egress:    :none))
    #
    # {Pikuri::Trifecta} unions these across an agent's tools and folds in its
    # sub-agents to decide whether all three legs are live at one node.
    #
    # == Implementation details
    #
    # Two axes are graded rather than boolean, and this class is the only place
    # their ordering lives: {#|} takes the per-axis +max+ (legs meeting at one
    # node), {#cap_egress} the +min+ (a leg squeezed through a delegation
    # channel), and {#relabel_inbound} applies the one fixed demotion a
    # sub-agent boundary buys. Nothing else may compare levels — the verdict
    # reads presence and top-ness only (see {Pikuri::Trifecta::Report#verdict}).
    #
    # Immutable.
    #
    # @!attribute [r] private
    #   @return [Boolean] reads data that may be sensitive. The framework cannot
    #     know this — sensitivity is a property of the data, not of the tool — so
    #     the user declares it on the workspace/corpus and the tool inherits it.
    # @!attribute [r] untrusted
    #   @return [Symbol] +:none+, +:weakened+ (reached this agent through a
    #     sub-agent, whose summarization relays an injected instruction as a
    #     reported fact) or +:hard+ (verbatim into this agent's context).
    # @!attribute [r] egress
    #   @return [Symbol] +:none+, +:human_approver+ (a human sees the literal
    #     outbound bytes and commits) or +:autonomous+ (no human in the path, or
    #     a human who sees only a proxy — a shell command line, a filename).
    class TrifectaLegs < Data.define(:private, :untrusted, :egress)
      # Danger order, least to most: +max+ is union at a node, +min+ is the cap
      # through a delegation channel.
      #
      # @return [Array<Symbol>]
      UNTRUSTED_ORDER = %i[none weakened hard].freeze

      # @return [Array<Symbol>] danger order, least to most (see {UNTRUSTED_ORDER})
      EGRESS_ORDER = %i[none human_approver autonomous].freeze

      # @param private [Boolean]
      # @param untrusted [Symbol] one of {UNTRUSTED_ORDER}
      # @param egress [Symbol] one of {EGRESS_ORDER}
      # @raise [ArgumentError] on a level outside its lattice — a typo'd level
      #   would otherwise read as a missing leg, the one failure mode this
      #   detector exists to refuse.
      def initialize(private:, untrusted:, egress:)
        raise ArgumentError, "unknown untrusted level: #{untrusted.inspect}" unless UNTRUSTED_ORDER.include?(untrusted)
        raise ArgumentError, "unknown egress level: #{egress.inspect}" unless EGRESS_ORDER.include?(egress)

        super
      end

      # Union: the strongest value on each axis wins.
      #
      #   read_legs | bash_legs   # what an agent holding both ends up with
      #
      # @param other [TrifectaLegs]
      # @return [TrifectaLegs]
      def |(other)
        TrifectaLegs.new(
          private: private || other.private,
          untrusted: [untrusted, other.untrusted].max_by { UNTRUSTED_ORDER.index(_1) },
          egress: [egress, other.egress].max_by { EGRESS_ORDER.index(_1) }
        )
      end

      # These legs as they reach a *parent* across a sub-agent boundary: +:hard+
      # untrusted demotes to +:weakened+, the other two axes are identity.
      #
      # The boundary filters *instructions*, not *content* — a faithful summary
      # preserves the page's facts but has no reason to adopt an out-of-band
      # imperative, so an injection arrives as a reported fact rather than as a
      # command. Private data survives intact (a summary of a secret still
      # contains the secret), and egress survives because the parent can simply
      # ask the child to send the thing.
      #
      # @return [TrifectaLegs]
      def relabel_inbound
        # Saturating, not one-rung-down: :weakened stays :weakened. Decrementing
        # per hop would launder a grandchild's untrusted content to :none at
        # depth three — two summarizers are no more instruction-resistant than
        # one, and that is the structural claim this design refuses to make.
        with(untrusted: untrusted == :hard ? :weakened : untrusted)
      end

      # These legs with the egress axis capped at what the delegation channel
      # itself allows — +min+ in series, the counterpart to {#|}'s +max+ in
      # parallel.
      #
      # A child's egress cannot exceed the channel feeding it: when the only
      # bytes crossing into the child are a task string a human approved, even a
      # fully poisoned child can send nothing else. That holds *only* while the
      # child has no private data of its own, so {Pikuri::Trifecta.walk} owns the
      # precondition and this method is the mechanical +min+.
      #
      # @param channel_level [Symbol] one of {EGRESS_ORDER}
      # @return [TrifectaLegs]
      # @raise [ArgumentError] on a level outside the lattice
      def cap_egress(channel_level)
        raise ArgumentError, "unknown egress level: #{channel_level.inspect}" unless EGRESS_ORDER.include?(channel_level)

        with(egress: [egress, channel_level].min_by { EGRESS_ORDER.index(_1) })
      end

      # Symbols naming the legs actually present, in the vocabulary the docs and
      # the rendered tree use. Absent legs are omitted, so a leg-free tool
      # yields +[]+ rather than three +:none+ entries.
      #
      #   TrifectaLegs.new(private: true, untrusted: :hard, egress: :none).to_tags
      #   # => [:private, :untrusted_hard]
      #
      # @return [Array<Symbol>]
      def to_tags
        tags = []
        tags << :private if private
        tags << :"untrusted_#{untrusted}" unless untrusted == :none
        tags << (egress == :autonomous ? :egress : :"egress_#{egress}") unless egress == :none
        tags
      end

      # @return [TrifectaLegs] no legs at all
      NONE = new(private: false, untrusted: :none, egress: :none)

      # What an *undeclared* tool is presumed to hold: hostile on both axes the
      # framework could have determined for itself. Silence from a tool author
      # is not evidence of safety.
      #
      # It stops short of +private: true+ deliberately — that axis is the user's
      # to declare, and assuming it would make every wiring loud, turning a
      # warn-only advisory into noise and getting it muted.
      #
      # @return [TrifectaLegs]
      ASSUMED = new(private: false, untrusted: :hard, egress: :autonomous)
    end
  end
end
