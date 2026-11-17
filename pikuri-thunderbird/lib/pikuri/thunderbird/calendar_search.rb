# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_calendar_search+ tool — search local + cached
    # Thunderbird calendars by title/description/location. Inbound-only; its
    # read half is +thunderbird_calendar_read+.
    #
    # Recall-first (words OR-matched, ranked by matched-word count) on purpose,
    # mirroring {MailSearch}: tighten it to AND and the model — primed by the
    # forgiving mail search — reads the sparser hits as "no such event".
    #
    # == Empty-corpus guidance
    #
    # Thunderbird keeps a CalDAV calendar's events *in memory only* unless
    # "Offline Support" is enabled, so a calendar can look full in the UI yet
    # have nothing on disk. When no events are cached, this tool returns a
    # self-fixing observation telling the user the one-click fix rather than a
    # bare "no results" — and the same fact rides the description, so the LLM
    # can advise proactively before any empty search.
    #
    # Sharing: +P_shared_locked+ — no state of its own, and the {Calendar}
    # backend it queries locks; see that class's +== Sharing+.
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
        - Free-text query and/or a date range — both optional; supply at least one.
        - To list everything on a day or in a span (e.g. "tomorrow's meetings"), pass a broad or empty query with after/before; a single day is after=before=that date.
        - Each query word is matched independently (across title, description, and location) and events matching more of the words rank first — so extra words broaden the search and surface partial matches, they don't require every word. Matching ignores accents and case. To narrow, add a date range rather than more words.
        - Optionally restrict to recurring events (a repeating series) or single one-off events with the recurrence filter; omit it to get both.
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
            p.optional_string :query, 'Words to find in event title/description/location, e.g. "standup". Omit to list everything in the date range.'
            p.optional_string :after, 'Only events on/after this date, e.g. "2026-01-01".'
            p.optional_string :before, 'Only events on/before this date, e.g. "2026-12-31".'
            p.optional_enum :recurrence, 'Restrict by repetition: "recurring" for repeating series only, "single" for one-off events only. Omit for both.', values: %w[recurring single]
            p.optional_integer :limit, "Max events (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 15."
          },
          execute: lambda { |query: nil, after: nil, before: nil, recurrence: nil, limit: DEFAULT_LIMIT|
            CalendarSearch.run_search(backend: @backend, query:, after:, before:, recurrence:, limit:)
          },
          trifecta_legs: Pikuri::Thunderbird::INBOUND_LEGS
        )
      end

      # @param recurrence [String, nil] +"recurring"+, +"single"+, or +nil+ for
      #   both (mapped to the backend's tri-state +recurring:+ flag).
      # @return [Pikuri::Tool::Result] the events (+"Found 8 events"+), or
      #   {Pikuri::Tool::Result.error}.
      def self.run_search(backend:, query:, after:, before:, recurrence: nil, limit:)
        # Refuse a match-everything call: with no query and no date bound this
        # would dump every cached event. "What's on my calendar" should name a
        # span — steer the model to add after/before (e.g. this week). A lone
        # recurrence filter is still too broad to stand in for a span.
        if [query, after, before].all? { |v| v.to_s.strip.empty? }
          return Pikuri::Tool::Result.error('give a query and/or a date range (after/before) to search for')
        end

        limit = limit.to_i.clamp(1, MAX_LIMIT)
        recurring = { 'recurring' => true, 'single' => false }[recurrence]
        # Fetch one past the cap so a full page is distinguishable from an
        # exhausted calendar (see {MailSearch.run_search}); limit+1 back means
        # more exist and {header} says so, rather than let the model read a
        # full page as the whole calendar.
        hits = backend.search(query:, limit: limit + 1, recurring:,
                              after: DateHelpers.parse_after(after), before: DateHelpers.parse_before(before))
        if hits.empty?
          return Pikuri::Tool::Result.new(content: offline_or_no_match(backend, query),
                                          summary: 'Found 0 events')
        end

        has_more = hits.size > limit
        hits = hits.first(limit)
        Pikuri::Tool::Result.new(
          content: [header(shown: hits.size, has_more:), *hits.map { |h| render(h) }].join("\n\n"),
          summary: "Found #{Pikuri::Tool.pluralize(hits.size, 'event')}#{'+' if has_more}"
        )
      rescue ArgumentError => e
        Pikuri::Tool::Result.error("bad date filter (#{e.message}).")
      rescue DatabaseSnapshot::TornError => e
        Pikuri::Tool::Result.error(e.message)
      end

      # The leading line: affirm completeness when every event fit ("all
      # shown"), or — when capped — name the two levers that get the rest.
      # Adding query words is *not* one (words are OR-matched, so they widen);
      # mirrors {MailSearch.header}, the recall-first principle riding the
      # prompt snippet ({Extension::INBOUND_USAGE}).
      #
      # @param shown [Integer] events actually rendered.
      # @param has_more [Boolean] whether more matched than fit.
      # @return [String]
      def self.header(shown:, has_more:)
        return "#{shown} event#{shown == 1 ? '' : 's'} (all shown):" unless has_more

        "Top #{shown} events — more exist. To see them, raise limit (up to " \
          "#{MAX_LIMIT}) or add an after/before date range. Adding query words " \
          'matches more events (any word), so it will not narrow.'
      end
      private_class_method :header

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
        tail = +''
        tail << "  |  where: #{loc}" unless loc.empty?
        tail << '  |  repeats: yes' if event[:recurring]
        <<~EV.chomp
          #{event[:title].to_s.strip.empty? ? '(untitled)' : event[:title].strip}
            when: #{DateHelpers.when_label(event)}#{tail}
            id: #{event[:event_id]}
        EV
      end
      private_class_method :render
    end
  end
end
