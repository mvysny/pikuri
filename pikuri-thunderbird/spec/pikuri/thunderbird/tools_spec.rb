# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe 'pikuri-thunderbird tools' do
  def make_gloda(dir)
    path = File.join(dir, 'global-messages-db.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER);
      CREATE TABLE folderLocations(id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER);
      INSERT INTO folderLocations VALUES (1,'imap://x/INBOX',0,'INBOX',50);
      INSERT INTO messagesText_content VALUES (1,'Please find the invoice attached.','Invoice 2024','invoice.pdf','Alice <a@acme.com>','me@example.com');
      INSERT INTO messages VALUES (1,1,#{Time.utc(2026, 3, 1).to_i * 1_000_000},'<a@x>',0);
    SQL
    db.close
    path
  end

  def make_calendar(dir)
    path = File.join(dir, 'cache.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER, event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT);
      CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT);
      INSERT INTO cal_events VALUES ('c','e1','Team standup',#{Time.utc(2026, 5, 1, 7, 0).to_i * 1_000_000},#{(Time.utc(2026, 5, 1, 7, 0).to_i + 1800) * 1_000_000},'Europe/Helsinki','Europe/Helsinki',262,'CONFIRMED');
      INSERT INTO cal_properties VALUES ('e1','LOCATION','Zoom');
      INSERT INTO cal_properties VALUES ('e1','DESCRIPTION','daily sync');
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
        out = tool.run('query' => 'invoice')
        assert_match(/1 match/, out)
        assert_match(/id: <a@x>/, out)
        assert_match(/Invoice 2024/, out)

        assert_match(/No matching mail/, tool.run('query' => 'zzzznope'))
        assert_match(/Error: bad date/, tool.run('query' => 'invoice', 'after' => 'not-a-date'))
        g.close
      end
    end
  end

  describe 'thunderbird_mail_read' do
    it 'returns the full message and Errors on unknown id' do
      Dir.mktmpdir do |dir|
        g = gloda(dir)
        tool = Pikuri::Thunderbird::MailRead.new(backend: mail(g))
        out = tool.run('message_id' => '<a@x>')
        assert_match(/Subject: Invoice 2024/, out)
        assert_match(/invoice attached/, out)
        assert_match(/Attachments: invoice.pdf/, out)
        assert_match(/Error: no message/, tool.run('message_id' => '<nope@x>'))
        g.close
      end
    end
  end

  describe 'thunderbird_calendar_search' do
    it 'lists matching events' do
      Dir.mktmpdir do |dir|
        c = calendar(dir)
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)
        out = tool.run('query' => 'standup')
        assert_match(/Team standup/, out)
        assert_match(/id: e1/, out)
        assert_match(/where: Zoom/, out)
        c.close
      end
    end

    it 'guides the user to enable Offline Support when nothing is cached' do
      Dir.mktmpdir do |dir|
        c = calendar(dir, []) # no calendar stores on disk
        tool = Pikuri::Thunderbird::CalendarSearch.new(backend: c)
        assert_match(/Offline Support/, tool.run('query' => 'anything'))
        c.close
      end
    end
  end

  describe 'thunderbird_calendar_read' do
    it 'returns event detail and Errors on unknown id' do
      Dir.mktmpdir do |dir|
        c = calendar(dir)
        tool = Pikuri::Thunderbird::CalendarRead.new(backend: c)
        out = tool.run('event_id' => 'e1')
        assert_match(/Title: Team standup/, out)
        assert_match(/Where: Zoom/, out)
        assert_match(/daily sync/, out)
        assert_match(/Error: no event/, tool.run('event_id' => 'nope'))
        c.close
      end
    end
  end
end
