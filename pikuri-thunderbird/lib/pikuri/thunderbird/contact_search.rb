# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_contact_search+ tool — resolve a person's name (or a
    # partial address) to the email address(es) the user has actually
    # corresponded with, ranked by familiarity. Inbound-only (a pure read,
    # no egress leg), registered whenever {Gloda} is present — like mail
    # search, and independently useful ("what's Jon's address?").
    #
    # Its reason to exist is {MailCompose}: the user says "email Jon Snow a
    # summary," the model has a *name* and compose needs an *address*. Rather
    # than invent one (a mis-send / exfil risk) or stop to ask, resolve it
    # against the user's own correspondence graph via {Gloda::Contacts#resolve}.
    # It returns *ranked candidates and never auto-picks* — a look-alike
    # sender of received mail can surface, so the human reviewing the To field
    # stays the last line (same posture as {ComposeGuard}).
    #
    # Sharing: +P_shared_locked+ — no state of its own, and the {Gloda}
    # backend it queries locks; see that class's +== Sharing+.
    class ContactSearch < Pikuri::Tool
      # @return [Integer] default / max candidates returned (a short
      #   disambiguation list, not a mailbox scan).
      DEFAULT_LIMIT = 5
      MAX_LIMIT = 15

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Resolve a person's name (or a partial address) to their email address(es), drawn from the user's own Thunderbird correspondence history.

        Usage:
        - Give a name ("Jon Snow") or a fragment ("jon", "acme.com") to find who the user has actually mailed or received mail from.
        - Returns ranked candidates as Name <address> with a familiarity signal — addresses the user has sent mail to rank highest — and never picks one for you.
        - Use it to fill a recipient before drafting mail, then confirm the address with the user: a look-alike sender can appear in received mail, so resolution alone is not proof.
        - Reads Thunderbird's own local index only; it never connects to any server.
      DESC

      # @param backend [Gloda::Contacts] the contact resolver.
      # @return [ContactSearch]
      def initialize(backend:)
        @backend = backend
        super(
          name: 'thunderbird_contact_search',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query, 'A name or partial address to resolve, e.g. "Jon Snow".'
            p.optional_integer :limit, "Max candidates (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 5."
          },
          execute: lambda { |query:, limit: DEFAULT_LIMIT|
            ContactSearch.run_search(backend: @backend, query:, limit:)
          },
          trifecta_legs: Pikuri::Thunderbird::INBOUND_LEGS
        )
      end

      # @return [String] formatted ranked candidates or a no-match line.
      def self.run_search(backend:, query:, limit:)
        limit = limit.to_i.clamp(1, MAX_LIMIT)
        candidates = backend.resolve(query:, limit:)
        return "No contacts found matching #{query.inspect}." if candidates.empty?

        header = "#{candidates.size} contact#{candidates.size == 1 ? '' : 's'} (best first):"
        [header, *candidates.map { |c| render(c) }].join("\n\n")
      end

      # @param c [Hash] one candidate from {Gloda::Contacts#resolve}.
      # @return [String]
      def self.render(c)
        who = c[:name].to_s.empty? ? c[:address] : "#{c[:name]} <#{c[:address]}>"
        <<~CAND.chomp
          #{who}
            #{familiarity(c)}
        CAND
      end
      private_class_method :render

      # @param c [Hash]
      # @return [String] the one-line familiarity signal (Sent history is the
      #   established-contact tell; received-only asks for a check).
      def self.familiarity(c)
        if c[:sent].positive?
          "you have sent mail to this address #{c[:sent]}× (#{c[:count]} appearances in all) — an established contact."
        else
          "appears only in received mail (#{c[:count]}×); you have never sent here, so verify the address before using it."
        end
      end
      private_class_method :familiarity
    end
  end
end
