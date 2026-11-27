# frozen_string_literal: true

require 'tmpdir'

# A synthetic prefs.js: two IMAP accounts on one host, the second the
# default, and Local Folders, which has no identity of its own.
describe Pikuri::Thunderbird::Accounts do
  def prefs = <<~JS
    user_pref("mail.account.account1.identities", "id1");
    user_pref("mail.account.account1.server", "server1");
    user_pref("mail.account.account2.server", "server2");
    user_pref("mail.account.account3.identities", "id2,id3");
    user_pref("mail.account.account3.server", "server3");
    user_pref("mail.account.lastKey", 3);
    user_pref("mail.accountmanager.accounts", "account1,account3,account2");
    user_pref("mail.accountmanager.defaultaccount", "account3");
    user_pref("mail.identity.id1.fullName", "Alex Novak");
    user_pref("mail.identity.id1.useremail", "alex@novak.example");
    user_pref("mail.identity.id2.useremail", "alex.novak@kotiposti.example");
    user_pref("mail.identity.id3.fullName", "Alex N.");
    user_pref("mail.identity.id3.useremail", "an@kotiposti.example");
    user_pref("mail.server.server1.directory-rel", "[ProfD]ImapMail/imap.example.com");
    user_pref("mail.server.server1.hostname", "imap.example.com");
    user_pref("mail.server.server1.type", "imap");
    user_pref("mail.server.server1.userName", "alex@novak.example");
    user_pref("mail.server.server2.hostname", "Local Folders");
    user_pref("mail.server.server2.type", "none");
    user_pref("mail.server.server2.userName", "nobody");
    user_pref("mail.server.server3.hostname", "imap.example.com");
    user_pref("mail.server.server3.type", "imap");
    user_pref("mail.server.server3.userName", "alex.novak@kotiposti.example");
  JS

  def accounts(text = prefs)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'prefs.js'), text)
      yield described_class.read(Pikuri::Thunderbird::Profile.new(dir: dir, variant: :override))
    end
  end

  def work = 'imap://alex%40novak.example@imap.example.com/INBOX'
  def personal = 'imap://alex.novak%40kotiposti.example@imap.example.com/[Gmail]/All Mail'

  it 'lists every identity, an unnamed one with an empty name' do
    accounts do |a|
      assert_equal %w[alex@novak.example alex.novak@kotiposti.example an@kotiposti.example], a.identities.map(&:email)
      assert_equal ['Alex Novak', '', 'Alex N.'], a.identities.map(&:name)
    end
  end

  it "maps a folder to its account's identities, default first" do
    accounts do |a|
      assert_equal ['alex@novak.example'], a.identities_for(work).map(&:email)
      assert_equal %w[alex.novak@kotiposti.example an@kotiposti.example], a.identities_for(personal).map(&:email)
    end
  end

  it "answers a Local Folders folder, or an unknown one, with the default account's" do
    accounts do |a|
      assert_equal 'alex.novak@kotiposti.example',
                   a.identities_for('mailbox://nobody@Local%20Folders/Archive').first.email
      assert_equal 'alex.novak@kotiposti.example', a.identities_for('imap://who@nowhere/INBOX').first.email
    end
  end

  it "finds a folder's server by scheme, user and host, and nothing for an unknown one" do
    accounts do |a|
      assert_equal '[ProfD]ImapMail/imap.example.com', a.server_for(work)['directory-rel']
      assert_equal 'none', a.server_for('mailbox://nobody@Local%20Folders/Archive')['type']
      assert_nil a.server_for('imap://who@nowhere/INBOX')
      assert_nil a.server_for('not a uri')
    end
  end

  it 'reads a profile without prefs.js as no accounts' do
    Dir.mktmpdir do |dir|
      a = described_class.read(Pikuri::Thunderbird::Profile.new(dir: dir, variant: :override))
      assert_empty a.identities
      assert_empty a.identities_for(work)
    end
  end
end
