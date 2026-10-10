# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'
require 'json'

describe Pikuri::Thunderbird::Gloda::Mail do
  Gloda = Pikuri::Thunderbird::Gloda unless defined?(Gloda)
  # Not +Mail+: a top-level constant of that name would replace the mail gem.
  GlodaMail = Pikuri::Thunderbird::Gloda::Mail

  D1 = Time.at(1_600_000_000)
  D2 = Time.at(1_600_100_000)
  D3 = Time.at(1_600_200_000)
  D4 = Time.at(1_600_300_000)

  # A fixture Gloda DB mirroring the real schema, with a Gmail-style duplicate
  # (same Message-ID in INBOX + All Mail), a deleted row, and a header-less row.
  # attachmentInfos sits at id 7, not the 51 seen live: ids are per profile.
  def make_gloda(dir)
    path = File.join(dir, 'global-messages-db.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(
        docid INTEGER PRIMARY KEY,
        c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(
        id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER,
        headerMessageID TEXT, deleted INTEGER, jsonAttributes TEXT);
      CREATE TABLE attributeDefinitions(
        id INTEGER PRIMARY KEY, attributeType INTEGER, extensionName TEXT,
        name TEXT, parameter BLOB);
      INSERT INTO attributeDefinitions VALUES (6,0,'built-in','attachmentTypes',NULL);
      INSERT INTO attributeDefinitions VALUES (7,0,'built-in','attachmentInfos',NULL);
      CREATE TABLE folderLocations(
        id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER,
        name TEXT, indexingPriority INTEGER);
      INSERT INTO folderLocations VALUES (1,'imap://me@x/INBOX',0,'INBOX',50);
      INSERT INTO folderLocations VALUES (2,'imap://me@x/[Gmail]/All Mail',0,'All Mail',20);
    SQL
    text = db.prepare('INSERT INTO messagesText_content VALUES (?,?,?,?,?,?)')
    msg  = db.prepare('INSERT INTO messages(id, folderID, date, headerMessageID, deleted) VALUES (?,?,?,?,?)')

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

    db.execute('UPDATE messages SET jsonAttributes = ? WHERE id = 1',
               [JSON.generate('7' => [['invoice.pdf', 'Application/PDF', 84_000, '1.2', nil, false],
                                      ['logo.png', 'image/png', -1, '1.1.2', nil, false]])])
    [text, msg].each(&:close)
    db.close
    path
  end

  # Yields a Gloda::Mail over the fixture; the underlying Gloda is closed after.
  def with_mail
    Dir.mktmpdir do |dir|
      gloda = Gloda.new(gloda_path: make_gloda(dir), cache_dir: File.join(dir, 'cache'))
      begin
        yield GlodaMail.new(gloda: gloda), dir
      ensure
        gloda.close
      end
    end
  end

  it 'dedups Gmail label duplicates by Message-ID' do
    with_mail do |mail|
      hits = mail.search(query: 'invoice', limit: 10)
      ids = hits.map { |h| h[:message_id] }
      assert_equal 1, ids.count('<a@x>'), 'the All-Mail duplicate is collapsed'
      assert_includes ids, 'gloda:5', 'header-less message gets a gloda: handle'
    end
  end

  it 'ORs query words (recall-first): any word can match' do
    with_mail do |mail|
      ids = mail.search(query: 'invoice lunch', limit: 10).map { |h| h[:message_id] }
      assert_includes ids, '<a@x>'
      assert_includes ids, '<b@x>', 'a message matching only the second word still appears'
    end
  end

  it 'excludes deleted messages' do
    with_mail do |mail|
      assert_empty mail.search(query: 'secret', limit: 10)
    end
  end

  it 'ranks the strongest match first' do
    with_mail do |mail|
      hits = mail.search(query: 'invoice', limit: 1)
      assert_equal '<a@x>', hits.first[:message_id]
      assert_equal 'Invoice 2024', hits.first[:subject]
    end
  end

  it 'applies structured filters' do
    with_mail do |mail|
      assert_equal ['<b@x>'], mail.search(query: 'lunch', limit: 10, from: 'bob').map { |h| h[:message_id] }
      # date filter: only the D4 invoice survives after: D2
      assert_equal ['gloda:5'], mail.search(query: 'invoice', limit: 10, after: D2).map { |h| h[:message_id] }
      # folder filter narrows to the All-Mail copy
      folders = mail.search(query: 'invoice', limit: 10, folder: 'All Mail').map { |h| h[:folder] }
      assert_equal ['All Mail'], folders
    end
  end

  it 'reads a full message by Message-ID and by gloda: handle' do
    with_mail do |mail|
      rec = mail.read(message_id: '<a@x>')
      assert_includes rec[:body], 'invoice attached'
      assert_equal 'INBOX', rec[:folder]
      assert_kind_of Time, rec[:date]

      assert_includes mail.read(message_id: 'gloda:5')[:body], 'no header id'
      assert_nil mail.read(message_id: '<does-not-exist@x>')
    end
  end

  it "lists attachments in Gloda's order, the content type lowercased" do
    with_mail do |mail|
      atts = mail.read(message_id: '<a@x>')[:attachments]

      assert_equal %w[invoice.pdf logo.png], atts.map(&:name)
      assert_equal 'application/pdf', atts.first.content_type
      assert_equal ['1.2', 84_000, false], [atts.first.part, atts.first.size, atts.first.external]
      assert_empty mail.read(message_id: '<b@x>')[:attachments]
    end
  end

  it 'lists every folder holding a copy, the read row first' do
    with_mail do |mail|
      # The read picks the newest row; both copies share a date, so the order
      # is whichever row came first, and the other folder must follow it.
      uris = mail.read(message_id: '<a@x>')[:folder_uris]

      assert_equal ['imap://me@x/INBOX', 'imap://me@x/[Gmail]/All Mail'].sort, uris.sort
      assert_equal 2, uris.size
      assert_equal ['imap://me@x/INBOX'], mail.read(message_id: 'gloda:5')[:folder_uris]
    end
  end
end
