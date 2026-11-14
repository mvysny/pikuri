# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe 'pikuri-thunderbird tools' do
  def make_gloda(dir)
    path = File.join(dir, 'global-messages-db.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER, jsonAttributes TEXT);
      CREATE TABLE folderLocations(id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER);
      CREATE TABLE attributeDefinitions(id INTEGER PRIMARY KEY, attributeType INTEGER, extensionName TEXT, name TEXT, parameter BLOB);
      INSERT INTO attributeDefinitions VALUES (51,0,'built-in','attachmentInfos',NULL);
      INSERT INTO folderLocations VALUES (1,'imap://x/INBOX',0,'INBOX',50);
      INSERT INTO messagesText_content VALUES (1,'Please find the invoice attached.','Invoice 2024','invoice.pdf','Alice <a@acme.com>','me@example.com');
      INSERT INTO messages VALUES (1,1,#{Time.utc(2026, 3, 1).to_i * 1_000_000},'<a@x>',0,
        '{"51":[["invoice.pdf","application/pdf",84000,"1.2",null,false]]}');
    SQL
    db.close
    path
  end

  def make_calendar(dir)
    path = File.join(dir, 'cache.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER, event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
      CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
      CREATE TABLE cal_attendees(item_id TEXT, recurrence_id INTEGER, recurrence_id_tz TEXT, cal_id TEXT, icalString TEXT);
      INSERT INTO cal_events VALUES ('c','e1','Team standup',#{Time.utc(2026, 5, 1, 7, 0).to_i * 1_000_000},#{(Time.utc(2026, 5, 1, 7, 0).to_i + 1800) * 1_000_000},'Europe/Helsinki','Europe/Helsinki',262,'CONFIRMED',NULL);
      INSERT INTO cal_properties VALUES ('e1','LOCATION','Zoom');
      INSERT INTO cal_properties VALUES ('e1','DESCRIPTION','daily sync');
      INSERT INTO cal_attendees VALUES ('e1',NULL,NULL,'c','ATTENDEE;CN=Bob;PARTSTAT=ACCEPTED:mailto:bob@example.com');
    SQL
    db.close
    path
  end

  def gloda(dir) = Pikuri::Thunderbird::Gloda.new(gloda_path: make_gloda(dir), cache_dir: File.join(dir, 'gc'))
  def mail(g) = Pikuri::Thunderbird::Gloda::Mail.new(gloda: g)
  def calendar(dir, dbs = nil)
    Pikuri::Thunderbird::Calendar.new(calendar_dbs: dbs || [make_calendar(dir)], cache_dir: File.join(dir, 'cc'))
  end

  describe 'thunderbird_mail_search' do
    it 'renders ranked hits with a usable id, and Errors on a bad date' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        tool = Pikuri::Thunderbird::MailSearch.new(backend: mail(g))
        out = tool.run('query' => 'invoice').to_s
        assert_match(/1 match/, out)
        assert_match(/id: <a@x>/, out)
        assert_match(/Invoice 2024/, out)

        assert_match(/No matching mail/, tool.run('query' => 'zzzznope').to_s)
        assert_match(/Error: bad date/, tool.run('query' => 'invoice', 'after' => 'not-a-date').to_s)
        g.close
      end
    end

    it 'searches by filters alone with no query (newest-first listing)' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        tool = Pikuri::Thunderbird::MailSearch.new(backend: mail(g))
        out = tool.run('from' => 'acme.com').to_s
        assert_match(/1 match/, out)
        assert_match(/Invoice 2024/, out)
        assert_match(/No mail matched those filters/, tool.run('from' => 'nobody@nowhere').to_s)
        g.close
      end
    end

    it 'refuses a match-everything call with no query and no filter' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        tool = Pikuri::Thunderbird::MailSearch.new(backend: mail(g))
        assert_match(/Error: give at least one/, tool.run({}).to_s)
        assert_match(/Error: give at least one/, tool.run('query' => '  ', 'from' => '').to_s)
        g.close
      end
    end

    it 'flags a full page as having more, and affirms completeness otherwise' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'global-messages-db.sqlite')
        db = SQLite3::Database.new(path)
        db.execute_batch(<<~SQL)
          CREATE TABLE messagesText_content(docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients);
          CREATE TABLE messages(id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER);
          CREATE TABLE folderLocations(id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER);
          INSERT INTO folderLocations VALUES (1,'imap://x/INBOX',0,'INBOX',50);
          INSERT INTO messagesText_content VALUES (1,'invoice one','Invoice 1','','a@x','me@x');
          INSERT INTO messages VALUES (1,1,#{Time.utc(2026, 3, 1).to_i * 1_000_000},'<m1@x>',0);
          INSERT INTO messagesText_content VALUES (2,'invoice two','Invoice 2','','b@x','me@x');
          INSERT INTO messages VALUES (2,1,#{Time.utc(2026, 3, 2).to_i * 1_000_000},'<m2@x>',0);
        SQL
        db.close
        g = Pikuri::Thunderbird::Gloda.new(gloda_path: path, cache_dir: File.join(dir, 'gc'))
        tool = Pikuri::Thunderbird::MailSearch.new(backend: mail(g))

        capped = tool.run('query' => 'invoice', 'limit' => 1).to_s
        assert_match(/more exist/, capped)
        assert_match(/raise limit/, capped)

        assert_match(/all shown/, tool.run('query' => 'invoice', 'limit' => 10).to_s)
        g.close
      end
    end
  end

  describe 'the display line' do
    it 'counts the hits and never carries a subject line' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        tool = Pikuri::Thunderbird::MailSearch.new(backend: mail(g))

        result = tool.run('query' => 'invoice')

        assert_equal 'Found 1 message', result.summary
        refute_includes result.summary, 'Invoice 2024'
        # Every parameter is optional, so the generic no-required default applies.
        assert_equal 'query=invoice', tool.describe_call('query' => 'invoice')
        assert_equal 'ThunderbirdMailSearch', tool.display_name
        assert_equal 'Found 0 messages', tool.run('query' => 'zzzznope').summary
        g.close
      end
    end

    it 'reports a read message by size, since a subject is whatever the sender wrote' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        result = Pikuri::Thunderbird::MailRead.new(backend: mail(g)).run('message_id' => '<a@x>')

        assert_match(/\ARead \d+(\.\d+)? (B|kB|MB)\z/, result.summary)
        g.close
      end
    end
  end

  describe 'thunderbird_mail_read' do
    it 'returns the full message and Errors on unknown id' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        tool = Pikuri::Thunderbird::MailRead.new(backend: mail(g))
        out = tool.run('message_id' => '<a@x>').to_s
        assert_match(/Subject: Invoice 2024/, out)
        assert_match(/invoice attached/, out)
        assert_match(%r{Attachments:\n  1\. invoice\.pdf \(application/pdf, [\d.]+ kB\)}, out)
        assert_match(/Error: no message/, tool.run('message_id' => '<nope@x>').to_s)
        g.close
      end
    end

    it "says a body may be cut off once it reaches Gloda's 20 KB per part, and only then" do
      Dir.mktmpdir do |dir|
        path = make_gloda(dir)
        db = SQLite3::Database.new(path)
        db.execute("INSERT INTO messagesText_content VALUES (2,?,'Rules','','a@x','me@x')", ['x' * (20 * 1024)])
        db.execute("INSERT INTO messages VALUES (2,1,0,'<rules@x>',0,'{}')")
        db.close
        g = Pikuri::Thunderbird::Gloda.new(gloda_path: path, cache_dir: File.join(dir, 'gc'))
        tool = Pikuri::Thunderbird::MailRead.new(backend: mail(g))

        assert tool.run('message_id' => '<rules@x>').to_s.end_with?("x\n\n#{Pikuri::Thunderbird::MailRead::CUT_NOTE}")
        refute_includes tool.run('message_id' => '<a@x>').to_s, 'may continue past this point'
        g.close
      end
    end

    it 'truncates a long body on a character boundary, so the result stays valid UTF-8' do
      Dir.mktmpdir do |dir|
        path = make_gloda(dir)
        db = SQLite3::Database.new(path)
        # 'a' first puts every 2-byte 'ä' on an odd offset: a byte cut at 40 KB tears one.
        db.execute("INSERT INTO messagesText_content VALUES (2,?,'Pitkä','','a@x','me@x')", ["a#{'ä' * 30_000}"])
        db.execute("INSERT INTO messages VALUES (2,1,0,'<long@x>',0,'{}')")
        db.close
        g = Pikuri::Thunderbird::Gloda.new(gloda_path: path, cache_dir: File.join(dir, 'gc'))

        out = Pikuri::Thunderbird::MailRead.new(backend: mail(g)).run('message_id' => '<long@x>').to_s

        assert out.valid_encoding?
        assert_includes out, "ää\n\n… [truncated; message longer than 40 KB] …"
        g.close
      end
    end
  end

  describe 'thunderbird_calendar_search' do
    it 'lists matching events' do
      Dir.mktmpdir do |dir|
        c = calendar(dir)
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)
        out = tool.run('query' => 'standup').to_s
        assert_match(/Team standup/, out)
        assert_match(/id: e1/, out)
        assert_match(/where: Zoom/, out)
        c.close
      end
    end

    it 'lists events by date range alone with no query' do
      Dir.mktmpdir do |dir|
        c = calendar(dir)
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)
        out = tool.run('after' => '2026-05-01', 'before' => '2026-05-01').to_s
        assert_match(/Team standup/, out)
        assert_match(/No events found in that date range/,
                     tool.run('after' => '2030-01-01', 'before' => '2030-01-01').to_s)
        c.close
      end
    end

    it 'refuses a match-everything call with no query and no date range' do
      Dir.mktmpdir do |dir|
        c = calendar(dir)
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)
        assert_match(/Error: give a query and\/or a date range/, tool.run({}).to_s)
        c.close
      end
    end

    it 'flags a full page as having more, and affirms completeness otherwise' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'cache.sqlite')
        db = SQLite3::Database.new(path)
        s1 = Time.utc(2026, 5, 1, 7, 0).to_i * 1_000_000
        s2 = Time.utc(2026, 5, 2, 7, 0).to_i * 1_000_000
        db.execute_batch(<<~SQL)
          CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER, event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT, recurrence_id INTEGER);
          CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
          CREATE TABLE cal_attendees(item_id TEXT, recurrence_id INTEGER, recurrence_id_tz TEXT, cal_id TEXT, icalString TEXT);
          INSERT INTO cal_events VALUES ('c','e1','Team standup',#{s1},#{s1 + 1_800_000_000},'UTC','UTC',0,'CONFIRMED',NULL);
          INSERT INTO cal_events VALUES ('c','e2','Daily standup',#{s2},#{s2 + 1_800_000_000},'UTC','UTC',0,'CONFIRMED',NULL);
        SQL
        db.close
        c = Pikuri::Thunderbird::Calendar.new(calendar_dbs: [path], cache_dir: File.join(dir, 'cc'))
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)

        capped = tool.run('query' => 'standup', 'limit' => 1).to_s
        assert_match(/more exist/, capped)
        assert_match(/raise limit/, capped)

        assert_match(/all shown/, tool.run('query' => 'standup', 'limit' => 10).to_s)
        c.close
      end
    end

    it 'guides the user to enable Offline Support when nothing is cached' do
      Dir.mktmpdir do |dir|
        c = calendar(dir, []) # no calendar stores on disk
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)
        assert_match(/Offline Support/, tool.run('query' => 'anything').to_s)
        c.close
      end
    end
  end

  describe 'thunderbird_calendar_read' do
    it 'returns event detail and Errors on unknown id' do
      Dir.mktmpdir do |dir|
        c = calendar(dir)
        tool = Pikuri::Thunderbird::CalendarRead.new(backend: c)
        out = tool.run('event_id' => 'e1').to_s
        assert_match(/Title: Team standup/, out)
        assert_match(/Where: Zoom/, out)
        assert_match(/daily sync/, out)
        assert_match(/Error: no event/, tool.run('event_id' => 'nope').to_s)
        c.close
      end
    end
  end
end
