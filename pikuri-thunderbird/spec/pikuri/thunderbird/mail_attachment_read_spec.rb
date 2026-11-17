# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'sqlite3'
require 'json'

# End to end over a synthetic profile: a Gloda index listing the attachments,
# prefs.js mapping the account, and the mbox holding the message's bytes.
describe Pikuri::Thunderbird::MailAttachmentRead do
  def folder_uri = 'imap://me%40example.com@imap.example.com/INBOX'

  # Gloda's attachmentInfos for <att@x>, in listing order. Parts 1.2–1.8 exist
  # in the stored message; the online link is refused before the store is read.
  def infos
    [['notes.txt', 'text/plain', 24, '1.2', nil, false],
     ['invite.ics', 'application/ics', 40, '1.3', nil, false],
     ['blob.bin', 'application/octet-stream', 4, '1.4', nil, false],
     ['Deleted: old.pdf', 'text/x-moz-deleted', 90, '1.5', nil, false],
     ['photo.jpg', 'image/jpeg', -1, '1.6', nil, false],
     ['ForwardedMessage.eml', 'message/rfc822', 0, '1.7', nil, false],
     ['cloud.pdf', 'application/pdf', 0, '1.8', 'https://files.example.com/x', true],
     ['scan.bin', 'application/octet-stream', 6, '1.8', nil, false]]
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
      --B
      Content-Type: image/jpeg; name="photo.jpg"
      Content-Transfer-Encoding: base64

      #{["\xFF\xD8\xFF\xE0jpeg".b].pack('m0')}
      --B
      Content-Type: message/rfc822
      Content-Disposition: attachment; filename="ForwardedMessage.eml"

      From: =?UTF-8?Q?Lea_M=C3=A4kinen?= <lea@example.com>
      To: Tomas <tomas@example.com>
      Cc: ilse@example.com
      Subject: =?UTF-8?Q?Hakemus:_kehitt=C3=A4j=C3=A4?=
      Date: Mon, 9 Nov 2026 22:14:00 +0000
      Message-ID: <inner@x>
      Content-Type: multipart/mixed; boundary="C"

      --C
      Content-Type: multipart/alternative; boundary="D"

      --D
      Content-Type: text/plain; charset=iso-8859-1
      Content-Transfer-Encoding: quoted-printable

      My CV is attached, caf=E9.
      --D
      Content-Type: multipart/related; boundary="E"

      --E
      Content-Type: text/html; charset=utf-8

      <p>My CV is attached.</p><img src="cid:logo@x">
      --E
      Content-Type: image/png
      Content-Disposition: inline; filename="logo.png"
      Content-ID: <logo@x>

      png
      --E--
      --D--
      --C
      Content-Type: application/pdf; name="cv.pdf"
      Content-Disposition: attachment; filename="cv.pdf"

      %PDF-
      --C
      Content-Type: text/plain; name="references.txt"
      Content-Disposition: attachment; filename="references.txt"

      Ask Mira at Lumo.
      --C
      Content-Type: message/rfc822
      Content-Disposition: attachment; filename="Earlier.eml"

      Subject: Portfolio
      Content-Type: multipart/mixed; boundary="F"

      --F
      Content-Type: text/plain

      My portfolio.
      --F
      Content-Type: text/plain; name="portfolio.txt"
      Content-Disposition: attachment; filename="portfolio.txt"

      Two shop sites.
      --F--
      --C--
      --B
      Content-Type: application/octet-stream; name="scan.bin"

      %PDF-
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
      -- Headers only: Gloda never saw the body, so body and attachment names are NULL.
      INSERT INTO messagesText_content VALUES (3,NULL,'Photos',NULL,'Carol','me@example.com');
    SQL
    db.execute('INSERT INTO messages VALUES (1,1,1600000000000000,?,0,?)', ['att@x', JSON.generate('51' => infos)])
    db.execute('INSERT INTO messages VALUES (2,1,1600000000000000,?,0,?)', ['', JSON.generate('51' => infos)])
    db.execute('INSERT INTO messages VALUES (3,1,1600000000000000,?,0,?)', ['hdr@x', '{}'])
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
    tool.run({ 'message_id' => id, 'attachment' => attachment.to_s }.merge(opts.transform_keys(&:to_s)))
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

  it 'names the format the host has no reader for, by its bytes over its declared type' do
    with_tools do |tool, _|
      assert_equal "Error: unsupported format application/octet-stream, can't extract text on this host.",
                   read(tool, 3).content
      assert_equal "Error: unsupported format application/pdf, can't extract text on this host.", read(tool, 8).content
    end
  end

  it 'refuses a PDF on a host without a PDF reader, even when its first bytes look like text' do
    with_tools do |tool, _|
      assert_equal "Error: unsupported format application/pdf, can't extract text on this host.",
                   read(tool, '6.1').content
    end
  end

  it 'refuses a detached stub and an online link' do
    with_tools do |tool, _|
      assert_includes read(tool, 4).content, 'detached or deleted'
      assert_includes read(tool, 7).content, 'attachment 7 is a link to an online file'
    end
  end

  it 'answers an image as the picture itself, typed by its bytes' do
    with_tools do |tool, _|
      result = read(tool, 5)

      assert_equal 'Read image: photo.jpg (8 B, image/jpeg)', result.content
      assert_equal 'Read image, 8 B', result.summary
      assert_equal [Pikuri::Attachment.new(mime: 'image/jpeg', filename: 'photo.jpg', bytes: "\xFF\xD8\xFF\xE0jpeg".b)],
                   result.attachments
    end
  end

  it 'refuses an image over the cap, before it reaches the model' do
    big = "\x89PNG\r\n\x1a\n".b + ("\0".b * Pikuri::Attachment::MAX_IMAGE_BYTES)
    found = described_class::Found.new(handle: '3.1', name: 'huge.png', content_type: 'image/png', bytes: big)

    result = described_class.send(:image_result, found, 'image/png')

    assert_equal 'Error: attachment 3.1 is an image of 5.0 MB, over the 5.0 MB that can be shown.', result.content
    assert_empty result.attachments
  end

  it "reads a forwarded email as its headers, numbered attachments and text, listing what Gloda would" do
    with_tools do |tool, _|
      lines = read(tool, 6).content.lines.map { _1.sub(/\A *\d+\t/, '').chomp }

      assert_equal ['Subject: Hakemus: kehittäjä',
                    'From: "Lea Mäkinen" <lea@example.com>',
                    'To: Tomas <tomas@example.com>',
                    'Cc: ilse@example.com',
                    "Date: #{Time.utc(2026, 11, 9, 22, 14).getlocal.strftime('%Y-%m-%d %H:%M')}",
                    'Attachments:',
                    '  6.1. cv.pdf (application/pdf, 5 B)',
                    '  6.2. references.txt (text/plain, 17 B)',
                    '  6.3. Earlier.eml (forwarded email)',
                    '',
                    'My CV is attached, café.'], lines.first(11)
      refute_includes lines.join, 'logo.png' # a cid: image is body, as Gloda has it
    end
  end

  describe 'a path into a forwarded email' do
    it "reads the forward's own attachment, and one a forward deeper" do
      with_tools do |tool, _|
        assert_includes read(tool, '6.2').content, "1\tAsk Mira at Lumo."
        assert_includes read(tool, '6.3').content, "  6.3.1. portfolio.txt (text/plain, 15 B)"
        assert_includes read(tool, '6.3.1').content, "1\tTwo shop sites."
        assert_includes read(tool, '6.2.').content, "1\tAsk Mira at Lumo." # as the listing prints it
      end
    end

    it 'answers a wrong number with the listing it missed' do
      with_tools do |tool, _|
        out = read(tool, '6.9').content

        assert out.start_with?('Error: no attachment 6.9; attachment 6 has:')
        assert_includes out, '  6.2. references.txt (text/plain, 17 B)'
        assert_equal 'Error: attachment 1 is not a forwarded email, so it has no attachment 1.1.',
                     read(tool, '1.1').content
        assert_equal 'Error: attachment 6.2 is not a forwarded email, so it has no attachment 6.2.1.',
                     read(tool, '6.2.1').content
      end
    end

    it 'refuses a handle that is not a listed number' do
      with_tools do |tool, _|
        assert_equal 'Error: attachment must be a number as listed, e.g. "2" or "2.1"; got "first".',
                     read(tool, 'first').content
        assert_includes read(tool, '0').content, 'must be a number as listed'
      end
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

  it 'says to keep the account offline when Thunderbird downloaded only the headers' do
    with_tools do |tool, mail_read|
      out = mail_read.run('message_id' => 'hdr@x').content

      assert_includes out, "Attachments: unknown\n"
      assert out.end_with?(Pikuri::Thunderbird::MailRead::NOT_DOWNLOADED_NOTE)
      result = read(tool, 1, id: 'hdr@x')
      assert result.error?
      assert_includes result.content, 'Keep messages in all folders for this account on this computer'
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
        assert_includes out, "  6. ForwardedMessage.eml (forwarded email)\n  7. cloud.pdf"
        assert_includes out, "\n  (A forwarded email's text may also appear in the body below;"
        assert_includes out, '  7. cloud.pdf (application/pdf, online link, not stored)'
      end
    end
  end
end
