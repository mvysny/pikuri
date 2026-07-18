# frozen_string_literal: true

require 'sqlite3'

module Pikuri
  module Thunderbird
    # Calendar search + read over Thunderbird's +calendar-data+ stores
    # (+cache.sqlite+ for cached network/CalDAV calendars, +local.sqlite+ for
    # local "storage" calendars). Event fields are *normalized columns*, not
    # opaque ICS, so basic reads are a plain +SELECT+ — no ICS parser for the
    # common case.
    #
    #   cal = Calendar.new(calendar_dbs: profile.calendar_dbs, cache_dir: dir)
    #   cal.available?      # any calendar store on disk?
    #   cal.event_count     # 0 → nothing cached (prompt the user to enable Offline Support)
    #   cal.search(query: 'standup', limit: 10)
    #   cal.read(event_id: hit[:event_id])
    #
    # Like {Gloda}, every query runs against {DatabaseSnapshot} copies (opened
    # +?immutable=1+, so a WAL store reads as-of-last-checkpoint), refreshed
    # when the source generation moves.
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
    # {#close} closes the snapshot connections. Not thread-safe.
    class Calendar
      LOGGER = Pikuri.logger_for('Thunderbird::Calendar')

      # @return [Integer] all-day bit in +cal_events.flags+.
      ALL_DAY_FLAG = 8

      # @return [Integer] +HAS_RECURRENCE+ bit in +cal_events.flags+ — set on
      #   the master row of any event with an RRULE/RDATE (Thunderbird's
      #   +CAL_ITEM_FLAG+). Airtight for the master, same as {ALL_DAY_FLAG}.
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
        @generations = {}
      end

      # @return [Boolean] whether any calendar store exists on disk (the
      #   calendar tools register regardless — see the empty-state guidance
      #   in {Tools} — but this gates whether a snapshot is even attempted).
      def available? = !@sources.empty?

      # @return [Integer] total events cached to disk across all stores. Zero
      #   means every calendar is memory-only (Offline Support off); the
      #   tool turns that into a self-fixing observation.
      def event_count
        ensure_fresh
        @conns.values.sum { |db| db.get_first_value('SELECT count(*) FROM cal_events').to_i }
      end

      # Search events by title / description / location; best match first (most
      # query words matched), newest breaks ties. Recall-first — a partial
      # match still surfaces (see {#search_db}).
      #
      # A recurring series stores a master row plus one row per modified
      # occurrence, all sharing the event UID; {#fold_series} collapses them to
      # one hit so a weekly meeting surfaces once, not once per occurrence.
      #
      # @param query [String] substring over title + DESCRIPTION + LOCATION.
      # @param limit [Integer] max events.
      # @param after [Time, nil] only events starting on/after this instant.
      # @param before [Time, nil] only events starting on/before this instant.
      # @param recurring [Boolean, nil] +true+ → only recurring events, +false+
      #   → only single (non-recurring) events, +nil+ → both.
      # @return [Array<Hash>] +[{event_id:, title:, start: Time, end: Time,
      #   all_day: Boolean, recurring: Boolean, start_tz:, end_tz:, location:}, …]+
      def search(query:, limit:, after: nil, before: nil, recurring: nil)
        ensure_fresh
        words = query.to_s.scan(/[[:alnum:]]+/).map { |w| fold(w) }
        rows = @conns.values.flat_map { |db| search_db(db, words:, after:, before:) }
        series = rows.group_by { |h| h[:event_id] }.map { |_uid, group| fold_series(group) }
        # Recurrence filter runs *after* folding: an occurrence row lacks the
        # master's HAS_RECURRENCE flag, so filtering per-row in SQL mislabeled
        # every occurrence "single" and leaked the whole series under
        # recurrence:single. Folding classifies the series as a whole first.
        series.select! { |h| h[:recurring] == recurring } unless recurring.nil?
        # Rank across stores by matched-word count, then recency. :score is an
        # internal ranking key (see #search_db), dropped from the returned shape.
        series.sort_by { |h| [-h[:score], -(h[:start]&.to_i || 0)] }
              .first(limit).map { |h| h.except(:score) }
      end

      # Full event detail for one event UID.
      #
      # @param event_id [String] the {#search} handle (the event UID).
      # @return [Hash, nil] the search shape plus +:description+ and
      #   +:status+, or +nil+ if not found.
      def read(event_id:)
        ensure_fresh
        @conns.each_value do |db|
          # A recurring UID has several rows (master + occurrence exceptions);
          # prefer the master (recurrence_id NULL sorts first) for a stable read.
          row = db.execute(<<~SQL, [event_id]).first
            SELECT id, title, event_start, event_end, event_start_tz, event_end_tz, flags, ical_status
            FROM cal_events WHERE id = ?
            ORDER BY (recurrence_id IS NOT NULL) LIMIT 1
          SQL
          next unless row

          return build_event(row).merge(properties(db, event_id))
        end
        nil
      end

      # @return [void]
      def close
        @conns.each_value(&:close)
        @conns.clear
      end

      private

      # (Re)snapshot + reopen each store whose source generation moved.
      #
      # @return [void]
      def ensure_fresh
        @snapshots.each do |src, snap|
          live = DatabaseSnapshot.change_counter(src)
          next if @conns[src] && @generations[src] && live == @generations[src]

          @conns[src]&.close
          snap.refresh
          @conns[src] = SQLite3::Database.new("file:#{snap.path}?immutable=1",
                                              flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
          @generations[src] = snap.generation
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
      # to rank with). Keeping the two tools aligned is the point: an LLM that
      # has seen forgiving mail search assumes the same here, so a stricter AND
      # would make it misread "fewer hits" as "no such event exists".
      #
      # @param words [Array<String>] pre-folded query terms (empty ⇒ list all).
      # @return [Array<Hash>] hits carrying an extra +:score+ (for {#search})
      #   and +:occurrence+ (for {#fold_series}); both dropped from the shape.
      def search_db(db, words:, after:, before:)
        filters = []
        binds = []
        # Date bounds are compared in the machine-local frame (the caller
        # parses a bare date to local midnight; parse_before extends it to
        # end-of-day). Correct for timed events in any zone. Caveat: all-day
        # events are stored as *floating* UTC-midnight, so in a far-*western*
        # zone (local midnight is hours ahead of UTC) an all-day event on day
        # D can fall just before a local-frame "day D" lower bound. Fine for
        # UTC/eastern zones; a fully correct fix needs per-event-type date
        # extraction (deferred — see ideas/thunderbird.md open questions).
        if after
          filters << 'event_start >= ?'
          binds << to_prtime(after)
        end
        if before
          filters << 'event_start <= ?'
          binds << to_prtime(before)
        end
        where = filters.empty? ? '1' : filters.join(' AND ')

        events = db.execute(<<~SQL, binds)
          SELECT id, title, event_start, event_end, event_start_tz, event_end_tz, flags, recurrence_id
          FROM cal_events WHERE #{where}
        SQL
        text = searchable_text(db)

        events.filter_map do |row|
          loc, desc = text[row[0]]
          # recurrence_id is set only on a recurring series' occurrence rows
          # (NULL on a master or a single event); it's what marks the flood
          # rows so #fold_series can class the series recurring even though the
          # occurrence itself lacks the master's HAS_RECURRENCE flag.
          hit = build_event(row).merge(location: loc, occurrence: !row[7].nil? && row[7].to_i != 0)
          # Empty query → list everything (score 0, date-ordered by #search).
          next hit.merge(score: 0) if words.empty?

          haystack = fold("#{row[1]} #{loc} #{desc}")
          score = words.count { |w| haystack.include?(w) }
          score.zero? ? nil : hit.merge(score: score)
        end
      end

      # Collapse the stored rows of one event UID — a single event is one row;
      # a recurring series is a master plus one row per modified occurrence — into
      # a single hit, so a weekly meeting surfaces once instead of once per
      # occurrence. The series counts as recurring if any row is a master
      # (HAS_RECURRENCE) or an occurrence (recurrence_id set); the earliest
      # in-range row represents it, and the group's best word-count is its score.
      #
      # @param group [Array<Hash>] rows sharing an +event_id+ (from {#search_db}).
      # @return [Hash] one merged hit (search shape + +:score+).
      def fold_series(group)
        recurring = group.any? { |h| h[:recurring] || h[:occurrence] }
        best = group.map { |h| h[:score] }.max
        rep = group.min_by { |h| h[:start]&.to_i || 0 }
        rep.merge(recurring: recurring, score: best).except(:occurrence)
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
