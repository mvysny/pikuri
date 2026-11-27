# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# Over a synthetic profile: prefs.js with a work and a personal account, an
# mbox per account holding the originals' bytes, and a stand-in for Gloda's
# read, which supplies the decoded text and the folders.
describe Pikuri::Thunderbird::MailReply do
  def work = 'imap://me%40example.com@imap.example.com/INBOX'
  def personal = 'imap://me%40home.example@imap.example.com/INBOX'

  def prefs = <<~JS
    user_pref("mail.account.account1.identities", "id1");
    user_pref("mail.account.account1.server", "server1");
    user_pref("mail.account.account2.identities", "id2");
    user_pref("mail.account.account2.server", "server2");
    user_pref("mail.accountmanager.defaultaccount", "account1");
    user_pref("mail.identity.id1.fullName", "Me Myself");
    user_pref("mail.identity.id1.useremail", "me@example.com");
    user_pref("mail.identity.id2.fullName", "Me Myself");
    user_pref("mail.identity.id2.useremail", "me@home.example");
    user_pref("mail.server.server1.directory-rel", "[ProfD]ImapMail/imap.example.com");
    user_pref("mail.server.server1.hostname", "imap.example.com");
    user_pref("mail.server.server1.type", "imap");
    user_pref("mail.server.server1.userName", "me@example.com");
    user_pref("mail.server.server2.directory-rel", "[ProfD]ImapMail/imap.example-1.com");
    user_pref("mail.server.server2.hostname", "imap.example.com");
    user_pref("mail.server.server2.type", "imap");
    user_pref("mail.server.server2.userName", "me@home.example");
  JS

  # Stored copies, headers only (the reply reads nothing else from the mbox).
  def mbox(*headers) = headers.map { "From - x\nX-Mozilla-Status: 0001\n#{_1}\n\nbody\n" }.join.gsub("\n", "\r\n")

  def work_mbox = mbox(<<~H.chomp, <<~H.chomp, <<~H.chomp, <<~H.chomp)
    Message-ID: <plan-3@lumo.example>
    From: Mira Koskinen <mira@lumo.example>
    To: Me Myself <me@example.com>
    Cc: ilse@example.com, ME@example.com
    References: <plan-1@lumo.example>
     <plan-2@example.com>
    In-Reply-To: <plan-2@example.com>
    Subject: Re: Plans
  H
    Message-ID: <mine@example.com>
    From: Me Myself <me@example.com>
    To: mira@lumo.example
    Subject: Plans
  H
    Message-ID: <phish@x>
    From: Bank <support@bank.example>
    Reply-To: support@xn--bnk-sna.example
    To: me@example.com
    Subject: Verify
  H
    Message-ID: <both@x>
    From: Ilse <ilse@example.com>
    To: me@home.example, me@example.com
    Subject: Both
  H

  def personal_mbox = mbox(<<~H.chomp)
    Message-ID: <ride@riders.example>
    From: Juha Salo <juha@riders.example>
    To: Helsinki Cycling <riders@list.example>
    Reply-To: Helsinki Cycling <riders@list.example>
    Subject: [riders] Sunday ride
  H

  def rec(id, folder, body: "Thursday?\n\nMira", subject: 'Plans', downloaded: true)
    { message_id: id, date: Time.new(2026, 11, 22, 14, 10), subject:, folder_uris: [folder], body:, downloaded: }
  end

  def recs = {
    'plan-3@lumo.example' => rec('plan-3@lumo.example', work),
    'mine@example.com' => rec('mine@example.com', work),
    'phish@x' => rec('phish@x', work, subject: 'Verify'),
    'both@x' => rec('both@x', work, subject: 'Both'),
    'ride@riders.example' => rec('ride@riders.example', personal, subject: '[riders] Sunday ride'),
    'gone@x' => rec('gone@x', work),
    'hdr@x' => rec('hdr@x', work, downloaded: false),
    'gloda:7' => rec('gloda:7', work)
  }

  def with_tool
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'prefs.js'), prefs)
      { 'imap.example.com' => work_mbox, 'imap.example-1.com' => personal_mbox }.each do |sub, bytes|
        FileUtils.mkdir_p(File.join(dir, 'ImapMail', sub))
        File.binwrite(File.join(dir, 'ImapMail', sub, 'INBOX'), bytes)
      end
      profile = Pikuri::Thunderbird::Profile.new(dir: dir, variant: :override)
      known = recs
      mail = Object.new
      mail.define_singleton_method(:read) { |message_id:| known[message_id] }
      @launched = []
      launched = @launched
      launcher = Object.new
      launcher.define_singleton_method(:launch) { |path| launched << path }
      yield described_class.new(mail:, store: Pikuri::Thunderbird::MessageStore.new(profile:), profile:, launcher:),
            File.join(dir, 'pikuri-outbox')
    end
  end

  # @return [Mail::Message] the draft staged by the last call.
  def draft = Mail.new(File.binread(@launched.last))

  it 'drafts a threaded reply to the sender, from the identity the mail reached, the original quoted' do
    with_tool do |tool, outbox|
      result = tool.run('message_id' => 'plan-3@lumo.example', 'body' => 'Thursday works.')

      assert_equal 'Reply handed to Thunderbird', result.summary
      assert_match(/Nothing has been sent/, result.to_s)
      assert_equal outbox, File.dirname(@launched.last)
      assert_match(/\.eml\z/, @launched.last)
      d = draft
      assert_equal ['me@example.com'], d.from
      assert_equal ['mira@lumo.example'], d.to
      assert_nil d.cc
      assert_equal 'Re: Plans', d.subject
      assert_equal '1', d['X-Unsent'].value
      assert_equal %w[plan-1@lumo.example plan-2@example.com plan-3@lumo.example], d.references
      assert_equal 'plan-3@lumo.example', d.in_reply_to
      assert_equal "Thursday works.\r\n\r\nOn 2026-11-22 14:10, Mira Koskinen wrote:\r\n> Thursday?\r\n>\r\n> Mira\r\n",
                   d.body.decoded.force_encoding('UTF-8')
    end
  end

  it 'adds the other recipients on reply_all, never the user' do
    with_tool do |tool, _|
      tool.run('message_id' => 'plan-3@lumo.example', 'body' => 'All good.', 'reply_all' => true)
      assert_equal ['mira@lumo.example'], draft.to
      assert_equal ['ilse@example.com'], draft.cc
    end
  end

  it 'answers a list mail at its Reply-To, from the account whose folder holds it' do
    with_tool do |tool, _|
      tool.run('message_id' => 'ride@riders.example', 'body' => 'Count me in.', 'reply_all' => true)
      assert_equal ['me@home.example'], draft.from
      assert_equal ['riders@list.example'], draft.to
      assert_nil draft.cc, 'the list is already the To'
      assert_equal 'Re: [riders] Sunday ride', draft.subject
    end
  end

  it 'answers from the first of the user\'s addresses the mail names, whatever folder holds it' do
    with_tool do |tool, _|
      tool.run('message_id' => 'both@x', 'body' => 'Got it.')
      assert_equal ['me@home.example'], draft.from
    end
  end

  it "refuses the user's own mail, and mail it can't answer from here, launching nothing" do
    with_tool do |tool, _|
      { 'mine@example.com' => /from the user/, 'hdr@x' => /only this message's headers/,
        'gloda:7' => /no Message-ID/, 'gone@x' => /no longer stored/, 'nope@x' => /no message found/ }.each do |id, why|
        out = tool.run('message_id' => id, 'body' => 'Hi').to_s
        assert_match(/\AError: /, out)
        assert_match(why, out)
      end
      assert_empty @launched
    end
  end

  it 'refuses a poisoned reply text, yet quotes the original verbatim, hidden bytes and all' do
    with_tool do |tool, _|
      assert_match(/\AError: /, tool.run('message_id' => 'plan-3@lumo.example', 'body' => "ok\u{202e}kcah").to_s)
      assert_empty @launched

      hostile = recs.merge('plan-3@lumo.example' => rec('plan-3@lumo.example', work, body: "Pay \u{202e}now"))
      tool.instance_variable_get(:@mail).define_singleton_method(:read) { |message_id:| hostile[message_id] }
      tool.run('message_id' => 'plan-3@lumo.example', 'body' => 'No.')
      assert_includes draft.body.decoded.force_encoding('UTF-8'), "> Pay \u{202e}now"
    end
  end

  it "drops a suspicious recipient for the user to type, without repeating the sender's address" do
    with_tool do |tool, _|
      out = tool.run('message_id' => 'phish@x', 'body' => 'Which account?').to_s
      assert_match(/To omitted/, out)
      refute_match(/xn--|bank\.example/, out)
      assert_nil draft.to
    end
  end
end
