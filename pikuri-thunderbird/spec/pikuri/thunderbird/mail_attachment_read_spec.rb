# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'sqlite3'
require 'json'

# End to end over a synthetic profile: a Gloda index listing the attachments,
# prefs.js mapping the account, and the mbox holding the message's bytes.
describe Pikuri::Thunderbird::MailAttachmentRead do
  def folder_uri = 'imap://me%40example.com@imap.example.com/INBOX'

  # Gloda's attachmentInfos for <att@x>, in listing order. Parts 1.2–1.5 exist
  # in the stored message; the rest are refused before the store is read.
  def infos
    [['notes.txt', 'text/plain', 24, '1.2', nil, false],
     ['invite.ics', 'application/ics', 40, '1.3', nil, false],
     ['blob.bin', 'application/octet-stream', 4, '1.4', nil, false],
     ['Deleted: old.pdf', 'text/x-moz-deleted', 90, '1.5', nil, false],
     ['photo.jpg', 'image/jpeg', -1, '1.6', nil, false],
     ['ForwardedMessage.eml', 'message/rfc822', 0, '1.7', nil, false],
     ['cloud.pdf', 'application/pdf', 0, '1.8', 'https://files.example.com/x', true]]
  end

  def stored_message
    <<~MSG.gsub("\n", "\r\n")
      From - Sat Oct 10 09:11:07 2026
      X-Mozilla-Status: 0001
      Message-ID: <att@x>
      Content-Type: multipart/mixed; boundary="B"

      --B
      Content-Type: text/plain; charset=utf-8

      See attached.
      --B
      Content-Type: text/plain; charset=iso-8859-1; name="notes.txt"
      Content-Transfer-Encoding: base64
      Content-Disposition: attachment; filename="notes.txt"

      #{['line one', "caf\xE9 two".b].join("\n").then { [_1].pack('m0') }}
      --B
      Content-Type: application/ics; name="invite.ics"

      BEGIN:VCALENDAR
      END:VCALENDAR
      --B
      Content-Type: application/octet-stream; name="blob.bin"
      Content-Transfer-Encoding: base64

      #{["\x00\x01\x02\x03".b].pack('m0')}
      --B
      Content-Type: text/x-moz-deleted; name="Deleted: old.pdf"

      You deleted an attachment from this message.
      --B--
    MSG
  end

  def make_profile(dir, stored: true)
    db = SQLite3::Database.new(File.join(dir, 'global-messages-db.sqlite'))
    db.execute_batch(<<~SQL)
      CREATE TABLE messagesText_content(docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients);
      CREATE TABLE messages(id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER, jsonAttributes TEXT);
      CREATE TABLE folderLocations(id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER);
      CREATE TABLE attributeDefinitions(id INTEGER PRIMARY KEY, attributeType INTEGER, extensionName TEXT, name TEXT, parameter BLOB);
      INSERT INTO attributeDefinitions VALUES (51,0,'built-in','attachmentInfos',NULL);
      INSERT INTO folderLocations VALUES (1,'#{folder_uri}',0,'INBOX',50);
      INSERT INTO messagesText_content VALUES (1,'See attached.','Files','','Alice <a@example.com>','me@example.com');
      INSERT INTO messagesText_content VALUES (2,'No id here.','Old','','Bob','me@example.com');
    SQL
    db.execute('INSERT INTO messages VALUES (1,1,1600000000000000,?,0,?)', ['att@x', JSON.generate('51' => infos)])
    db.execute('INSERT INTO messages VALUES (2,1,1600000000000000,?,0,?)', ['', JSON.generate('51' => infos)])
    db.close

    File.write(File.join(dir, 'prefs.js'), <<~JS)
      user_pref("mail.server.server1.directory-rel", "[ProfD]ImapMail/imap.example.com");
      user_pref("mail.server.server1.hostname", "imap.example.com");
      user_pref("mail.server.server1.type", "imap");
      user_pref("mail.server.server1.userName", "me@example.com");
    JS
    FileUtils.mkdir_p(File.join(dir, 'ImapMail', 'imap.example.com'))
    File.binwrite(File.join(dir, 'ImapMail', 'imap.example.com', 'INBOX'), stored_message) if stored
  end

  def with_tools(stored: true)
    Dir.mktmpdir do |dir|
      make_profile(dir, stored:)
      profile = Pikuri::Thunderbird::Profile.new(dir: dir, variant: :override)
      gloda = Pikuri::Thunderbird::Gloda.new(gloda_path: profile.gloda_path, cache_dir: File.join(dir, 'gc'))
      mail = Pikuri::Thunderbird::Gloda::Mail.new(gloda:)
      store = Pikuri::Thunderbird::MessageStore.new(profile:)
      yield described_class.new(backend: mail, store:), Pikuri::Thunderbird::MailRead.new(backend: mail)
    ensure
      gloda&.close
    end
  end

  def read(tool, attachment, id: 'att@x', **opts)
    tool.run({ 'message_id' => id, 'attachment' => attachment }.merge(opts.transform_keys(&:to_s)))
  end

  it 'reads a text attachment as a cat -n page, transcoded to UTF-8' do
    with_tools do |tool, _|
      result = read(tool, 1)

      assert_equal "     1\tline one\n     2\tcafé two\n\n(End of attachment - total 2 lines)", result.content
      assert_equal 'Read 2 lines', result.summary
    end
  end

  it 'pages with offset and limit' do
    with_tools do |tool, _|
      assert_equal "     2\tcafé two\n\n(End of attachment - total 2 lines)", read(tool, 1, offset: 2).content
      assert_includes read(tool, 1, limit: 1).content, 'Use offset=2 to continue.'
    end
  end

  it 'reads a calendar invite, text under a non-text content type' do
    with_tools { |tool, _| assert_includes read(tool, 2).content, "1\tBEGIN:VCALENDAR" }
  end

  it 'names the type the host has no reader for' do
    with_tools do |tool, _|
      assert_equal 'Error: no reader for application/octet-stream attachments on this host.', read(tool, 3).content
    end
  end

  it 'refuses a detached stub, an image, a forwarded mail and an online link' do
    with_tools do |tool, _|
      assert_includes read(tool, 4).content, 'detached or deleted'
      assert_includes read(tool, 5).content, 'attachment 5 is an image'
      assert_includes read(tool, 6).content, 'attachment 6 is a forwarded email'
      assert_includes read(tool, 7).content, 'attachment 7 is a link to an online file'
    end
  end

  it 'answers a wrong number with the listing, so the model recovers in one step' do
    with_tools do |tool, _|
      out = read(tool, 9).content

      assert out.start_with?('Error: no attachment 9; this message has:')
      assert_includes out, '  1. notes.txt (text/plain, 24 B)'
    end
  end

  it "says so when the message isn't stored offline, or has no Message-ID to find it by" do
    with_tools(stored: false) do |tool, _|
      assert_includes read(tool, 1).content, "isn't stored on this computer"
      assert_includes read(tool, 1, id: 'gloda:2').content, 'no Message-ID header'
    end
  end

  it 'Errors on an unknown message and on a bad window' do
    with_tools do |tool, _|
      assert_includes read(tool, 1, id: 'nope@x').content, 'no message found'
      assert_includes read(tool, 1, offset: 0).content, 'offset must be >= 1'
    end
  end

  describe 'thunderbird_mail_read listing' do
    it 'numbers the attachments as the reader takes them, with what Gloda knows' do
      with_tools do |_, mail_read|
        out = mail_read.run('message_id' => 'att@x').to_s

        assert_includes out, "Attachments:\n  1. notes.txt (text/plain, 24 B)\n  2. invite.ics (application/ics, 40 B)"
        assert_includes out, '  5. photo.jpg (image/jpeg)'
        assert_includes out, '  6. ForwardedMessage.eml (message/rfc822)'
        assert_includes out, '  7. cloud.pdf (application/pdf, online link, not stored)'
      end
    end
  end
end
