# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

# The Gloda *service*: snapshot + FTS5 index + freshness + a current
# connection. Query behaviour lives in the view specs (gloda/mail_spec,
# contact_search_spec); here we test only the access the service provides.
describe Pikuri::Thunderbird::Gloda do
  Gloda = Pikuri::Thunderbird::Gloda unless defined?(Gloda)

  def make_gloda(dir, rows: 1)
    path = File.join(dir, 'global-messages-db.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER);
      CREATE TABLE folderLocations(id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER);
    SQL
    rows.times do |i|
      db.execute('INSERT INTO messagesText_content VALUES (?,?,?,?,?,?)',
                 [i + 1, "body #{i}", 'subj', '', 'a@x', 'me@x'])
      db.execute('INSERT INTO messages VALUES (?,?,?,?,?)', [i + 1, 1, 1_600_000_000_000_000, "<#{i}@x>", 0])
    end
    db.close
    path
  end

  def with_gloda(**kw)
    Dir.mktmpdir do |dir|
      gloda = Gloda.new(gloda_path: make_gloda(dir, **kw), cache_dir: File.join(dir, 'cache'))
      begin
        yield gloda, dir
      ensure
        gloda.close
      end
    end
  end

  it 'reports availability by the index file existing' do
    with_gloda { |gloda| assert gloda.available? }
    Dir.mktmpdir do |dir|
      absent = Gloda.new(gloda_path: File.join(dir, 'nope.sqlite'), cache_dir: File.join(dir, 'c'))
      refute absent.available?
    end
  end

  it 'yields a queryable, FTS-indexed connection through with_fresh_db' do
    with_gloda(rows: 3) do |gloda|
      count = gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') }
      assert_equal 3, count
      # the service built the FTS5 index the views rely on
      hits = gloda.with_fresh_db { |db| db.get_first_value("SELECT count(*) FROM fts WHERE fts MATCH 'body'") }
      assert_equal 3, hits
    end
  end

  it 'rebuilds when the live Gloda generation moves (freshness)' do
    with_gloda(rows: 1) do |gloda, dir|
      assert_equal 1, gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') }

      # simulate Thunderbird indexing a new message into the live file
      src = SQLite3::Database.new(File.join(dir, 'global-messages-db.sqlite'))
      src.execute("INSERT INTO messagesText_content VALUES (99,'a zebra appeared','Z','','Eve','me')")
      src.execute('INSERT INTO messages VALUES (99,1,1600000000000000,\'<z@x>\',0)')
      src.close

      # a fresh with_fresh_db sees it (re-snapshot + reindex fired)
      assert_equal 2, gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') }
      assert_equal 1, gloda.with_fresh_db { |db| db.get_first_value("SELECT count(*) FROM fts WHERE fts MATCH 'zebra'") }
    end
  end
end
