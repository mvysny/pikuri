# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_calendar_search+ tool — search local + cached
    # Thunderbird calendars by title/description/location. Inbound-only; its
    # read half is +thunderbird_calendar_read+.
    #
    # == Empty-corpus guidance (Q6)
    #
    # Thunderbird keeps a CalDAV calendar's events *in memory only* unless
    # "Offline Support" is enabled, so a calendar can look full in the UI yet
    # have nothing on disk. When no events are cached, this tool returns a
    # self-fixing observation telling the user the one-click fix rather than a
    # bare "no results" — and the same fact rides the description, so the LLM
    # can advise proactively before any empty search.
    class CalendarSearch < Pikuri::Tool
      DEFAULT_LIMIT = 15
      MAX_LIMIT = 50

      # @return [String] the enable-Offline-Support guidance, reused by the
      #   description and the empty-corpus observation.
      OFFLINE_HINT =
        'No calendar events are cached to disk. If Thunderbird shows events but ' \
        'search finds none, enable Offline Support on each calendar ' \
        '(right-click the calendar → Properties → Offline Support) so its events ' \
        'are stored locally and become searchable.'

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Search the user's local and cached Thunderbird calendars by title, description or location.

        Usage:
        - Free-text query plus an optional date range.
        - To list everything on a day or in a span (e.g. "tomorrow's meetings"), pass a broad or empty query with after/before; a single day is after=before=that date.
        - Multiple words must ALL appear in the event (across its title, description, and location) — so add words to narrow, remove words to widen.
        - Reads Thunderbird's on-disk calendar store — it never connects to any calendar server.
        - Only events cached to disk are visible. A CalDAV calendar keeps events in memory unless its "Offline Support" is enabled (right-click the calendar → Properties → Offline Support); if a search comes back empty but the calendar looks full, that setting is why.
        - Read an event in full with thunderbird_calendar_read.
      DESC

      # @param backend [Calendar] the calendar backend.
      # @return [CalendarSearch]
      def initialize(backend:)
        @backend = backend
        super(
          name: 'thunderbird_calendar_search',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query, 'Words to find in event title/description/location, e.g. "standup".'
            p.optional_string :after, 'Only events on/after this date, e.g. "2026-01-01".'
            p.optional_string :before, 'Only events on/before this date, e.g. "2026-12-31".'
            p.optional_integer :limit, "Max events (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 15."
          },
          execute: lambda { |query:, after: nil, before: nil, limit: DEFAULT_LIMIT|
            CalendarSearch.run_search(backend: @backend, query:, after:, before:, limit:)
          }
        )
      end

      # @return [String]
      def self.run_search(backend:, query:, after:, before:, limit:)
        limit = limit.to_i.clamp(1, MAX_LIMIT)
        hits = backend.search(query:, limit:, after: Format.parse_after(after), before: Format.parse_before(before))
        return offline_or_no_match(backend, query) if hits.empty?

        header = "#{hits.size} event#{hits.size == 1 ? '' : 's'}:"
        [header, *hits.map { |h| render(h) }].join("\n\n")
      rescue ArgumentError => e
        "Error: bad date filter (#{e.message})."
      end

      # Distinguish "no events cached at all" (fixable) from "no match". An
      # empty query is a date-range listing, so its no-match line names the
      # range rather than an empty query string.
      #
      # @return [String]
      def self.offline_or_no_match(backend, query)
        return OFFLINE_HINT if backend.event_count.zero?

        query.to_s.strip.empty? ? 'No events found in that date range.' : "No matching events found for #{query.inspect}."
      end
      private_class_method :offline_or_no_match

      # @return [String]
      def self.render(event)
        loc = event[:location].to_s.strip
        <<~EV.chomp
          #{event[:title].to_s.strip.empty? ? '(untitled)' : event[:title].strip}
            when: #{Format.when_label(event)}#{loc.empty? ? '' : "  |  where: #{loc}"}
            id: #{event[:event_id]}
        EV
      end
      private_class_method :render
    end
  end
end
