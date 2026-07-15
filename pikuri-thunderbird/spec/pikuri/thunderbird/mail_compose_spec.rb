# frozen_string_literal: true

describe Pikuri::Thunderbird::MailCompose do
  # Capture the hand-off instead of spawning Thunderbird.
  def tool(seen: nil)
    @launched = []
    backend = seen && Class.new { define_method(:domains_seen) { |d| d & seen } }.new
    Pikuri::Thunderbird::MailCompose.new(backend: backend, launcher: ->(uri) { @launched << uri })
  end

  it 'hands off a mailto URI and returns the pre-send checklist' do
    out = tool(seen: ['acme.com']).run('to' => 'a@acme.com', 'subject' => 'Hi', 'body' => 'Hello')
    assert_equal 1, @launched.size
    assert_equal 'mailto:a@acme.com?subject=Hi&body=Hello', @launched.first
    assert_match(/Nothing has been sent/, out)
  end

  it 'refuses a poisoned body and launches nothing' do
    out = tool.run('to' => 'a@acme.com', 'body' => "hi\u{202e}kcah") # RLO reversal
    assert_empty @launched
    assert_match(/\AError: /, out)
  end

  it 'relays the recipient-novelty warning in the observation' do
    out = tool(seen: ['paypal.com']).run('to' => 'a@paypa1.com', 'body' => 'ok')
    assert_equal 1, @launched.size
    assert_match(/no prior mail with paypa1\.com/, out)
  end

  it 'still opens a window (empty To, body kept) when the recipient is dropped' do
    out = tool.run('to' => "a@m\u{ed}crosoft.com", 'body' => 'ok') # í look-alike
    assert_equal ['mailto:?body=ok'], @launched
    assert_match(/To omitted/, out)
  end

  it 'Errors when the Thunderbird binary cannot be found (real launcher)' do
    t = Pikuri::Thunderbird::MailCompose.new(thunderbird_bin: '/nonexistent/thunderbird-xyz')
    assert_match(/not found/, t.run('to' => 'a@acme.com', 'body' => 'ok'))
  end
end
