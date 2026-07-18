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
        hits = @conns.values.flat_map { |db| search_db(db, query:, after:, before:, recurring:, limit:) }
        # Rank across stores by matched-word count, then recency. :score is an
        # internal ranking key (see #search_db), dropped from the returned shape.
        hits.sort_by { |h| [-h[:score].to_i, -(h[:start]&.to_i || 0)] }
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
          row = db.execute(<<~SQL, [event_id]).first
            SELECT id, title, event_start, event_end, event_start_tz, event_end_tz, flags, ical_status
            FROM cal_events WHERE id = ? LIMIT 1
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
          db = SQLite3::Database.new("file:#{snap.path}?immutable=1",
                                     flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
          # Diacritic-fold both sides of every text LIKE (see #search_db), so
          # "Drop" finds "Dröp" — matching the mail path, whose FTS5 unicode61
          # tokenizer already strips diacritics for free.
          db.create_function('pk_fold', 1) { |func, value| func.result = fold(value) }
          @conns[src] = db
          @generations[src] = snap.generation
        end
      end

      # Casefold + strip diacritics (NFD-decompose, drop the combining marks),
      # so a folded needle substring-matches a folded haystack accent-blind.
      # +nil+-safe: SQLite passes +NULL+ columns through as +nil+.
      #
      #   fold("Dröp")   # => "drop"
      #
      # @param str [String, nil]
      # @return [String, nil]
      def fold(str)
        return nil if str.nil?

        str.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase
      end

      # @return [Array<Hash>] hits carrying an extra +:score+ (matched-word
      #   count) for the cross-store rank in {#search}.
      def search_db(db, query:, after:, before:, recurring:, limit:)
        # Word matching is recall-first, mirroring the mail path (which ORs
        # words + bm25-ranks): OR the words and rank a hit by how many it
        # contains, across title / DESCRIPTION / LOCATION (accent- and
        # case-folded on both sides via pk_fold — see #ensure_fresh). The
        # matched-word count is the calendar analogue of bm25 (no corpus
        # stats to rank with); ties break on recency. Keeping the two tools
        # aligned is the point: an LLM that has seen forgiving mail search
        # assumes the same here, so a stricter AND would make it misread
        # "fewer hits" as "no such event exists".
        score_binds = []
        score = query.to_s.scan(/[[:alnum:]]+/).map do |word|
          score_binds << fold(word) << fold(word)
          <<~EXPR.chomp
            (CASE WHEN pk_fold(e.title) LIKE '%' || ? || '%'
                    OR EXISTS (SELECT 1 FROM cal_properties p WHERE p.item_id = e.id
                               AND p.key IN ('DESCRIPTION','LOCATION') AND pk_fold(p.value) LIKE '%' || ? || '%')
                  THEN 1 ELSE 0 END)
          EXPR
        end

        filters = []
        filter_binds = []
        # Date bounds are compared in the machine-local frame (the caller
        # parses a bare date to local midnight; parse_before extends it to
        # end-of-day). Correct for timed events in any zone. Caveat: all-day
        # events are stored as *floating* UTC-midnight, so in a far-*western*
        # zone (local midnight is hours ahead of UTC) an all-day event on day
        # D can fall just before a local-frame "day D" lower bound. Fine for
        # UTC/eastern zones; a fully correct fix needs per-event-type date
        # extraction (deferred — see ideas/thunderbird.md open questions).
        if after
          filters << 'e.event_start >= ?'
          filter_binds << to_prtime(after)
        end
        if before
          filters << 'e.event_start <= ?'
          filter_binds << to_prtime(before)
        end
        # Recurrence filter off the master's HAS_RECURRENCE bit (constant, no
        # bind). nil leaves it unfiltered.
        filters << "(e.flags & #{RECURRENCE_FLAG}) #{recurring ? '!= 0' : '= 0'}" unless recurring.nil?
        where = filters.empty? ? '1' : filters.join(' AND ')
        # An empty query scores every event 0 and lists the whole range; a
        # non-empty query keeps only events that matched at least one word.
        match_gate = score.empty? ? '1' : 'score > 0'

        rows = db.execute(<<~SQL, score_binds + filter_binds + [limit])
          SELECT id, title, event_start, event_end, event_start_tz, event_end_tz, flags, location, score FROM (
            SELECT e.id, e.title, e.event_start, e.event_end, e.event_start_tz, e.event_end_tz, e.flags,
                   (SELECT value FROM cal_properties p WHERE p.item_id = e.id AND p.key = 'LOCATION' LIMIT 1) AS location,
                   (#{score.empty? ? '0' : score.join(' + ')}) AS score
            FROM cal_events e
            WHERE #{where}
          )
          WHERE #{match_gate}
          ORDER BY score DESC, event_start DESC
          LIMIT ?
        SQL
        rows.map { |row| build_event(row[0..6]).merge(location: row[7], score: row[8]) }
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
