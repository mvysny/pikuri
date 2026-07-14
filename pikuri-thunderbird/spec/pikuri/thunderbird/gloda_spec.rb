# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe Pikuri::Thunderbird::Gloda do
  Gloda = Pikuri::Thunderbird::Gloda

  D1 = Time.at(1_600_000_000)
  D2 = Time.at(1_600_100_000)
  D3 = Time.at(1_600_200_000)
  D4 = Time.at(1_600_300_000)

  # Build a fixture Gloda DB mirroring the real schema: messagesText_content
  # (decoded columns, docid PK), messages (id/folderID/date/headerMessageID/
  # deleted), folderLocations. Includes a Gmail-style duplicate (same
  # Message-ID in INBOX + All Mail), a deleted row, and a header-less row.
  def make_gloda(dir)
    path = File.join(dir, 'global-messages-db.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(
        docid INTEGER PRIMARY KEY,
        c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(
        id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER,
        headerMessageID TEXT, deleted INTEGER);
      CREATE TABLE folderLocations(
        id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER,
        name TEXT, indexingPriority INTEGER);
      INSERT INTO folderLocations VALUES (1,'imap://x/INBOX',0,'INBOX',50);
      INSERT INTO folderLocations VALUES (2,'imap://x/All',0,'All Mail',20);
    SQL
    text = db.prepare('INSERT INTO messagesText_content VALUES (?,?,?,?,?,?)')
    msg  = db.prepare('INSERT INTO messages VALUES (?,?,?,?,?)')

    # docid 1 + its All-Mail duplicate (docid 2), same Message-ID <a@x>
    text.execute(1, 'Please find the invoice attached', 'Invoice 2024', 'invoice.pdf',
                 'Alice <alice@example.com>', 'me@example.com')
    msg.execute(1, 1, D1.to_i * 1_000_000, '<a@x>', 0)
    text.execute(2, 'Please find the invoice attached', 'Invoice 2024', 'invoice.pdf',
                 'Alice <alice@example.com>', 'me@example.com')
    msg.execute(2, 2, D1.to_i * 1_000_000, '<a@x>', 0)
    # docid 3: unrelated
    text.execute(3, 'lunch plans tomorrow', 'Lunch', '', 'Bob <bob@example.com>', 'me@example.com')
    msg.execute(3, 1, D2.to_i * 1_000_000, '<b@x>', 0)
    # docid 4: deleted (must never surface)
    text.execute(4, 'secret invoice deleted stuff', 'Old', '', 'Carol', 'me@example.com')
    msg.execute(4, 1, D3.to_i * 1_000_000, '<c@x>', 1)
    # docid 5: header-less → gloda:5 handle
    text.execute(5, 'another invoice with no header id', 'NoID', '', 'Dave', 'me@example.com')
    msg.execute(5, 1, D4.to_i * 1_000_000, '', 0)

    [text, msg].each(&:close)
    db.close
    path
  end

  def with_gloda
    Dir.mktmpdir do |dir|
      gloda = Gloda.new(gloda_path: make_gloda(dir), cache_dir: File.join(dir, 'cache'))
      begin
        yield gloda, dir
      ensure
        gloda.close
      end
    end
  end

  it 'dedups Gmail label duplicates by Message-ID' do
    with_gloda do |gloda|
      hits = gloda.search(query: 'invoice', limit: 10)
      ids = hits.map { |h| h[:message_id] }
      assert_equal 1, ids.count('<a@x>'), 'the All-Mail duplicate is collapsed'
      assert_includes ids, 'gloda:5', 'header-less message gets a gloda: handle'
    end
  end

  it 'ORs query words (recall-first): any word can match' do
    with_gloda do |gloda|
      ids = gloda.search(query: 'invoice lunch', limit: 10).map { |h| h[:message_id] }
      # "invoice" hits <a@x>/gloda:5, "lunch" hits <b@x> — OR returns all.
      assert_includes ids, '<a@x>'
      assert_includes ids, '<b@x>', 'a message matching only the second word still appears'
    end
  end

  it 'excludes deleted messages' do
    with_gloda do |gloda|
      assert_empty gloda.search(query: 'secret', limit: 10)
    end
  end

  it 'ranks the strongest match first' do
    with_gloda do |gloda|
      hits = gloda.search(query: 'invoice', limit: 1)
      assert_equal '<a@x>', hits.first[:message_id]
      assert_equal 'Invoice 2024', hits.first[:subject]
    end
  end

  it 'applies structured filters' do
    with_gloda do |gloda|
      assert_equal ['<b@x>'], gloda.search(query: 'lunch', limit: 10, from: 'bob').map { |h| h[:message_id] }
      # date filter: only the D4 invoice survives after: D2
      assert_equal ['gloda:5'], gloda.search(query: 'invoice', limit: 10, after: D2).map { |h| h[:message_id] }
      # folder filter narrows to the All-Mail copy
      folders = gloda.search(query: 'invoice', limit: 10, folder: 'All Mail').map { |h| h[:folder] }
      assert_equal ['All Mail'], folders
    end
  end

  it 'reads a full message by Message-ID and by gloda: handle' do
    with_gloda do |gloda|
      rec = gloda.read(message_id: '<a@x>')
      assert_includes rec[:body], 'invoice attached'
      assert_equal 'invoice.pdf', rec[:attachment_names]
      assert_equal 'INBOX', rec[:folder]
      assert_kind_of Time, rec[:date]

      assert_includes gloda.read(message_id: 'gloda:5')[:body], 'no header id'
      assert_nil gloda.read(message_id: '<does-not-exist@x>')
    end
  end

  it 'rebuilds the index when the Gloda generation moves' do
    with_gloda do |gloda, dir|
      assert_empty gloda.search(query: 'zebra', limit: 10)
      # simulate Thunderbird indexing a new message
      src = SQLite3::Database.new(File.join(dir, 'global-messages-db.sqlite'))
      src.execute("INSERT INTO messagesText_content VALUES (6,'a zebra appeared','Zebra','','Eve','me')")
      src.execute("INSERT INTO messages VALUES (6,1,#{D4.to_i * 1_000_000},'<z@x>',0)")
      src.close

      hits = gloda.search(query: 'zebra', limit: 10)
      assert_equal ['<z@x>'], hits.map { |h| h[:message_id] }
    end
  end
end
