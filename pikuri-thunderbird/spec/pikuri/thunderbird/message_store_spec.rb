# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# A synthetic profile: prefs.js naming two accounts on one host (the second
# gets the "-1" directory), and an mbox laid out the way Thunderbird writes one.
describe Pikuri::Thunderbird::MessageStore do
  def prefs = <<~JS
    user_pref("mail.server.server1.directory-rel", "[ProfD]ImapMail/imap.example.com");
    user_pref("mail.server.server1.hostname", "imap.example.com");
    user_pref("mail.server.server1.type", "imap");
    user_pref("mail.server.server1.userName", "me@example.com");
    user_pref("mail.server.server1.storeContractID", "@mozilla.org/msgstore/berkeleystore;1");
    user_pref("mail.server.server2.directory-rel", "[ProfD]ImapMail/imap.example-1.com");
    user_pref("mail.server.server2.hostname", "imap.example.com");
    user_pref("mail.server.server2.type", "imap");
    user_pref("mail.server.server2.userName", "other@example.com");
    user_pref("mail.server.server3.directory-rel", "[ProfD]ImapMail/imap.maildir.com");
    user_pref("mail.server.server3.hostname", "imap.maildir.com");
    user_pref("mail.server.server3.type", "imap");
    user_pref("mail.server.server3.userName", "md");
    user_pref("mail.server.server3.storeContractID", "@mozilla.org/msgstore/maildirstore;1");
  JS

  def all_mail = 'imap://me%40example.com@imap.example.com/[Gmail]/All Mail'

  # One mbox message, CRLF throughout, as Thunderbird stores it.
  def mbox_message(message_id, body, status: '0001', extra: '')
    "From - Sat Oct 10 09:11:07 2026\nX-Mozilla-Status: #{status}\n#{extra}" \
      "Message-ID: <#{message_id}>\nSubject: s\n\n#{body}\n".gsub("\n", "\r\n")
  end

  def with_store(mbox: nil, path: %w[ImapMail imap.example.com [Gmail].sbd], name: 'All Mail')
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'prefs.js'), prefs)
      if mbox
        FileUtils.mkdir_p(File.join(dir, *path))
        File.binwrite(File.join(dir, *path, name), mbox)
      end
      profile = Pikuri::Thunderbird::Profile.new(dir: dir, variant: :override)
      yield described_class.new(profile:)
    end
  end

  def raw(store, id = 'target@x', uris = [all_mail]) = store.raw_message(message_id: id, folder_uris: uris)

  it 'returns the live copy, skipping an expunged one and a Message-ID quoted in a body' do
    forwarded = mbox_message('fwd@x', "Forwarded:\nMessage-ID: <target@x>\nquoted")
    mbox = mbox_message('target@x', 'old copy', status: '0009') + forwarded + mbox_message('target@x', 'live copy')

    with_store(mbox:) do |store|
      message = raw(store)

      assert_includes message, 'live copy'
      refute_includes message, 'From - ', 'the separator line is stripped'
      assert message.start_with?('X-Mozilla-Status: 0001')
      assert_equal Encoding::ASCII_8BIT, message.encoding
    end
  end

  it 'matches a folded Message-ID header, case-insensitively' do
    mbox = "From - x\r\nMessage-Id:\r\n <target@x>\r\n\r\nfolded\r\n"

    with_store(mbox:) { |store| assert_includes raw(store), 'folded' }
  end

  it 'finds a message past the first scan chunk' do
    filler = mbox_message('filler@x', 'x' * (described_class::CHUNK + 1024))

    with_store(mbox: filler + mbox_message('target@x', 'after the chunk')) do |store|
      assert_includes raw(store), 'after the chunk'
    end
  end

  it "maps a second account on the same host to its own directory, by prefs.js" do
    uri = 'imap://other%40example.com@imap.example.com/INBOX'

    with_store(mbox: mbox_message('target@x', 'second account'), path: %w[ImapMail imap.example-1.com],
               name: 'INBOX') do |store|
      assert_includes raw(store, 'target@x', [uri]), 'second account'
    end
  end

  it 'answers nil when no folder holds a copy, trying each in turn' do
    inbox = 'imap://me%40example.com@imap.example.com/INBOX'

    with_store(mbox: mbox_message('someone-else@x', 'b')) do |store|
      assert_nil raw(store, 'target@x', [inbox, all_mail])
    end
  end

  it 'refuses a folder no account owns, and a maildir store' do
    with_store do |store|
      err = assert_raises(described_class::Error) { raw(store, 'target@x', ['imap://nobody@nowhere/INBOX']) }
      assert_includes err.message, 'no account'

      err = assert_raises(described_class::Error) { raw(store, 'target@x', ['imap://md@imap.maildir.com/INBOX']) }
      assert_includes err.message, 'maildirstore'
    end
  end
end
