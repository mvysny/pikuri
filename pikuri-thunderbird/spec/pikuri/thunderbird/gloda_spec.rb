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

  # Simulate Thunderbird indexing a new message into the live file, which bumps
  # the change counter the freshness check reads.
  def add_message(dir, id, body: 'a zebra appeared')
    src = SQLite3::Database.new(File.join(dir, 'global-messages-db.sqlite'))
    src.execute('INSERT INTO messagesText_content VALUES (?,?,?,?,?,?)', [id, body, 'Z', '', 'Eve', 'me'])
    src.execute('INSERT INTO messages VALUES (?,1,1600000000000000,?,0)', [id, "<#{id}@x>"])
    src.close
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

  it 'strips the literal undefined only right after an address' do
    assert_equal 'Mira <mira@lumo.example>, bob@x.example',
                 Gloda.strip_undefined('Mira <mira@lumo.example> undefined, bob@x.example undefined')
    assert_equal 'Undefined <u@x.example>', Gloda.strip_undefined('Undefined <u@x.example> undefined')
    assert_equal 'me@x.example', Gloda.strip_undefined('me@x.example')
    assert_equal 'Martin <m@x.example> Martin Vyšný', Gloda.strip_undefined('Martin <m@x.example> Martin Vyšný')
    assert_nil Gloda.strip_undefined(nil)
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

      add_message(dir, 99)

      # a fresh with_fresh_db sees it (re-snapshot + reindex fired)
      assert_equal 2, gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') }
      assert_equal 1, gloda.with_fresh_db { |db| db.get_first_value("SELECT count(*) FROM fts WHERE fts MATCH 'zebra'") }
    end
  end

  it 'keeps serving the older copy while Thunderbird is mid-write, even after a close' do
    with_gloda(rows: 1) do |gloda, dir|
      count = -> { gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') } }
      assert_equal 1, count.()

      add_message(dir, 99)
      journal = File.join(dir, 'global-messages-db.sqlite-journal')
      File.write(journal, '')
      assert_equal 1, count.(), 'busy → the older copy answers'
      gloda.close
      assert_equal 1, count.(), 'busy after a close → the older copy reopens'

      File.delete(journal)
      assert_equal 2, count.()
    end
  end

  # P_shared_locked, asserted on the *outcome* rather than on a schedule: a
  # reader parks inside its block while a second caller tries to rebuild. Drop
  # the lock and the rebuild's #close lands on the handle the reader is still
  # holding, so its query raises on a closed database. Under the lock the
  # rebuild cannot start at all, which is what the join-timeout proves.
  it 'holds the lock across the block, so a rebuild cannot close a live reader' do
    with_gloda(rows: 1) do |gloda, dir|
      held = Queue.new
      release = Queue.new
      outcome = nil

      reader = Thread.new do
        gloda.with_fresh_db do |db|
          held << :ready
          release.pop
          outcome = db.get_first_value('SELECT count(*) FROM messages')
        rescue SQLite3::Exception => e
          outcome = e
        end
      end

      held.pop
      add_message(dir, 99) # move the generation, so the next call must rebuild
      rebuilder = Thread.new { gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') } }
      refute rebuilder.join(0.3), 'rebuild ran while a reader held the connection'
      release << :go
      [reader, rebuilder].each(&:join)

      assert_equal 1, outcome, "reader saw #{outcome.inspect} instead of its snapshot's row count"
    end
  end

  it 'reopens after a co-owner closes, rather than failing' do
    with_gloda(rows: 2) do |gloda|
      assert_equal 2, gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') }
      gloda.close # what one agent's on_close does while another still holds it
      assert_equal 2, gloda.with_fresh_db { |db| db.get_first_value('SELECT count(*) FROM messages') }
      assert_equal 2, gloda.with_fresh_db { |db| db.get_first_value("SELECT count(*) FROM fts WHERE fts MATCH 'body'") }
    end
  end
end
