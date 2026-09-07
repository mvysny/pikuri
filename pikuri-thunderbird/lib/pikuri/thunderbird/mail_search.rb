# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_mail_search+ tool — ranked, deduped search over the
    # local Thunderbird mailbox via {Gloda}. Inbound-only (no egress). Its
    # capability pair is +thunderbird_mail_read+, which fetches a hit's full
    # body by the +id:+ handle this tool returns (parent-document retrieval,
    # like corpus search→read).
    #
    # Sharing: +P_shared_locked+ — no state of its own, and the {Gloda}
    # backend it queries locks; see that class's +== Sharing+.
    class MailSearch < Pikuri::Tool
      # @return [Integer] default / max hits returned. The cap protects the
      #   host's context budget (a snippet-laden page is dear on a small local
      #   model); past it, ranking is moot and narrowing is the right move —
      #   which is what {header} steers the model toward.
      DEFAULT_LIMIT = 15
      MAX_LIMIT = 50

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
          },
          trifecta_legs: Pikuri::Thunderbird::INBOUND_LEGS
        )
      end

      # @return [Pikuri::Tool::Result, String] the hits as a
      #   {Pikuri::Tool::Result} (+"Found 8 messages"+ — the count only: a
      #   subject line is whatever the sender wrote), or a bare +"Error: …"+.
      def self.run_search(backend:, query:, from:, to:, subject:, after:, before:, folder:, limit:)
        # Refuse a match-everything call: with no query and no filter this
        # would dump the whole mailbox newest-first. Every real request has at
        # least one criterion — steer the model to name one.
        if [query, from, to, subject, after, before, folder].all? { |v| v.to_s.strip.empty? }
          return 'Error: give at least one of query, from, to, subject, after, before, or folder to search for.'
        end

        limit = limit.to_i.clamp(1, MAX_LIMIT)
        after_t = DateHelpers.parse_after(after)
        before_t = DateHelpers.parse_before(before)
        # Fetch one past the cap so a full page is distinguishable from an
        # exhausted mailbox: getting limit+1 back means more exist, and the
        # header must say so — an LLM reads a full page as "that's everything"
        # and gives a silently incomplete answer. (Heavy Gmail label-dup can
        # false-negative if the (limit+1)th distinct match falls outside the
        # backend's over-fetch window; rare, accepted.)
        hits = backend.search(query:, limit: limit + 1, from:, to:, subject:,
                              after: after_t, before: before_t, folder:)
        if hits.empty?
          empty = query.to_s.strip.empty? ? 'No mail matched those filters.' \
                                          : "No matching mail found for #{query.inspect}."
          return Pikuri::Tool::Result.new(content: empty, summary: 'Found 0 messages')
        end

        has_more = hits.size > limit
        hits = hits.first(limit)
        Pikuri::Tool::Result.new(
          content: [header(shown: hits.size, has_more:), *hits.map { |h| render(h) }].join("\n\n"),
          summary: "Found #{Pikuri::Tool.pluralize(hits.size, 'message')}#{'+' if has_more}"
        )
      rescue ArgumentError => e
        "Error: bad date filter (#{e.message})."
      end

      # The leading line: affirm completeness when every match fit ("all
      # shown", so the model can trust the set), or — when capped — name the
      # two levers that get the rest. Adding query words is deliberately *not*
      # one: the search ORs its terms, so more words widen the net. The
      # recall-first principle itself rides the prompt snippet
      # ({Extension::INBOUND_USAGE}); this is the terse per-search reminder.
      #
      # Fuzzy on purpose ("more exist", not the total one +COUNT(DISTINCT)+
      # would give): an exact number over an OR-recall corpus reads as
      # false precision — "you have 47 emails about X", where 47 is a loose
      # any-word tally. For the same reason there is no +page+ param:
      # +bm25, date DESC+ isn't offset-stable across snapshot refreshes, and
      # paging tempts the model to walk on instead of narrowing.
      #
      # @param shown [Integer] hits actually rendered.
      # @param has_more [Boolean] whether more matched than fit.
      # @return [String]
      def self.header(shown:, has_more:)
        return "#{shown} match#{shown == 1 ? '' : 'es'} (best first, all shown):" unless has_more

        "Top #{shown} matches (best first) — more exist. To see them, raise limit " \
          "(up to #{MAX_LIMIT}) or narrow with from/to/subject/date/folder. Adding " \
          'query words matches more mail (any word), so it will not narrow.'
      end
      private_class_method :header

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
