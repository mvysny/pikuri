# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe Pikuri::Thunderbird::Calendar do
  Calendar = Pikuri::Thunderbird::Calendar

  E1 = Time.utc(2026, 5, 1, 7, 0, 0)      # timed, Helsinki
  E2 = Time.utc(2026, 6, 1, 0, 0, 0)      # all-day (flags bit 8), floating
  E3 = Time.utc(2026, 5, 15, 10, 0, 0)    # timed, UTC

  def make_calendar(dir, name = 'cache.sqlite')
    path = File.join(dir, name)
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE cal_events(
        cal_id TEXT, id TEXT, title TEXT,
        event_start INTEGER, event_end INTEGER,
        event_start_tz TEXT, event_end_tz TEXT,
        flags INTEGER, ical_status TEXT);
      CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
    SQL
    ev = db.prepare('INSERT INTO cal_events VALUES (?,?,?,?,?,?,?,?,?)')
    ev.execute('c1', 'e1', 'Team standup', E1.to_i * 1_000_000, (E1.to_i + 1800) * 1_000_000,
               'Europe/Helsinki', 'Europe/Helsinki', 262, 'CONFIRMED')
    ev.execute('c1', 'e2', 'Company Holiday', E2.to_i * 1_000_000, (E2.to_i + 86_400) * 1_000_000,
               'floating', 'floating', 8, 'CONFIRMED')
    ev.execute('c1', 'e3', 'Lunch with Bob', E3.to_i * 1_000_000, (E3.to_i + 3600) * 1_000_000,
               'UTC', 'UTC', 262, 'CONFIRMED')
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
    with_calendar { |cal| assert_equal 3, cal.event_count }
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

  it 'ANDs query words across title/description/location' do
    with_calendar do |cal|
      # "engineering" is in the description, "standup" in the title — both present ⇒ match.
      assert_equal ['e1'], cal.search(query: 'engineering standup', limit: 10).map { |h| h[:event_id] }
      # a word that appears nowhere in the event drops it.
      assert_empty cal.search(query: 'standup missingword', limit: 10)
    end
  end

  it 'decodes the all-day flag and UTC instants' do
    with_calendar do |cal|
      all = cal.search(query: '', limit: 10)
      by_id = all.to_h { |h| [h[:event_id], h] }
      assert by_id['e2'][:all_day], 'flags bit 8 → all-day'
      refute by_id['e1'][:all_day]
      assert_equal E1, by_id['e1'][:start]
      assert_equal 'Europe/Helsinki', by_id['e1'][:start_tz]
      assert_equal 'floating', by_id['e2'][:start_tz]
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
      # backend must see a whole-day window (via Format.parse_before's
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
