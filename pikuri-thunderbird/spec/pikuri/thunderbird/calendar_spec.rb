# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe Pikuri::Thunderbird::Calendar do
  Calendar = Pikuri::Thunderbird::Calendar

  E1 = Time.utc(2026, 5, 1, 7, 0, 0)      # timed, Helsinki
  E2 = Time.utc(2026, 6, 1, 0, 0, 0)      # all-day (flags bit 8), floating
  E3 = Time.utc(2026, 5, 15, 10, 0, 0)    # timed, UTC
  E4 = Time.utc(2026, 5, 8, 9, 0, 0)      # timed, recurring (flags bit 16)

  def make_calendar(dir, name = 'cache.sqlite')
    path = File.join(dir, name)
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE cal_events(
        cal_id TEXT, id TEXT, title TEXT,
        event_start INTEGER, event_end INTEGER,
        event_start_tz TEXT, event_end_tz TEXT,
        flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
      CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
    SQL
    ev = db.prepare('INSERT INTO cal_events VALUES (?,?,?,?,?,?,?,?,?,?)')
    ev.execute('c1', 'e1', 'Team standup', E1.to_i * 1_000_000, (E1.to_i + 1800) * 1_000_000,
               'Europe/Helsinki', 'Europe/Helsinki', 262, 'CONFIRMED', nil)
    ev.execute('c1', 'e2', 'Company Holiday', E2.to_i * 1_000_000, (E2.to_i + 86_400) * 1_000_000,
               'floating', 'floating', 8, 'CONFIRMED', nil)
    ev.execute('c1', 'e3', 'Lunch with Bob', E3.to_i * 1_000_000, (E3.to_i + 3600) * 1_000_000,
               'UTC', 'UTC', 262, 'CONFIRMED', nil)
    ev.execute('c1', 'e4', 'Weekly sync', E4.to_i * 1_000_000, (E4.to_i + 1800) * 1_000_000,
               'UTC', 'UTC', 278, 'CONFIRMED', nil) # 278 = 262 | 16 (HAS_RECURRENCE); master row
    ev.close
    db.execute("INSERT INTO cal_properties VALUES ('e1','LOCATION','Zoom room A')")
    db.execute("INSERT INTO cal_properties VALUES ('e1','DESCRIPTION','daily engineering standup')")
    db.close
    path
  end

  def with_calendar
    Dir.mktmpdir do |dir|
      cal = Calendar.new(calendar_dbs: [make_calendar(dir)], cache_dir: File.join(dir, 'cache'))
      begin
        yield cal, dir
      ensure
        cal.close
      end
    end
  end

  it 'counts cached events' do
    with_calendar { |cal| assert_equal 4, cal.event_count }
    Dir.mktmpdir do |dir|
      empty = Calendar.new(calendar_dbs: [], cache_dir: dir)
      refute empty.available?
      assert_equal 0, empty.event_count
    end
  end

  it 'searches by title, description and location' do
    with_calendar do |cal|
      assert_equal ['e1'], cal.search(query: 'standup', limit: 10).map { |h| h[:event_id] }
      assert_equal ['e1'], cal.search(query: 'engineering', limit: 10).map { |h| h[:event_id] } # DESCRIPTION
      assert_equal ['e1'], cal.search(query: 'Zoom', limit: 10).map { |h| h[:event_id] }        # LOCATION
      assert_equal ['e3'], cal.search(query: 'Bob', limit: 10).map { |h| h[:event_id] }
    end
  end

  it 'matches accent- and case-blind (folds diacritics on both sides)' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(
          cal_id TEXT, id TEXT, title TEXT,
          event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT,
          flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        INSERT INTO cal_events VALUES
          ('c1','a1','Hammer Dröp on a boat',#{E3.to_i * 1_000_000},#{(E3.to_i + 3600) * 1_000_000},
           'UTC','UTC',262,'CONFIRMED',NULL);
        INSERT INTO cal_properties VALUES ('a1','LOCATION','Café Zürich');
      SQL
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'cache'))
      begin
        # the reported bug: accented title found by an un-accented query.
        assert_equal ['a1'], cal.search(query: 'Hammer Drop', limit: 10).map { |h| h[:event_id] }
        # and the reverse: un-accented query text against an accented location.
        assert_equal ['a1'], cal.search(query: 'cafe zurich', limit: 10).map { |h| h[:event_id] }
      ensure
        cal.close
      end
    end
  end

  it 'ORs query words (recall-first, like the mail path)' do
    with_calendar do |cal|
      # "engineering" is in the description, "standup" in the title — e1 matches both.
      assert_equal ['e1'], cal.search(query: 'engineering standup', limit: 10).map { |h| h[:event_id] }
      # recall-first: a word matching nothing does NOT drop an event that
      # matched the other word (an AND would have returned nothing here —
      # that stricter behavior is exactly what made the model give up).
      assert_equal ['e1'], cal.search(query: 'standup missingword', limit: 10).map { |h| h[:event_id] }
    end
  end

  it 'ranks an event matching more query words above one matching fewer (beats recency)' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      # 'both' is the OLDER event but matches two words; 'one' is NEWER but
      # matches a single word. Score must win over recency ⇒ 'both' first.
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        INSERT INTO cal_events VALUES
          ('c1','both','Project kickoff meeting',#{E1.to_i * 1_000_000},#{(E1.to_i + 3600) * 1_000_000},
           'UTC','UTC',262,'CONFIRMED',NULL),
          ('c1','one','Weekly meeting',#{E3.to_i * 1_000_000},#{(E3.to_i + 3600) * 1_000_000},
           'UTC','UTC',262,'CONFIRMED',NULL);
      SQL
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        # 'kickoff' hits only 'both'; 'meeting' hits both events.
        assert_equal %w[both one], cal.search(query: 'kickoff meeting', limit: 10).map { |h| h[:event_id] }
      ensure
        cal.close
      end
    end
  end

  it 'decodes the all-day and recurrence flags and UTC instants' do
    with_calendar do |cal|
      all = cal.search(query: '', limit: 10)
      by_id = all.to_h { |h| [h[:event_id], h] }
      assert by_id['e2'][:all_day], 'flags bit 8 → all-day'
      refute by_id['e1'][:all_day]
      assert by_id['e4'][:recurring], 'flags bit 16 → recurring'
      refute by_id['e1'][:recurring]
      assert_equal E1, by_id['e1'][:start]
      assert_equal 'Europe/Helsinki', by_id['e1'][:start_tz]
      assert_equal 'floating', by_id['e2'][:start_tz]
    end
  end

  it 'filters by recurrence (recurring-only, single-only, or both)' do
    with_calendar do |cal|
      recurring = cal.search(query: '', limit: 10, recurring: true).map { |h| h[:event_id] }
      assert_equal ['e4'], recurring
      single = cal.search(query: '', limit: 10, recurring: false).map { |h| h[:event_id] }.sort
      assert_equal %w[e1 e2 e3], single
      both = cal.search(query: '', limit: 10, recurring: nil).map { |h| h[:event_id] }.sort
      assert_equal %w[e1 e2 e3 e4], both
    end
  end

  it 'folds a recurring series (master + occurrence rows) into one hit' do
    # The reported bug: a recurring Google event is stored as a master row plus
    # one row per modified occurrence — all sharing the UID, each with its own
    # recurrence_id, and (crucially) NONE of the occurrence rows carry the
    # master's HAS_RECURRENCE flag. The old per-row SQL recurrence filter then
    # leaked every occurrence under recurrence:single and flooded plain search.
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
      SQL
      uid = 'series@google.com'
      master = Time.utc(2026, 2, 6, 11, 30, 0)
      ev = db.prepare('INSERT INTO cal_events VALUES (?,?,?,?,?,?,?,?,?,?)')
      # Master (recurrence_id NULL, flag 16); then 5 weekly occurrence rows
      # (recurrence_id set, flag 262 = no HAS_RECURRENCE bit).
      ev.execute('c1', uid, 'Weekly standup', master.to_i * 1_000_000, (master.to_i + 1800) * 1_000_000,
                 'UTC', 'UTC', 278, 'CONFIRMED', nil)
      5.times do |i|
        occ = master + ((i + 1) * 7 * 86_400)
        ev.execute('c1', uid, 'Weekly standup', occ.to_i * 1_000_000, (occ.to_i + 1800) * 1_000_000,
                   'UTC', 'UTC', 262, 'CONFIRMED', occ.to_i * 1_000_000)
      end
      # A genuinely single event, for the recurrence filter checks.
      ev.execute('c1', 'solo', 'Standup retro', Time.utc(2026, 3, 1).to_i * 1_000_000,
                 (Time.utc(2026, 3, 1).to_i + 1800) * 1_000_000, 'UTC', 'UTC', 262, 'CONFIRMED', nil)
      ev.close
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        # Plain search: the series collapses to ONE hit (not six), marked recurring.
        hits = cal.search(query: 'standup', limit: 50)
        assert_equal [uid, 'solo'], hits.map { |h| h[:event_id] }.sort
        assert hits.find { |h| h[:event_id] == uid }[:recurring], 'folded series is recurring'
        # recurrence:single must NOT leak the occurrence rows — only the real single.
        assert_equal ['solo'], cal.search(query: 'standup', limit: 50, recurring: false).map { |h| h[:event_id] }
        # recurrence:recurring surfaces the series exactly once.
        assert_equal [uid], cal.search(query: 'standup', limit: 50, recurring: true).map { |h| h[:event_id] }
      ensure
        cal.close
      end
    end
  end

  it 'filters by date and orders newest first' do
    with_calendar do |cal|
      ids = cal.search(query: '', limit: 10, after: Time.utc(2026, 5, 20)).map { |h| h[:event_id] }
      assert_equal ['e2'], ids # only the June all-day event starts after May 20
    end
  end

  it 'returns same-day events given an inclusive whole-day window' do
    with_calendar do |cal|
      # "tomorrow's meetings" shape: after == before == the day. The
      # backend must see a whole-day window (via DateHelpers.parse_before's
      # end-of-day), so E3 at 10:00 that day is included, not excluded.
      ids = cal.search(query: '', limit: 10,
                       after: Time.utc(2026, 5, 15, 0, 0, 0),
                       before: Time.utc(2026, 5, 15, 23, 59, 59)).map { |h| h[:event_id] }
      assert_equal ['e3'], ids
    end
  end

  it 'reads full event detail' do
    with_calendar do |cal|
      rec = cal.read(event_id: 'e1')
      assert_equal 'Team standup', rec[:title]
      assert_equal 'Zoom room A', rec[:location]
      assert_equal 'daily engineering standup', rec[:description]
      assert_equal 'CONFIRMED', rec[:status]
      assert_nil cal.read(event_id: 'nope')
    end
  end
end
