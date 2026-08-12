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
    #     egress_payload_review: :no_egress))
    #
    # {Pikuri::Trifecta} unions these across an agent's tools and folds in its
    # sub-agents to decide whether all three legs are live at one node.
    #
    # == Implementation details
    #
    # Three axes are graded rather than boolean, and this class is the only
    # place their ordering lives: {#|} takes the per-axis +max+ (legs meeting at
    # one node), {#cap_payload_review} the +min+ (a leg squeezed through a
    # delegation channel), and {#relabel_inbound} applies the one fixed demotion
    # a sub-agent boundary buys. Nothing else may compare levels — the verdict
    # reads presence and top-ness only (see {Pikuri::Trifecta::Report#verdict}).
    #
    # The egress leg is *two* axes because they are orthogonal: an unreviewed
    # query to a vouched engine and a human-reviewed send to an attacker's inbox
    # are different animals, and neither dominates the other. Both carry
    # +:no_egress+ at the bottom and the constructor keeps them coherent, so the
    # leg is present on both or on neither ({#egress?} is the canonical read).
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
    # @!attribute [r] egress_payload_review
    #   Answers: did a human see the bytes that leave?
    #
    #   @return [Symbol] +:no_egress+, +:human_reviewed+ (the payload *is* the
    #     reviewed artifact — a compose window, an editable task string) or
    #     +:unreviewed+, which covers both no human at all and a human who saw
    #     only a proxy: approving +curl+ approves a program, and the bytes it
    #     sends are computed after the click.
    # @!attribute [r] egress_destination
    #   Answers: if an injection hijacks the model, can it reach the attacker?
    #
    #   @return [Symbol] +:no_egress+; +:attacker_reachable+ — the caller picks
    #     the host, *or* a fixed sink republishes what it receives (a hard-coded
    #     +gist.github.com+ POST is pinned and world-readable, so pinning alone
    #     buys nothing); or +:tool_vouched+, declarable iff the caller cannot
    #     choose the destination, that destination does not republish, and the
    #     request is not attacker-readable in flight or at rest. Unverifiable by
    #     the framework: like +private+, it is a declaration it inherits.
    class TrifectaLegs < Data.define(:private, :untrusted, :egress_payload_review, :egress_destination)
      # Danger order, least to most: +max+ is union at a node, +min+ is the cap
      # through a delegation channel.
      #
      # @return [Array<Symbol>]
      UNTRUSTED_ORDER = %i[none weakened hard].freeze

      # @return [Array<Symbol>] danger order, least to most (see {UNTRUSTED_ORDER})
      EGRESS_REVIEW_ORDER = %i[no_egress human_reviewed unreviewed].freeze

      # @return [Array<Symbol>] danger order, least to most (see {UNTRUSTED_ORDER})
      EGRESS_DESTINATION_ORDER = %i[no_egress tool_vouched attacker_reachable].freeze

      # @param private [Boolean]
      # @param untrusted [Symbol] one of {UNTRUSTED_ORDER}
      # @param egress_payload_review [Symbol] one of {EGRESS_REVIEW_ORDER}
      # @param egress_destination [Symbol, nil] one of {EGRESS_DESTINATION_ORDER};
      #   omit to derive — +:no_egress+ without a leg, else the pessimistic
      #   +:attacker_reachable+, so silence never buys the softer grade.
      # @raise [ArgumentError] on a level outside its lattice, or on the two
      #   egress axes disagreeing about whether the leg exists at all — a typo'd
      #   level would otherwise read as a missing leg, the one failure mode this
      #   detector exists to refuse.
      def initialize(private:, untrusted:, egress_payload_review:, egress_destination: nil)
        egress_destination ||= egress_payload_review == :no_egress ? :no_egress : :attacker_reachable
        check!(untrusted, UNTRUSTED_ORDER, 'untrusted')
        check!(egress_payload_review, EGRESS_REVIEW_ORDER, 'egress review')
        check!(egress_destination, EGRESS_DESTINATION_ORDER, 'egress destination')
        unless (egress_payload_review == :no_egress) == (egress_destination == :no_egress)
          raise ArgumentError, 'egress axes disagree on whether the leg exists: ' \
                               "#{egress_payload_review.inspect} / #{egress_destination.inspect}"
        end

        super(private: private, untrusted: untrusted, egress_payload_review: egress_payload_review,
              egress_destination: egress_destination)
      end

      # Union: the strongest value on each axis wins.
      #
      #   read_legs | bash_legs   # what an agent holding both ends up with
      #
      # @param other [TrifectaLegs]
      # @return [TrifectaLegs]
      def |(other)
        # Per-axis, so web_search (unreviewed, vouched) beside a compose tool
        # (reviewed, attacker-reachable) scores a cell neither occupies. Pairing
        # them up instead would be data flow, which this detector refuses to
        # model; over-warning is the declared bias.
        TrifectaLegs.new(
          private: private || other.private,
          untrusted: [untrusted, other.untrusted].max_by { UNTRUSTED_ORDER.index(_1) },
          egress_payload_review: [egress_payload_review, other.egress_payload_review]
            .max_by { EGRESS_REVIEW_ORDER.index(_1) },
          egress_destination: [egress_destination, other.egress_destination]
            .max_by { EGRESS_DESTINATION_ORDER.index(_1) }
        )
      end

      # @return [Boolean] whether this contributes an egress leg at all. The
      #   canonical presence read, since both egress axes encode absence.
      def egress? = egress_payload_review != :no_egress

      # These legs as they reach a *parent* across a sub-agent boundary: +:hard+
      # untrusted demotes to +:weakened+, the other three axes are identity.
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

      # These legs with the *review* axis capped at what the delegation channel
      # itself allows — +min+ in series, the counterpart to {#|}'s +max+ in
      # parallel.
      #
      # A child's egress cannot exceed the channel feeding it: when the only
      # bytes crossing into the child are a task string a human approved, even a
      # fully poisoned child can send nothing else. That holds *only* while the
      # child has no private data of its own, so {Pikuri::Trifecta.walk} owns the
      # precondition and this method is the mechanical +min+.
      #
      # {#egress_destination} is deliberately untouched: a gate bounds *what*
      # leaves and *who saw it*, never who can read it back.
      #
      # @param channel_level [Symbol] one of {EGRESS_REVIEW_ORDER}
      # @return [TrifectaLegs] with the leg gone entirely when the channel
      #   carries no egress at all
      # @raise [ArgumentError] on a level outside the lattice
      def cap_payload_review(channel_level)
        check!(channel_level, EGRESS_REVIEW_ORDER, 'egress review')
        capped = [egress_payload_review, channel_level].min_by { EGRESS_REVIEW_ORDER.index(_1) }
        return with(egress_payload_review: capped) unless capped == :no_egress

        with(egress_payload_review: :no_egress, egress_destination: :no_egress)
      end

      # Symbols naming the legs actually present, in the vocabulary the docs and
      # the rendered tree use. Absent legs are omitted, so a leg-free tool
      # yields +[]+ rather than three +:none+ entries.
      #
      #   TrifectaLegs.new(private: true, untrusted: :hard,
      #                    egress_payload_review: :no_egress).to_tags
      #   # => [:private, :untrusted_hard]
      #
      # @return [Array<Symbol>]
      def to_tags
        tags = []
        tags << :private if private
        tags << :"untrusted_#{untrusted}" unless untrusted == :none
        tags << egress_tag if egress?
        tags
      end

      private

      # @return [Symbol] +:egress+ at full strength, with +_reviewed+ /
      #   +_vouched+ appended per attenuated axis, so the four cells name
      #   themselves without a lookup table
      def egress_tag
        parts = ['egress']
        parts << 'reviewed' if egress_payload_review == :human_reviewed
        parts << 'vouched' if egress_destination == :tool_vouched
        parts.join('_').to_sym
      end

      # @raise [ArgumentError] unless +value+ is a level of the +order+ lattice
      def check!(value, order, name)
        raise ArgumentError, "unknown #{name} level: #{value.inspect}" unless order.include?(value)
      end

      # @return [TrifectaLegs] no legs at all
      NONE = new(private: false, untrusted: :none, egress_payload_review: :no_egress)

      # What an *undeclared* tool is presumed to hold: hostile on every axis the
      # framework could have determined for itself. Silence from a tool author is
      # not evidence of safety.
      #
      # It stops short of +private: true+ deliberately — that axis is the user's
      # to declare, and assuming it would make every wiring loud, turning a
      # warn-only advisory into noise and getting it muted.
      #
      # @return [TrifectaLegs]
      ASSUMED = new(private: false, untrusted: :hard, egress_payload_review: :unreviewed,
                    egress_destination: :attacker_reachable)
    end
  end
end
