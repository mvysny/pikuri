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
    # Like {Gloda}, every query runs against {Snapshot} copies (opened
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

      # @param calendar_dbs [Array<String>] existing calendar store paths
      #   (see {Profile#calendar_dbs}); may be empty.
      # @param cache_dir [String] private 0700 dir for the snapshot copies.
      # @return [Calendar]
      def initialize(calendar_dbs:, cache_dir:)
        @sources = calendar_dbs
        @snapshots = @sources.to_h do |src|
          [src, Snapshot.new(source: src, dir: File.join(cache_dir, File.basename(src, '.sqlite')))]
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

      # Search events by title / description / location, newest first.
      #
      # @param query [String] substring over title + DESCRIPTION + LOCATION.
      # @param limit [Integer] max events.
      # @param after [Time, nil] only events starting on/after this instant.
      # @param before [Time, nil] only events starting on/before this instant.
      # @return [Array<Hash>] +[{event_id:, title:, start: Time, end: Time,
      #   all_day: Boolean, start_tz:, end_tz:, location:}, …]+
      def search(query:, limit:, after: nil, before: nil)
        ensure_fresh
        hits = @conns.values.flat_map { |db| search_db(db, query:, after:, before:, limit:) }
        hits.sort_by { |h| -(h[:start]&.to_i || 0) }.first(limit)
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
          live = Snapshot.change_counter(src)
          next if @conns[src] && @generations[src] && live == @generations[src]

          @conns[src]&.close
          snap.refresh
          @conns[src] = SQLite3::Database.new("file:#{snap.path}?immutable=1",
                                              flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
          @generations[src] = snap.generation
        end
      end

      # @return [Array<Hash>]
      def search_db(db, query:, after:, before:, limit:)
        clauses = []
        binds = []
        # Multi-word rule: AND across words — every word must appear in the
        # event's title, description, or location (possibly different
        # fields). Precision-first, since the calendar path has no ranking
        # to separate strong from weak matches (contrast the mail path, which
        # ORs words and lets bm25 rank).
        query.to_s.scan(/[[:alnum:]]+/).each do |word|
          clauses << <<~COND.chomp
            (e.title LIKE '%' || ? || '%'
             OR EXISTS (SELECT 1 FROM cal_properties p WHERE p.item_id = e.id
                        AND p.key IN ('DESCRIPTION','LOCATION') AND p.value LIKE '%' || ? || '%'))
          COND
          binds << word << word
        end
        if after
          clauses << 'e.event_start >= ?'
          binds << to_prtime(after)
        end
        if before
          clauses << 'e.event_start <= ?'
          binds << to_prtime(before)
        end
        where = clauses.empty? ? '1' : clauses.join(' AND ')
        rows = db.execute(<<~SQL, binds + [limit])
          SELECT e.id, e.title, e.event_start, e.event_end, e.event_start_tz, e.event_end_tz, e.flags,
                 (SELECT value FROM cal_properties p WHERE p.item_id = e.id AND p.key = 'LOCATION' LIMIT 1)
          FROM cal_events e
          WHERE #{where}
          ORDER BY e.event_start DESC
          LIMIT ?
        SQL
        rows.map { |row| build_event(row[0..6]).merge(location: row[7]) }
      end

      # @param row [Array] +[id, title, start_us, end_us, start_tz, end_tz, flags]+
      # @return [Hash]
      def build_event(row)
        id, title, start_us, end_us, start_tz, end_tz, flags = row
        {
          event_id: id, title: title,
          start: to_time(start_us), end: to_time(end_us),
          all_day: (flags.to_i & ALL_DAY_FLAG) != 0,
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
