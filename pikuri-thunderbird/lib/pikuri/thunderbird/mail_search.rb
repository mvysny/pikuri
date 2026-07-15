# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_mail_search+ tool — ranked, deduped search over the
    # local Thunderbird mailbox via {Gloda}. Inbound-only (no egress). Its
    # capability pair is +thunderbird_mail_read+, which fetches a hit's full
    # body by the +id:+ handle this tool returns (parent-document retrieval,
    # like corpus search→read).
    class MailSearch < Pikuri::Tool
      # @return [Integer] default / max hits returned.
      DEFAULT_LIMIT = 10
      MAX_LIMIT = 25

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Search the user's local Thunderbird mail (subject, body, sender, recipients, attachment names) and return ranked matches.

        Usage:
        - Free-text query and/or exact filters (sender, recipient, subject, date range, folder) — both optional; supply at least one.
        - Multiple words match broadly (any of them), and the best-matching messages rank first — so extra words widen the net and improve ranking rather than requiring all to appear.
        - With no query, the filters alone list matches newest-first — e.g. the latest mail from a sender is from="alice@acme.com" with no query.
        - Reads Thunderbird's own local index — local folders only; it never connects to any mail server.
        - Returns the best matches with a snippet and a stable id; read a match in full with thunderbird_mail_read.
        - Spam/Junk/Trash are not searched.
      DESC

      # @param backend [Gloda::Mail] the mail backend.
      # @return [MailSearch]
      def initialize(backend:)
        @backend = backend
        super(
          name: 'thunderbird_mail_search',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.optional_string :query, 'Words or a phrase to find, e.g. "invoice from acme". Omit to list by the filters alone (newest first).'
            p.optional_string :from, 'Only mail whose sender contains this, e.g. "alice@acme.com".'
            p.optional_string :to, 'Only mail whose recipients contain this, e.g. "me@example.com".'
            p.optional_string :subject, 'Only mail whose subject contains this, e.g. "receipt".'
            p.optional_string :after, 'Only mail on/after this date, e.g. "2026-01-01".'
            p.optional_string :before, 'Only mail on/before this date, e.g. "2026-06-30".'
            p.optional_string :folder, 'Restrict to one folder by its exact name, e.g. "INBOX".'
            p.optional_integer :limit, "Max matches (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 10."
          },
          execute: lambda { |query: nil, from: nil, to: nil, subject: nil,
                             after: nil, before: nil, folder: nil, limit: DEFAULT_LIMIT|
            MailSearch.run_search(backend: @backend, query:, from:, to:, subject:,
                                  after:, before:, folder:, limit:)
          }
        )
      end

      # @return [String] formatted hits, a no-match line, or +"Error: …"+.
      def self.run_search(backend:, query:, from:, to:, subject:, after:, before:, folder:, limit:)
        limit = limit.to_i.clamp(1, MAX_LIMIT)
        after_t = DateHelpers.parse_after(after)
        before_t = DateHelpers.parse_before(before)
        hits = backend.search(query:, limit:, from:, to:, subject:,
                              after: after_t, before: before_t, folder:)
        if hits.empty?
          return query.to_s.strip.empty? ? 'No mail matched those filters.' \
                                         : "No matching mail found for #{query.inspect}."
        end

        header = "#{hits.size} match#{hits.size == 1 ? '' : 'es'} (best first):"
        [header, *hits.map { |h| render(h) }].join("\n\n")
      rescue ArgumentError => e
        "Error: bad date filter (#{e.message})."
      end

      # @param hit [Hash]
      # @return [String]
      def self.render(hit)
        <<~HIT.chomp
          #{hit[:subject].to_s.strip.empty? ? '(no subject)' : hit[:subject].strip}
            from: #{hit[:from]}  |  #{DateHelpers.short_datetime(hit[:date])}  |  folder: #{hit[:folder]}
            id: #{hit[:message_id]}
            #{hit[:snippet]}
        HIT
      end
      private_class_method :render
    end
  end
end
