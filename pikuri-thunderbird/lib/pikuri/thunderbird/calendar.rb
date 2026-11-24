# frozen_string_literal: true

require 'sqlite3'

module Pikuri
  module Thunderbird
    # Calendar search + read over Thunderbird's +calendar-data+ stores
    # (+cache.sqlite+ for cached network/CalDAV calendars, +local.sqlite+ for
    # local "storage" calendars). Event fields are *normalized columns*, not
    # opaque ICS, so basic reads are a plain +SELECT+ — no ICS parser for the
    # common case. The exceptions are the guest list ({#attendees}) and a
    # series' recurrence ({Recurrence}), which Thunderbird keeps as raw
    # content lines.
    #
    #   cal = Calendar.new(calendar_dbs: profile.calendar_dbs, cache_dir: dir)
    #   cal.event_count     # 0 → nothing cached (prompt the user to enable Offline Support)
    #   cal.search(query: 'standup', limit: 10)
    #   cal.read(event_id: hit[:event_id])
    #
    # Like {Gloda}, every query runs against {DatabaseSnapshot} copies,
    # refreshed when the source generation moves.
    #
    # == Time & all-day encoding
    #
    # +event_start+/+event_end+ are PRTime microseconds of the **UTC**
    # instant; the event's own zone is in +event_start_tz+/+event_end_tz+
    # (an Olson name, +floating+, +UTC+, or a fixed +GMT±HHMM+). All-day
    # events are +flags & 8+ (airtight — correlates 1:1 with a +floating+
    # zone and a midnight-aligned start) with an iCal *exclusive* DTEND
    # (a 1-day event spans exactly one day). {#search}/{#read} return the raw
    # UTC {Time}s + the tz string + an +all_day+ flag; presentation (local
    # display, all-day date rendering) is the tool's job.
    #
    # An all-day start is *floating*: its date's midnight labelled UTC, not an
    # instant. So a date bound or "today", a machine-local instant, dates a
    # timed event as is and an all-day one by its wall clock ({#floating}).
    #
    # {#close} closes the snapshot connections.
    #
    # == Sharing
    #
    # +P_shared_locked+, on {Gloda}'s terms and for its reasons — see that
    # class's +== Sharing+ for the contracts (lock spans the query, no
    # re-entry, {#close} needs no refcount, +cache_dir+ stays unshared). The
    # only difference is shape: this class has no +with_fresh_db+ seam, so the
    # guard sits on each public query instead of one chokepoint.
    class Calendar
      LOGGER = Pikuri.logger_for('Thunderbird::Calendar')

      # @return [Integer] all-day bit in +cal_events.flags+.
      ALL_DAY_FLAG = 8

      # @return [Integer] +HAS_RECURRENCE+ bit in +cal_events.flags+ — set on
      #   the master row of any event with an RRULE/RDATE (Thunderbird's
      #   +CAL_ITEM_FLAG+, comm-central +calStorageHelpers.sys.mjs+). Airtight
      #   for the master, same as {ALL_DAY_FLAG}.
      RECURRENCE_FLAG = 16

      # @param calendar_dbs [Array<String>] existing calendar store paths
      #   (see {Profile#calendar_dbs}); may be empty.
      # @param cache_dir [String] private 0700 dir for the snapshot copies.
      # @return [Calendar]
      def initialize(calendar_dbs:, cache_dir:)
        @sources = calendar_dbs
        @snapshots = @sources.to_h do |src|
          [src, DatabaseSnapshot.new(source: src, dir: File.join(cache_dir, File.basename(src, '.sqlite')))]
        end
        @conns = {}
        @lock = Mutex.new
      end

      # @return [Integer] total events cached to disk across all stores. Zero
      #   means every calendar is memory-only (Offline Support off); the
      #   tool turns that into a self-fixing observation.
      def event_count
        @lock.synchronize do
          ensure_fresh
          @conns.values.sum { |db| db.get_first_value('SELECT count(*) FROM cal_events').to_i }
        end
      end

      # Search events by title / description / location.
      #
      #   cal.search(query: 'hang around', recurring: false, limit: 15)
      #   # the one-off events titled "…hang around" — not the 50 whose
      #   # description merely contains the common word "around"
      #
      # **Phrase-first, OR-fallback** ranking: when the query's words appear
      # *adjacently* in some event ({#search_db}'s +:phrase+), only those hits
      # are kept; the loose OR-any-word recall runs only as a fallback when no
      # event matches the phrase (so a scattered-word query like "vaadin party"
      # still hits). Within the kept set, most-words-matched ranks first,
      # newest breaks ties. A single-word query has no adjacency to enforce, so
      # it stays pure substring recall.
      #
      # A recurring series is stored as a master row dated at its first
      # occurrence, plus one row per modified occurrence. With a date range,
      # {Recurrence} expands it and each occurrence in the range is a hit of
      # its own, earliest first from an +after+:
      #
      #   cal.search(query: '', limit: 15, after: monday, before: friday_night)
      #   # => standup Mon, standup Wed, planning Thu, standup Fri
      #
      # Without one, the series surfaces once, dated at its current occurrence
      # (see {#current_of}), newest first. Google additionally splits a
      # "this-and-following" edit into separate masters
      # +UID_R<ical-datetime>@google.com+; {#base_uid} plus {#fold_series}
      # collapse the whole lot to that one hit.
      #
      # @param query [String] substring over title + DESCRIPTION + LOCATION.
      # @param limit [Integer] max events.
      # @param after [Time, nil] only events starting on/after this instant.
      # @param before [Time, nil] only events starting on/before this instant.
      # @param recurring [Boolean, nil] +true+ → only recurring events, +false+
      #   → only single (non-recurring) events, +nil+ → both.
      # @param now [Time] the clock {#current_of} reads.
      # @return [Array<Hash>] +[{event_id:, title:, start: Time, end: Time,
      #   all_day: Boolean, recurring: Boolean, start_tz:, end_tz:, location:}, …]+
      def search(query:, limit:, after: nil, before: nil, recurring: nil, now: Time.now)
        words = query.to_s.scan(/[[:alnum:]]+/).map { |w| fold(w) }
        ranged = !(after || before).nil?
        today = local_midnight(now)
        # Only the fetch is guarded — the folding and ranking below run on
        # materialized rows and touch no connection.
        rows = @lock.synchronize do
          ensure_fresh
          @conns.values.flat_map { |db| search_db(db, words:, after:, before:, today:) }
        end
        series =
          if ranged
            rows.map { |h| h.merge(recurring: h[:recurring] || h[:occurrence]).except(:occurrence) }
          else
            # Group on the *base* UID (see #base_uid), not the raw id, so Google's
            # this-and-following splits fold into one series instead of 20+ hits.
            rows.group_by { |h| base_uid(h[:event_id]) }.map { |_uid, group| fold_series(group, today) }
          end
        # Phrase-first: once any event matches the words adjacently, drop the
        # OR-any-word matches — else a two-word query floods with events sharing
        # only a common word (e.g. "around") in a description. The OR set is the
        # fallback when no event matches the phrase.
        series.select! { |h| h[:phrase] } if series.any? { |h| h[:phrase] }
        # Recurrence filter runs *after* folding: an occurrence row lacks the
        # master's HAS_RECURRENCE flag, so filtering per-row in SQL mislabeled
        # every occurrence "single" and leaked the whole series under
        # recurrence:single. Folding classifies the series as a whole first.
        series.select! { |h| h[:recurring] == recurring } unless recurring.nil?
        # Rank across stores by matched-word count, then date. :score/:phrase
        # are internal ranking keys (see #search_db), dropped from the shape.
        # From an +after+ the cap must cut the far end, not the days nearest it.
        order = after ? 1 : -1
        series.sort_by { |h| [-h[:score], order * (h[:start]&.to_i || 0)] }
              .first(limit).map { |h| h.except(:score, :phrase) }
      end

      # Full event detail for one event UID; a recurring one is dated at its
      # current occurrence (see {#current_of}).
      #
      # @param event_id [String] the {#search} handle (the event UID).
      # @param now [Time] the clock {#current_of} reads.
      # @return [Hash, nil] the search shape plus +:description+, +:status+,
      #   and +:attendees+ (see {#attendees}), or +nil+ if not found.
      def read(event_id:, now: Time.now)
        @lock.synchronize do
          ensure_fresh
          @conns.each_value do |db|
            # A recurring UID has several rows (master + occurrence exceptions);
            # prefer the master (recurrence_id NULL sorts first) for a stable read.
            rows = db.execute(<<~SQL, [event_id])
              SELECT id, title, event_start, event_end, event_start_tz, event_end_tz, flags, cal_id, recurrence_id
              FROM cal_events WHERE id = ?
              ORDER BY (recurrence_id IS NOT NULL)
            SQL
            next if rows.empty?

            master = build_event(rows.first)
            if master[:recurring]
              today = local_midnight(now)
              cal_id = rows.first[7]
              edited = rows.drop(1).select { |r| r[7] == cal_id }.map { |r| build_event(r) }
              current = pick_current([current_of(master, cal_id, series_data(db, [cal_id, event_id]), today), *edited], today)
              master = master.merge(start: current[:start], end: current[:end])
            end
            return master.merge(properties(db, event_id), attendees: attendees(db, event_id))
          end
        end
        nil
      end

      # Idempotent, and safe while another agent shares this instance — the
      # next query reopens.
      #
      # @return [void]
      def close
        @lock.synchronize do
          @conns.each_value(&:close)
          @conns.clear
        end
      end

      private

      # (Re)snapshot + reopen each store whose source generation moved. While
      # Thunderbird is busy writing, the older copy keeps serving.
      #
      # @return [void]
      # @raise [DatabaseSnapshot::TornError] Thunderbird is busy and a store
      #   has no copy yet.
      def ensure_fresh
        @snapshots.each do |src, snap|
          next if @conns[src] && snap.current?
          next unless snap.refresh || @conns[src].nil?

          @conns.delete(src)&.close
          @conns[src] = SQLite3::Database.new(snap.path, flags: SQLite3::Constants::Open::READONLY)
        end
      end

      # Casefold + strip diacritics (NFD-decompose, drop the combining marks),
      # so a folded needle substring-matches a folded haystack accent-blind.
      #
      #   fold("Dröp")   # => "drop"
      #
      # @param str [String, nil]
      # @return [String] the folded text ("" for +nil+/blank).
      def fold(str) = str.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase

      # Fetch the date-filtered events (native SQL), then fold + match + score
      # in Ruby — never in SQL (the recurrence filter also runs in Ruby, after
      # {#fold_series}, since it's a per-*series* not per-row decision). Folding is a Ruby-side
      # +unicode_normalize+; as a per-row SQLite callback inside a correlated
      # subquery it pegged a core for tens of seconds, so the two SQL reads
      # here (events + their LOCATION/DESCRIPTION) are flat single scans and
      # all the folding runs once per field in-process.
      #
      # Matching is recall-first, mirroring the mail path (which ORs words +
      # bm25-ranks): a word matches if the folded query term is a substring of
      # the folded title/description/location, and a hit's +:score+ is how many
      # of the words matched — the calendar analogue of bm25 (no corpus stats
      # to rank with). Each hit also carries +:phrase+ ({#phrase_match?}), which
      # {#search} uses to prefer adjacent-word matches; the OR score is the
      # fallback ranking, never a stricter AND gate here — an LLM that has seen
      # forgiving mail search would misread a bare AND's "fewer hits" as "no
      # such event exists".
      #
      # @param words [Array<String>] pre-folded query terms (empty ⇒ list all).
      # @param today [Time] local midnight, for {#current_of}.
      # @return [Array<Hash>] hits carrying +:score+/+:phrase+ (for {#search})
      #   and +:occurrence+ (for {#fold_series}); all dropped from the shape.
      def search_db(db, words:, after:, before:, today:)
        filters = []
        binds = []
        [[after, '>='], [before, '<=']].each do |bound, op|
          next unless bound

          filters << "event_start #{op} CASE WHEN flags & #{ALL_DAY_FLAG} != 0 THEN ? ELSE ? END"
          binds.push(to_prtime(floating(bound)), to_prtime(bound))
        end
        where = filters.empty? ? '1' : filters.join(' AND ')
        # A master is dated at its first occurrence, so the range can't
        # select it; #occurrences decides once it is expanded.
        where = "(#{where}) OR (recurrence_id IS NULL AND flags & #{RECURRENCE_FLAG} != 0)" if after || before

        events = db.execute(<<~SQL, binds)
          SELECT id, title, event_start, event_end, event_start_tz, event_end_tz, flags, recurrence_id, cal_id
          FROM cal_events WHERE #{where}
        SQL
        text = searchable_text(db)
        series = nil

        events.flat_map do |row|
          loc, desc = text[row[0]]
          # recurrence_id is set only on a recurring series' occurrence rows
          # (NULL on a master or a single event); it's what marks the flood
          # rows so #fold_series can class the series recurring even though the
          # occurrence itself lacks the master's HAS_RECURRENCE flag.
          hit = build_event(row).merge(location: loc, occurrence: !row[7].nil? && row[7].to_i != 0)
          # Empty query → list everything (score 0, date-ordered by #search).
          if words.empty?
            hit = hit.merge(score: 0, phrase: false)
          else
            haystack = fold("#{row[1]} #{loc} #{desc}")
            score = words.count { |w| haystack.include?(w) }
            next [] if score.zero?

            hit = hit.merge(score: score, phrase: phrase_match?(haystack, words))
          end
          next [hit] unless hit[:recurring] && !hit[:occurrence]

          series ||= series_data(db)
          after || before ? occurrences(hit, row[8], series, after:, before:) : [current_of(hit, row[8], series, today)]
        end
      end

      # A master's hit repeated once per occurrence in the range, each with
      # its own start and end. A series {Recurrence} won't expand keeps its
      # one stored row, as long as that falls in the range.
      #
      # @param hit [Hash] the master's hit (see {#search_db}).
      # @param cal_id [String]
      # @param series [Array(Hash, Hash)] from {#series_data}.
      # @return [Array<Hash>]
      def occurrences(hit, cal_id, series, after:, before:)
        return [] unless hit[:start]

        after = frame(hit, after)
        before = frame(hit, before)
        recurrence(hit, cal_id, series).starts(after:, before:).map { |start| starting_at(hit, start) }
      rescue Recurrence::Unexpandable => e
        LOGGER.warn("not expanding recurring event #{hit[:event_id]}: #{e.message}")
        stored = hit[:start].between?(after || hit[:start], before || hit[:start])
        stored ? [hit] : []
      end

      # A master's hit dated at the series' current occurrence: the first on
      # or after +today+, else the last before it, so an ended series shows
      # when it last met.
      #
      #   current_of(standup, 'c1', series, Time.local(2026, 11, 17))
      #   # => standup's hit with start: 2026-11-18 07:00 UTC — Wednesday's
      #
      # It keeps its stored first date when nothing falls within
      # {Recurrence::MAX_SPAN} either side, or the series won't expand.
      #
      # @param hit [Hash] the master's hit (see {#search_db}).
      # @param cal_id [String]
      # @param series [Array(Hash, Hash)] from {#series_data}.
      # @param today [Time] local midnight.
      # @return [Hash]
      def current_of(hit, cal_id, series, today)
        return hit unless hit[:start]

        today = frame(hit, today)
        rec = recurrence(hit, cal_id, series)
        start = rec.starts(after: today, before: nil).first || rec.starts(after: nil, before: today - 1).last
        start ? starting_at(hit, start) : hit
      rescue Recurrence::Unexpandable => e
        LOGGER.warn("not expanding recurring event #{hit[:event_id]}: #{e.message}")
        hit
      end

      # @param hits [Array<Hash>] dated hits of one series.
      # @param today [Time] local midnight.
      # @return [Hash] the earliest on or after +today+, else the latest.
      def pick_current(hits, today)
        upcoming = hits.select { |h| h[:start] && h[:start] >= frame(h, today) }
        upcoming.empty? ? hits.max_by { |h| h[:start]&.to_i || 0 } : upcoming.min_by { |h| h[:start] }
      end

      # @return [Recurrence] the series of a master's hit.
      # @raise [Recurrence::Unexpandable]
      def recurrence(hit, cal_id, series)
        lines, overridden = series.map { |by_key| by_key.fetch([cal_id, hit[:event_id]], nil) }
        Recurrence.new(start: hit[:start], tz: hit[:start_tz], lines: lines || [], overridden: overridden || Set.new)
      end

      # @return [Hash] +hit+ moved to +start+, keeping its duration.
      def starting_at(hit, start)
        duration = hit[:end] - hit[:start] if hit[:end]
        hit.merge(start: start, end: duration && (start + duration))
      end

      # +time+'s local wall clock labelled UTC, the frame an all-day event is
      # stored in:
      #
      #   floating(Time.local(2026, 6, 1))   # => 2026-06-01 00:00:00 UTC, in any zone
      #
      # @param time [Time] a machine-local instant: a bound, or today's midnight.
      # @return [Time]
      def floating(time)
        local = time.getlocal
        Time.utc(local.year, local.month, local.day, local.hour, local.min, local.sec)
      end

      # @param hit [Hash] a dated hit.
      # @param time [Time, nil]
      # @return [Time, nil] +time+ to compare +hit+'s start with: {#floating}
      #   for an all-day hit, else unchanged.
      def frame(hit, time) = hit[:all_day] && time ? floating(time) : time

      # @param now [Time]
      # @return [Time] the start of +now+'s day, machine-local.
      def local_midnight(now)
        local = now.getlocal
        Time.local(local.year, local.month, local.day)
      end

      # One flat scan each of the recurrence lines and of the edited
      # occurrences' original starts, keyed by +[cal_id, uid]+ — a UID alone
      # can repeat across calendars.
      #
      # @param only [Array(String, String), nil] one +[cal_id, uid]+ to read
      #   instead of all.
      # @return [Array(Hash{Array(String, String) => Array<String>},
      #   Hash{Array(String, String) => Set<Integer>})] the +icalString+ lines,
      #   and the +recurrence_id+s in epoch seconds.
      def series_data(db, only = nil)
        binds = only || []
        lines = {}
        db.execute("SELECT cal_id, item_id, icalString FROM cal_recurrence#{' WHERE cal_id = ? AND item_id = ?' if only}",
                   binds) do |cal_id, uid, ical|
          (lines[[cal_id, uid]] ||= []) << ical
        end
        overridden = {}
        db.execute("SELECT cal_id, id, recurrence_id FROM cal_events WHERE recurrence_id IS NOT NULL#{' AND cal_id = ? AND id = ?' if only}",
                   binds) do |cal_id, uid, rid|
          (overridden[[cal_id, uid]] ||= Set.new) << (rid / 1_000_000)
        end
        [lines, overridden]
      end

      # Whether the query's words appear *adjacently* in +folded_haystack+
      # (token-separated by any non-alnum run). Collapsing punctuation to single
      # spaces makes the joined needle a plain substring test:
      #
      #   phrase_match?("hammer drop hang around", %w[hang around])  # => true
      #   phrase_match?("hangaround event",        %w[hang around])  # => false
      #   phrase_match?("hangout notes",           %w[hang])         # => true  (single word ⇒ substring)
      #
      # A single-word needle has no interior space, so it degrades to today's
      # substring recall — the phrase gate only bites multi-word queries.
      #
      # @param folded_haystack [String] already {#fold}ed title+location+desc.
      # @param words [Array<String>] pre-folded query terms.
      # @return [Boolean]
      def phrase_match?(folded_haystack, words)
        folded_haystack.gsub(/[^[:alnum:]]+/, ' ').include?(words.join(' '))
      end

      # The recurring-series UID shared by Google's this-and-following splits:
      # strip the +_R<ical-datetime>+ suffix Thunderbird stores on each split
      # master, so they fold into one series (see {#search}).
      #
      #   base_uid("6soj…_R20191024T103000@google.com")  # => "6soj…@google.com"
      #   base_uid("0k6drt…@google.com")                 # => "0k6drt…@google.com" (unchanged)
      #
      # @param id [String] a +cal_events.id+.
      # @return [String] the id with any split suffix removed.
      def base_uid(id) = id.to_s.sub(/_R\d{8}T\d{6}(?=@|\z)/, '')

      # Collapse the stored rows of one series — a single event is one row; a
      # recurring series is a master plus one row per modified occurrence, plus
      # (for Google) one master per this-and-following split — into a single
      # hit, so a weekly meeting surfaces once instead of once per occurrence or
      # split. The series counts as recurring if any row is a master
      # (HAS_RECURRENCE) or an occurrence (recurrence_id set), a phrase hit if
      # any row matched the phrase; the current row represents it (see
      # {#pick_current}; its real id stays the read handle), and the group's
      # best word-count is its score.
      #
      # @param group [Array<Hash>] rows sharing a {#base_uid} (from {#search_db}),
      #   masters already at their {#current_of} dates.
      # @param today [Time] local midnight.
      # @return [Hash] one merged hit (search shape + +:score+ + +:phrase+).
      def fold_series(group, today)
        recurring = group.any? { |h| h[:recurring] || h[:occurrence] }
        rep = pick_current(group, today)
        rep.merge(recurring: recurring, score: group.map { |h| h[:score] }.max,
                  phrase: group.any? { |h| h[:phrase] }).except(:occurrence)
      end

      # One flat scan of the LOCATION/DESCRIPTION properties (vs. a correlated
      # subquery per event), indexed by event id for the Ruby-side match.
      #
      # @return [Hash{String => Array(String, String)}] +id => [location, description]+.
      def searchable_text(db)
        by_id = Hash.new { |h, k| h[k] = [nil, nil] }
        db.execute("SELECT item_id, key, value FROM cal_properties WHERE key IN ('LOCATION','DESCRIPTION')") do |item_id, key, value|
          by_id[item_id][key == 'LOCATION' ? 0 : 1] = value
        end
        by_id
      end

      # @param row [Array] +[id, title, start_us, end_us, start_tz, end_tz, flags]+
      # @return [Hash] see {#search} for the shape (incl. +all_day+/+recurring+).
      def build_event(row)
        id, title, start_us, end_us, start_tz, end_tz, flags = row
        {
          event_id: id, title: title,
          start: to_time(start_us), end: to_time(end_us),
          all_day: (flags.to_i & ALL_DAY_FLAG) != 0,
          recurring: (flags.to_i & RECURRENCE_FLAG) != 0,
          start_tz: start_tz, end_tz: end_tz
        }
      end

      # The event's attendees + organizer, over the raw +ATTENDEE+/+ORGANIZER+
      # lines in +cal_attendees+ (the one field Thunderbird leaves as opaque
      # ICS — {IcalLine.attendee} does the parsing). Master row only
      # (recurrence_id NULL) — the canonical guest list, not per-occurrence RSVP
      # overrides. Organizer(s) sort first, attendees keep file order.
      #
      # @return [Array<IcalLine::Attendee>] +[]+ for an event with no guests.
      def attendees(db, event_id)
        rows = db.execute('SELECT icalString FROM cal_attendees WHERE item_id = ? AND recurrence_id IS NULL', [event_id])
        people = rows.filter_map { |(ical)| IcalLine.attendee(ical) unless ical.to_s.strip.empty? }
        orgs, guests = people.partition(&:organizer?)
        orgs + guests
      end

      # @return [Hash] +{location:, description:, status:}+ from cal_properties.
      def properties(db, event_id)
        props = db.execute('SELECT key, value FROM cal_properties WHERE item_id = ?', [event_id]).to_h
        status = db.get_first_value('SELECT ical_status FROM cal_events WHERE id = ? LIMIT 1', [event_id])
        { location: props['LOCATION'], description: props['DESCRIPTION'], status: status }
      end

      # @return [Time, nil]
      def to_time(prtime_us)
        return nil if prtime_us.nil? || prtime_us.to_i.zero?

        Time.at(prtime_us / 1_000_000).utc
      end

      # @return [Integer]
      def to_prtime(time) = (time.to_i * 1_000_000)
    end
  end
end
