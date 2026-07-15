# frozen_string_literal: true

describe Pikuri::Thunderbird::ComposeGuard do
  Guard = Pikuri::Thunderbird::ComposeGuard

  # Minimal Gloda stand-in for the novelty check.
  class FakeBackend
    def initialize(seen) = @seen = seen
    def domains_seen(domains) = domains & @seen
  end

  def guard(seen: nil) = Guard.new(backend: seen && FakeBackend.new(seen))

  it 'passes a clean single-recipient message through' do
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com', subject: 'Hi', body: 'Hello Alice')
    assert v.ok
    assert_equal ['a@acme.com'], v.to
    assert_equal 'Hi', v.subject
    assert_equal 'Hello Alice', v.body
    assert_empty v.notes
  end

  it 'fails closed on a body carrying a bidi-override byte' do
    v = guard.check(to: 'a@acme.com', body: "ship it\u{202e}kcah") # RLO reversal
    refute v.ok
    assert_match(/no honest reason/, v.error)
    assert_nil v.body
  end

  it 'drops a subject with suspicious characters but keeps composing' do
    v = guard.check(to: 'a@acme.com', subject: "Re:\u{200b}hi", body: 'ok') # zero-width space
    assert v.ok
    assert_nil v.subject
    assert(v.notes.any? { |n| n.match?(/Subject omitted/) })
  end

  it 'drops a non-ASCII (look-alike) recipient field for retyping' do
    v = guard.check(to: "a@m\u{ed}crosoft.com", body: 'ok') # í look-alike for i
    assert v.ok
    assert_empty v.to
    assert(v.notes.any? { |n| n.match?(/To omitted/) })
  end

  it 'rejects a pre-encoded punycode homoglyph domain' do
    v = guard.check(to: 'a@xn--80ak6aa92e.com', body: 'ok')
    assert_empty v.to
    assert(v.notes.any? { |n| n.match?(/To omitted/) })
  end

  it 'drops the whole field when any one address is bad' do
    v = guard.check(to: 'good@acme.com, a@mícrosoft.com', body: 'ok')
    assert_empty v.to
  end

  it 'warns (does not block) on a recipient domain never corresponded with' do
    v = guard(seen: ['paypal.com']).check(to: 'a@paypa1.com', body: 'ok')
    assert v.ok
    assert_equal ['a@paypa1.com'], v.to
    assert(v.notes.any? { |n| n.match?(/no prior mail with paypa1\.com/) })
  end

  it 'stays quiet for a domain already in the correspondence graph' do
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com', body: 'ok')
    assert_empty v.notes
  end

  it 'notes that novelty could not be checked without a backend' do
    v = guard.check(to: 'a@acme.com', body: 'ok')
    assert(v.notes.any? { |n| n.match?(/Couldn't check/) })
  end
end
