# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe 'thunderbird_contact_search' do
  Contacts = Pikuri::Thunderbird::Gloda::Contacts
  ContactSearch = Pikuri::Thunderbird::ContactSearch

  US = 1_000_000

  # A fixture exercising the real-data shapes the resolver must survive:
  # a bracketed Name <addr>, a bare address (name trailing, no brackets), a
  # literal "undefined" name, a Sent-folder message (the strong signal), a
  # spoofer who mailed *as* the real contact from a different address, and a
  # two-recipient cell. Folder indexingPriority 60 == Sent.
  def make_gloda(dir)
    path = File.join(dir, 'global-messages-db.sqlite')
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(
        docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(
        id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER);
      CREATE TABLE folderLocations(
        id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER);
      CREATE TABLE identities(id INTEGER PRIMARY KEY, contactID INTEGER, kind TEXT, value TEXT);
      INSERT INTO folderLocations VALUES (1,'imap://x/INBOX',0,'INBOX',50);
      INSERT INTO folderLocations VALUES (2,'imap://x/Sent',0,'Sent',60);
      INSERT INTO identities VALUES (1,1,'email','martin@vysny.me');
      INSERT INTO identities VALUES (2,2,'email','alice@acme.com');
    SQL
    text = db.prepare('INSERT INTO messagesText_content VALUES (?,?,?,?,?,?)')
    msg  = db.prepare('INSERT INTO messages VALUES (?,?,?,?,?)')
    add = lambda do |id, folder, author, recipients|
      text.execute(id, 'body', 'subj', '', author, recipients)
      msg.execute(id, folder, 1_600_000_000 * US + id, "<m#{id}@x>", 0)
    end

    # Two received from the real Martin (bracketed + bare forms).
    add.call(1, 1, 'Martin Vysny <martin@vysny.me> Martin Vyšný', 'me@example.com')
    add.call(2, 1, 'martin@vysny.me Martin Vyšný', 'me@example.com')
    # One I *sent* to Martin — the Sent-folder signal (recipient is the contact,
    # author is me and must NOT surface for a "martin" query).
    add.call(3, 2, 'me@example.com', 'Martin Vysny <martin@vysny.me>')
    # A spoofer: mailed *as* "Martin Vysny" from a different address, once.
    add.call(4, 1, 'Martin Vysny <evil@phish.example>', 'me@example.com')
    # Bare address, "undefined" name (no brackets).
    add.call(5, 1, 'support@synergi.so undefined', 'me@example.com')
    # Two recipients in one cell (domain query should return both).
    add.call(6, 2, 'me@example.com', 'Alice <alice@acme.com>, Bob <bob@acme.com>')

    [text, msg].each(&:close)
    db.close
    path
  end

  # Yields a Gloda::Contacts resolver over the fixture (the tool + the backend
  # both work through it; the underlying Gloda is closed on the way out).
  def with_contacts
    Dir.mktmpdir do |dir|
      gloda = Pikuri::Thunderbird::Gloda.new(gloda_path: make_gloda(dir), cache_dir: File.join(dir, 'cache'))
      begin
        yield Contacts.new(gloda: gloda)
      ensure
        gloda.close
      end
    end
  end

  it 'ranks the real contact above a same-name spoofer, with the Sent signal' do
    with_contacts do |contacts|
      cands = contacts.resolve(query: 'martin', limit: 10)
      addrs = cands.map { |c| c[:address] }
      assert_equal 'martin@vysny.me', addrs.first, 'the mailed contact ranks first'
      assert_includes addrs, 'evil@phish.example', 'the spoofer still surfaces (honest)'
      assert_operator addrs.index('martin@vysny.me'), :<, addrs.index('evil@phish.example')

      real = cands.find { |c| c[:address] == 'martin@vysny.me' }
      assert_equal 1, real[:sent], 'the Sent message counts as mailed-to'
      assert_equal 'Martin Vysny', real[:name], 'the most-seen display name wins'
      spoof = cands.find { |c| c[:address] == 'evil@phish.example' }
      assert_equal 0, spoof[:sent], 'a spoofer is never in Sent'
    end
  end

  it 'never surfaces my own address or a co-recipient for a name query' do
    with_contacts do |contacts|
      addrs = contacts.resolve(query: 'martin', limit: 10).map { |c| c[:address] }
      refute_includes addrs, 'me@example.com', 'own address on the Sent message is filtered out'
    end
  end

  it 'extracts a bare address and drops the "undefined" name noise' do
    with_contacts do |contacts|
      cand = contacts.resolve(query: 'synergi', limit: 10).first
      assert_equal 'support@synergi.so', cand[:address]
      assert_nil cand[:name], 'a literal "undefined" is not a display name'
    end
  end

  it 'returns every matching recipient in a multi-recipient cell (domain query)' do
    with_contacts do |contacts|
      addrs = contacts.resolve(query: 'acme', limit: 10).map { |c| c[:address] }
      assert_equal %w[alice@acme.com bob@acme.com], addrs.sort
    end
  end

  it 'reverse-resolves an address to its display name' do
    with_contacts do |contacts|
      cand = contacts.resolve(query: 'evil@phish.example', limit: 10).first
      assert_equal 'evil@phish.example', cand[:address]
      assert_equal 'Martin Vysny', cand[:name]
    end
  end

  it 'returns nothing for an empty or unmatched query' do
    with_contacts do |contacts|
      assert_empty contacts.resolve(query: '', limit: 10)
      assert_empty contacts.resolve(query: 'nobodyhere', limit: 10)
    end
  end

  it 'counts a domain as known only once the user has sent mail to it (novelty)' do
    with_contacts do |contacts|
      # phish.example and synergi.so only ever wrote to the user: an attacker
      # earns "known" by writing first, so received mail must not count.
      assert_equal %w[vysny.me acme.com],
                   contacts.domains_sent_to(%w[vysny.me acme.com phish.example synergi.so ghost.example])
      # A substring of a Sent recipient's domain is not that domain.
      assert_empty contacts.domains_sent_to(%w[acme.co vysny.me.evil.example])
      assert_empty contacts.domains_sent_to([])
    end
  end

  it 'cannot answer novelty when no Sent-folder mail is indexed' do
    Dir.mktmpdir do |dir|
      path = make_gloda(dir)
      SQLite3::Database.new(path) { |db| db.execute('UPDATE folderLocations SET indexingPriority = 50') }
      gloda = Pikuri::Thunderbird::Gloda.new(gloda_path: path, cache_dir: File.join(dir, 'cache'))
      begin
        assert_nil Contacts.new(gloda: gloda).domains_sent_to(%w[vysny.me])
      ensure
        gloda.close
      end
    end
  end

  describe 'the tool' do
    it 'renders ranked Name <addr> candidates with a familiarity signal' do
      with_contacts do |contacts|
        out = ContactSearch.new(backend: contacts).run('query' => 'martin').to_s
        assert_match(/contacts \(best first\)/, out)
        assert_match(/Martin Vysny <martin@vysny\.me>/, out)
        assert_match(/established contact/, out)          # has Sent history
        assert_match(/<evil@phish\.example>/, out)
        assert_match(/verify the address/, out)           # received-only
      end
    end

    it 'reports no match plainly' do
      with_contacts do |contacts|
        assert_match(/No contacts found/, ContactSearch.new(backend: contacts).run('query' => 'zzznobody').to_s)
      end
    end
  end
end
