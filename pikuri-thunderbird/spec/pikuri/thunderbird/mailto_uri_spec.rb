# frozen_string_literal: true

describe Pikuri::Thunderbird::MailtoUri do
  Uri = Pikuri::Thunderbird::MailtoUri

  it 'keeps @ literal in the recipient and needs no query for a bare to' do
    assert_equal 'mailto:a@x.com', Uri.build(to: ['a@x.com'])
  end

  it 'percent-encodes structural characters and newlines in the body' do
    uri = Uri.build(to: ['a@x.com'], subject: 'Re: hi', body: "Line 1\nB & C?")
    # Conservative: everything outside the address-safe set is encoded (`:`→%3A
    # too), so nothing structural can slip through; Thunderbird decodes it back.
    assert_equal 'mailto:a@x.com?subject=Re%3A%20hi&body=Line%201%0AB%20%26%20C%3F', uri
  end

  it 'structurally defuses a body that tries to smuggle a bcc' do
    uri = Uri.build(to: ['a@x.com'], body: 'hi&bcc=evil@attacker.com')
    # The injected &bcc= is encoded, so it is body text, not a real header.
    refute_match(/&bcc=evil/, uri)
    assert_match(/%26bcc%3Devil/, uri)
  end

  it 'joins multiple recipients with a literal comma, each encoded' do
    uri = Uri.build(to: ['a@x.com', 'b@y.com'], cc: ['c@z.com'])
    assert_equal 'mailto:a@x.com,b@y.com?cc=c@z.com', uri
  end

  it 'encodes a multibyte body byte-wise' do
    uri = Uri.build(to: ['a@x.com'], body: 'café')
    assert_equal 'mailto:a@x.com?body=caf%C3%A9', uri
  end
end
