# frozen_string_literal: true

describe Pikuri::Thunderbird::ReplyDraft do
  def me = Pikuri::Thunderbird::Accounts::Identity.new(email: 'alex@novak.example', name: 'Alex Nováková')

  def build(**over)
    described_class.build(from: me, to: ['mira@lumo.example'], cc: [], subject: 'Re: Plans',
                          thread: %w[p1@lumo.example p2@novak.example], body: "Works.\n\n> quoted", **over)
  end

  def header(eml) = eml.split("\r\n\r\n", 2).first
  def field_names(eml) = header(eml).scan(/^([\w-]+):/).flatten

  it 'writes an X-Unsent draft with only its own headers and a base64 body' do
    eml = build
    assert_equal %w[From To In-Reply-To References Subject X-Unsent MIME-Version Content-Type
                    Content-Transfer-Encoding], field_names(eml)
    assert_match(/^From: =\?UTF-8\?B\?.+\?= <alex@novak\.example>\r$/, header(eml))
    assert_match(/^In-Reply-To: <p2@novak\.example>\r$/, header(eml))
    assert_equal %w[p1@lumo.example p2@novak.example], header(eml)[/^References:.*?(?=^\S)/m].scan(/<([^>]+)>/).flatten
    assert_equal "Works.\r\n\r\n> quoted", eml.split("\r\n\r\n", 2).last.unpack1('m').force_encoding('UTF-8')
    refute_match(/(?<!\r)\n/, eml, 'CRLF throughout')
  end

  it 'parses back as the reply it describes' do
    mail = Mail.new(build(cc: ['ilse@novak.example']))
    assert_equal ['alex@novak.example'], mail.from
    assert_equal ['ilse@novak.example'], mail.cc
    assert_equal 'Re: Plans', mail.subject
    assert_equal 'Works.', mail.body.decoded.lines.first.chomp
  end

  it "can't be made to open a header of its own through the subject" do
    eml = build(subject: "Re: Hi\r\nBcc: exfil@evil.example")
    refute_includes field_names(eml), 'Bcc'
    assert_equal 'Re: Hi  Bcc: exfil@evil.example', Mail.new(eml).subject
  end

  it 'drops a malformed Message-ID and keeps the first and latest of a long chain' do
    eml = build(thread: ["evil\r\nBcc: x@evil.example", 'no-at-sign', '<bracketed@x>', 'ok@x'])
    assert_equal ['ok@x'], header(eml)[/^References:.*?(?=^\S)/m].scan(/<([^>]+)>/).flatten

    chain = (1..30).map { "m#{_1}@x" }
    refs = header(build(thread: chain))[/^References:.*?(?=^\S)/m].scan(/<([^>]+)>/).flatten
    assert_equal ['m1@x', *(12..30).map { "m#{_1}@x" }], refs
  end

  it 'omits From, Cc and threading when there are none' do
    eml = build(from: nil, thread: [])
    assert_equal %w[To Subject X-Unsent MIME-Version Content-Type Content-Transfer-Encoding], field_names(eml)
  end

  describe '.quote' do
    it 'attributes and prefixes every line, an empty one with a bare >' do
      quote = described_class.quote(text: "Hi Alex,\n\nThursday?  \n", author: "Mira\nKoskinen", date: Time.new(2026, 11, 22, 14, 10))
      assert_equal "On 2026-11-22 14:10, Mira Koskinen wrote:\n> Hi Alex,\n>\n> Thursday?", quote
    end

    it 'ends a text Gloda cut with a marker' do
      text = 'x' * Pikuri::Thunderbird::MailRead::GLODA_PART_CAP
      assert described_class.quote(text:, author: 'A', date: nil).end_with?("\n> […]")
    end
  end
end
