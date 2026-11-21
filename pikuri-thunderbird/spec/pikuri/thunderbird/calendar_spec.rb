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
      CREATE TABLE cal_attendees(item_id TEXT, recurrence_id INTEGER, recurrence_id_tz TEXT, cal_id TEXT, icalString TEXT);
      CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
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
    # e1 attendees exercise the parser: an organizer (CN + EMAIL param), a
    # quoted CN with an interior comma, an OPT-PARTICIPANT, and a plain row
    # whose address lives only in the mailto: value (no CN/EMAIL param).
    att = db.prepare('INSERT INTO cal_attendees VALUES (?,NULL,NULL,?,?)')
    att.execute('e1', 'c1', 'ORGANIZER;CN=Ann Boss;EMAIL=ann@example.com:mailto:ann@example.com')
    att.execute('e1', 'c1', 'ATTENDEE;CN="Vysny, Martin";PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT:mailto:martin@example.com')
    att.execute('e1', 'c1', 'ATTENDEE;PARTSTAT=TENTATIVE;ROLE=OPT-PARTICIPANT;CUTYPE=INDIVIDUAL:mailto:bob@example.com')
    att.close
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

  # P_shared_locked: one agent's on_close must not strand a co-owner, so #close
  # only drops the connections and the next query reopens them.
  it 'reopens after a co-owner closes, rather than failing' do
    with_calendar do |cal|
      assert_equal 4, cal.event_count
      cal.close
      assert_equal 4, cal.event_count
      assert_equal 'Team standup', cal.read(event_id: 'e1')[:title]
    end
  end

  it 'counts cached events' do
    with_calendar { |cal| assert_equal 4, cal.event_count }
    Dir.mktmpdir do |dir|
      empty = Calendar.new(calendar_dbs: [], cache_dir: dir)
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
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
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
      # Fallback (OR) ranking: neither title has "kickoff meeting" *adjacent*,
      # so the phrase gate finds nothing and both events fall back to OR recall.
      # 'both' is the OLDER event but matches two words; 'one' is NEWER but
      # matches a single word. Score must win over recency ⇒ 'both' first.
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
        INSERT INTO cal_events VALUES
          ('c1','both','Kickoff for the big meeting',#{E1.to_i * 1_000_000},#{(E1.to_i + 3600) * 1_000_000},
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

  it 'prefers an adjacent-phrase match and suppresses single-common-word noise' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      # The reported bug: query "hang around" flooded with events whose only
      # link is the common word "around" in a description. 'phrase' has the
      # words adjacent (in the title); 'noise' matches only "around" (in its
      # description). Once a phrase hit exists, the noise must be dropped.
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
        INSERT INTO cal_events VALUES
          ('c1','phrase','Hammer Dröp hang around',#{E1.to_i * 1_000_000},#{(E1.to_i + 3600) * 1_000_000},
           'UTC','UTC',262,'CONFIRMED',NULL),
          ('c1','noise','Quarterly Product Release',#{E3.to_i * 1_000_000},#{(E3.to_i + 3600) * 1_000_000},
           'UTC','UTC',262,'CONFIRMED',NULL);
        INSERT INTO cal_properties VALUES ('noise','DESCRIPTION','This time around we review the results');
      SQL
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        # phrase-first: only the adjacent match survives.
        assert_equal ['phrase'], cal.search(query: 'hang around', limit: 10).map { |h| h[:event_id] }
        # a scattered query (no adjacency anywhere) falls back to OR recall,
        # returning both — 'noise' (both words) ranked above 'phrase' (one word).
        assert_equal %w[noise phrase], cal.search(query: 'around review', limit: 10).map { |h| h[:event_id] }
      ensure
        cal.close
      end
    end
  end

  it 'folds a recurring series split across UID_R<datetime> masters into one hit' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      # Google stores a "this-and-following" edit as a new master whose UID
      # carries an _R<ical-datetime> suffix. All are one logical series and
      # must fold to a single hit — not one per split (the 22-dupe bug).
      base = 'abc123@google.com'
      split = 'abc123_R20200227T113000@google.com'
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
        INSERT INTO cal_events VALUES
          ('c1','#{base}','Weekly hangout',#{E1.to_i * 1_000_000},#{(E1.to_i + 3600) * 1_000_000},
           'UTC','UTC',278,'CONFIRMED',NULL),
          ('c1','#{split}','Weekly hangout',#{E3.to_i * 1_000_000},#{(E3.to_i + 3600) * 1_000_000},
           'UTC','UTC',278,'CONFIRMED',NULL);
      SQL
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        hits = cal.search(query: 'hangout', limit: 10)
        assert_equal 1, hits.size, 'the base + _R split fold into one series'
        assert hits.first[:recurring]
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
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
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

  it 'dates an all-day event by its own day, even west of UTC' do
    # All-day events are stored floating (the date's midnight labelled UTC),
    # while a bare-date bound is local midnight: at UTC-11 that is 11:00 UTC,
    # so comparing the two instants put every all-day event in the day before.
    old_tz = ENV['TZ']
    ENV['TZ'] = 'Pacific/Pago_Pago'
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
      SQL
      us = ->(t) { t.to_i * 1_000_000 }
      ev = db.prepare('INSERT INTO cal_events VALUES (?,?,?,?,?,?,?,?,?,?)')
      ev.execute('c1', 'holiday', 'Company Holiday', us[Time.utc(2026, 6, 1)], us[Time.utc(2026, 6, 2)],
                 'floating', 'floating', 8, 'CONFIRMED', nil)
      # Every Friday since Friday 2 January, all-day (8 | 16 = 24).
      ev.execute('c1', 'rent', 'Rent due', us[Time.utc(2026, 1, 2)], us[Time.utc(2026, 1, 3)],
                 'floating', 'floating', 24, 'CONFIRMED', nil)
      # 10:00 on 1 June in Pago Pago: a timed event keeps the local frame.
      ev.execute('c1', 'call', 'Call', us[Time.utc(2026, 6, 1, 21)], us[Time.utc(2026, 6, 1, 22)],
                 'Pacific/Pago_Pago', 'Pacific/Pago_Pago', 0, 'CONFIRMED', nil)
      ev.close
      db.execute("INSERT INTO cal_recurrence VALUES ('rent','c1','RRULE:FREQ=WEEKLY')")
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        day = ->(y, m, d) { { after: Time.local(y, m, d), before: Time.local(y, m, d, 23, 59, 59) } }
        ids = ->(range) { cal.search(query: '', limit: 50, **range).map { |h| h[:event_id] }.sort }
        assert_equal %w[call holiday], ids[day[2026, 6, 1]]
        assert_equal [], ids[day[2026, 5, 31]]
        assert_equal ['rent'], ids[day[2026, 6, 5]] # a Friday
        assert_equal [], ids[day[2026, 6, 4]]
        # Unranged, the series is dated at its current occurrence: on Friday
        # morning that is today's, not next week's.
        rent = cal.search(query: 'rent', limit: 5, now: Time.local(2026, 6, 5, 8)).first
        assert_equal Time.utc(2026, 6, 5), rent[:start]
      ensure
        cal.close
      end
    end
  ensure
    ENV['TZ'] = old_tz
  end

  it 'lists each occurrence of a recurring series in a date range, earliest first' do
    # A series is one master row dated at its first occurrence, so before
    # expansion a week's listing never saw a meeting that started in January.
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
      SQL
      us = ->(t) { t.to_i * 1_000_000 }
      ev = db.prepare('INSERT INTO cal_events VALUES (?,?,?,?,?,?,?,?,?,?)')
      # 09:00 Helsinki Mon/Wed/Fri since January; Wednesday the 18th moved to 11:00.
      ev.execute('c1', 'standup', 'Standup', us[Time.utc(2026, 1, 5, 7)], us[Time.utc(2026, 1, 5, 7, 15)],
                 'Europe/Helsinki', 'Europe/Helsinki', 278, 'CONFIRMED', nil)
      ev.execute('c1', 'standup', 'Standup', us[Time.utc(2026, 11, 18, 9)], us[Time.utc(2026, 11, 18, 9, 15)],
                 'Europe/Helsinki', 'Europe/Helsinki', 262, 'CONFIRMED', us[Time.utc(2026, 11, 18, 7)])
      ev.execute('c1', 'solo', 'Planning', us[Time.utc(2026, 11, 19, 10)], us[Time.utc(2026, 11, 19, 11)],
                 'UTC', 'UTC', 262, 'CONFIRMED', nil)
      # Hourly rules don't expand: the stored row stands in when it is in range.
      ev.execute('c1', 'pinger', 'Pinger', us[Time.utc(2026, 11, 17, 12)], us[Time.utc(2026, 11, 17, 13)],
                 'UTC', 'UTC', 278, 'CONFIRMED', nil)
      ev.execute('c1', 'old-pinger', 'Old pinger', us[Time.utc(2025, 1, 1)], us[Time.utc(2025, 1, 1, 1)],
                 'UTC', 'UTC', 278, 'CONFIRMED', nil)
      ev.close
      db.execute("INSERT INTO cal_recurrence VALUES ('standup','c1','RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR')")
      db.execute("INSERT INTO cal_recurrence VALUES ('pinger','c1','RRULE:FREQ=HOURLY')")
      db.execute("INSERT INTO cal_recurrence VALUES ('old-pinger','c1','RRULE:FREQ=HOURLY')")
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        week = { after: Time.utc(2026, 11, 15, 22), before: Time.utc(2026, 11, 20, 21, 59, 59) }
        hits = cal.search(query: '', limit: 50, **week)
        assert_equal [['standup', Time.utc(2026, 11, 16, 7)], ['pinger', Time.utc(2026, 11, 17, 12)],
                      ['standup', Time.utc(2026, 11, 18, 9)], ['solo', Time.utc(2026, 11, 19, 10)],
                      ['standup', Time.utc(2026, 11, 20, 7)]],
                     hits.map { |h| [h[:event_id], h[:start]] }
        assert_equal Time.utc(2026, 11, 16, 7, 15), hits.first[:end]
        assert_equal ['solo'], cal.search(query: '', limit: 50, recurring: false, **week).map { |h| h[:event_id] }
        # Without a range the series is still one hit.
        assert_equal ['standup'], cal.search(query: 'standup', limit: 50).map { |h| h[:event_id] }
      ensure
        cal.close
      end
    end
  end

  it "dates a recurring series at its current occurrence, not its first" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
        CREATE TABLE cal_attendees(item_id TEXT, recurrence_id INTEGER, recurrence_id_tz TEXT, cal_id TEXT, icalString TEXT);
      SQL
      us = ->(t) { t.to_i * 1_000_000 }
      ev = db.prepare('INSERT INTO cal_events VALUES (?,?,?,?,?,?,?,?,?,?)')
      # Mondays 09:00 UTC since January; Monday the 23rd moved to Tuesday 10:00.
      ev.execute('c1', 'weekly', 'Weekly review', us[Time.utc(2026, 1, 5, 9)], us[Time.utc(2026, 1, 5, 10)],
                 'UTC', 'UTC', 278, 'CONFIRMED', nil)
      ev.execute('c1', 'weekly', 'Weekly review', us[Time.utc(2026, 11, 24, 10)], us[Time.utc(2026, 11, 24, 11)],
                 'UTC', 'UTC', 262, 'CONFIRMED', us[Time.utc(2026, 11, 23, 9)])
      # Ended in May: its last meeting, not its first.
      ev.execute('c1', 'ended', 'Spring course', us[Time.utc(2026, 1, 5, 9)], us[Time.utc(2026, 1, 5, 10)],
                 'UTC', 'UTC', 278, 'CONFIRMED', nil)
      ev.close
      db.execute("INSERT INTO cal_recurrence VALUES ('weekly','c1','RRULE:FREQ=WEEKLY;BYDAY=MO')")
      db.execute("INSERT INTO cal_recurrence VALUES ('ended','c1','RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260601T000000Z')")
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        now = Time.utc(2026, 11, 18, 12) # a Wednesday
        hits = cal.search(query: 'weekly course', limit: 10, now:).to_h { |h| [h[:event_id], h] }
        assert_equal Time.utc(2026, 11, 24, 10), hits['weekly'][:start], 'the moved Monday is the next one'
        assert hits['weekly'][:recurring]
        assert_equal Time.utc(2026, 5, 25, 9), hits['ended'][:start]
        assert_equal Time.utc(2026, 5, 25, 10), hits['ended'][:end]
        read = cal.read(event_id: 'weekly', now:)
        assert_equal [Time.utc(2026, 11, 24, 10), Time.utc(2026, 11, 24, 11)], [read[:start], read[:end]]
        assert read[:recurring]
        assert_equal Time.utc(2026, 11, 30, 9), cal.read(event_id: 'weekly', now: Time.utc(2026, 11, 25, 12))[:start]
        assert_includes Pikuri::Thunderbird::CalendarSearch.run_search(backend: cal, query: 'weekly', after: nil,
                                                                       before: nil, limit: 5).content, 'repeats: yes'
        assert_includes Pikuri::Thunderbird::CalendarRead.run_read(backend: cal, event_id: 'weekly').content,
                        'Repeats: yes'
      ensure
        cal.close
      end
    end
  end

  it 'filters by date' do
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

  it 'reads attendees as typed IcalLine::Attendee values' do
    with_calendar do |cal|
      people = cal.read(event_id: 'e1')[:attendees]
      # organizer sorts first.
      org = people.first
      assert org.organizer?
      assert_equal 'Ann Boss', org.name
      assert_equal 'ann@example.com', org.email
      # quoted CN keeps its interior comma; the mailto: value gives the email.
      martin = people.find { |p| p.email == 'martin@example.com' }
      assert_equal 'Vysny, Martin', martin.name
      assert_equal 'ACCEPTED', martin.status
      refute martin.organizer?
      # no CN/EMAIL param ⇒ name falls back to the mailto: address.
      bob = people.find { |p| p.email == 'bob@example.com' }
      assert_equal 'bob@example.com', bob.name
      assert bob.optional?
    end
  end

  it 'renders the organizer + attendees block with RSVP words' do
    with_calendar do |cal|
      out = Pikuri::Thunderbird::CalendarRead.run_read(backend: cal, event_id: 'e1').to_s
      assert_includes out, 'Organizer: Ann Boss <ann@example.com>'
      assert_includes out, 'Attendees (2):'
      assert_includes out, '- Vysny, Martin <martin@example.com> — accepted'
      # OPT-PARTICIPANT marked; missing PARTSTAT would read as "no reply".
      assert_includes out, '- bob@example.com — tentative (optional)'
    end
  end

  it 'truncates a large attendee list to a per-status tally' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cache.sqlite')
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER,
          event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
        CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
        CREATE TABLE cal_attendees(item_id TEXT, recurrence_id INTEGER, recurrence_id_tz TEXT, cal_id TEXT, icalString TEXT);
        CREATE TABLE cal_recurrence(item_id TEXT, cal_id TEXT, icalString TEXT);
        INSERT INTO cal_events VALUES
          ('c1','big','All Hands',#{E1.to_i * 1_000_000},#{(E1.to_i + 3600) * 1_000_000},'UTC','UTC',262,'CONFIRMED',NULL);
      SQL
      ins = db.prepare('INSERT INTO cal_attendees VALUES (?,NULL,NULL,?,?)')
      50.times { |i| ins.execute('big', 'c1', "ATTENDEE;PARTSTAT=ACCEPTED:mailto:u#{i}@example.com") }
      ins.close
      db.close
      cal = Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'c'))
      begin
        out = Pikuri::Thunderbird::CalendarRead.run_read(backend: cal, event_id: 'big').to_s
        assert_includes out, 'Attendees (50):'
        assert_equal 40, out.lines.count { |l| l.start_with?('  - ') }
        assert_includes out, '… and 10 more (50 accepted)'
      ensure
        cal.close
      end
    end
  end
end
