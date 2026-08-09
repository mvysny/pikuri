# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-thunderbird gem: local Thunderbird mail +
# calendar search/read for a pikuri agent, home of the
# +bin/pikuri-thunderbird+ no-egress demo. {Pikuri::Thunderbird::Extension}
# is the one-call wiring; it reads Thunderbird's own on-disk profile
# ({Pikuri::Thunderbird::Profile} discovers it) and never touches the
# network.
#
# The load-bearing posture (v1): search + read are inbound-only, so an
# agent wired with only these tools has private data + untrusted content
# but *no egress leg* — the lethal trifecta is broken by construction, the
# same model as +bin/pikuri-corpus+. Outbound actions (compose / create
# event) are v2 and are always human-gated hand-offs to Thunderbird's own
# UI. Threat model: +DESIGN.md+; design rationale: +ideas/thunderbird.md+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Thunderbird
    # Legs of the five inbound tools: a mailbox and a calendar are private by
    # *domain*, and their contents are written by whoever mailed you.
    #
    # The +private: true+ is the one place the framework declares that leg for
    # you, and it is a narrow exception rather than a breach of the rule that
    # the user declares sensitivity: elsewhere the framework cannot tell
    # +~/work/scratch+ from +~/work/payroll+, but a *mailbox* is sensitive by
    # what it is, not by how it was configured. Nothing was inspected to know
    # this — only the tool's domain.
    #
    # @return [Pikuri::Tool::TrifectaLegs]
    INBOUND_LEGS = Pikuri::Tool::TrifectaLegs.new(
      private: true, untrusted: :hard, egress: :none
    ).freeze

    # Legs of the two opt-in outbound hand-offs.
    #
    # +:human_approver+ rather than +:autonomous+ because all four clauses of
    # the approver seat hold, and the load-bearing one is payload visibility:
    # the human commits in Thunderbird's own compose window / import wizard, so
    # what is on screen *is* what leaves, byte for byte. That is why these are
    # graded differently from a confirmer-gated shell command, where the human
    # approves a program whose output was never shown.
    #
    # It stays true only while the outbound surface carries nothing but fields
    # that render literally — no attachments, no HTML body. A tool that gained
    # one would silently drop to hard +:egress+, since the human would be
    # approving a reference to bytes nobody saw.
    #
    # No +private+, unlike {INBOUND_LEGS}: these *send*, they do not read the
    # mailbox. The one trickle back is {ComposeGuard}'s recipient-novelty note,
    # and it is a single incidental bit about an address the model itself
    # supplied — worthless under attack, where a novel recipient is expected by
    # construction. The private leg grades what a tool lets an attacker
    # **query** over the pool, not whether any bit at all flows back.
    #
    # @return [Pikuri::Tool::TrifectaLegs]
    OUTBOUND_LEGS = Pikuri::Tool::TrifectaLegs.new(
      private: false, untrusted: :none, egress: :human_approver
    ).freeze

    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-thunderbird'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-thunderbird.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
