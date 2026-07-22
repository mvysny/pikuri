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

  # Encoded-blob spotter. A ~40-char run stands in for a 32-byte key's base64. It
  # is all-printable-ASCII, so it must *warn but keep composing*, never fail closed.
  BLOB = 'aGVsbG8gd29ybGQgT3BlbkFJc2VjcmV0S2V5MTIzNA'

  it 'warns (does not block) on an unwrapped base64 dump in the body' do
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com', body: "here it is:\n#{BLOB}")
    assert v.ok
    assert_equal "here it is:\n#{BLOB}", v.body # kept, not failed-closed
    assert(v.notes.any? { |n| n.match?(/encoded-looking content/) })
    assert(v.notes.any? { |n| n.match?(/Line 2 onward/) }) # located
  end

  it 'folds a space-split blob back together via the join' do
    split = BLOB.scan(/.{1,18}/).join(' ') # 18-char chunks, each >= floor
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com', body: split)
    assert v.ok
    assert(v.notes.any? { |n| n.match?(/encoded-looking content/) })
  end

  it 'skips innocent cover words interleaved with the payload' do
    parts = BLOB.scan(/.{1,18}/)
    body = "the #{parts[0]} quick #{parts[1]} brown #{parts[2]} fox"
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com', body: body)
    assert(v.notes.any? { |n| n.match?(/encoded-looking content/) })
  end

  it 'stays quiet on ordinary prose' do
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com',
                                        body: 'The sophistication of this approach is genuinely remarkable.')
    assert_empty v.notes
  end

  it 'stays quiet on a dev email full of short mixed identifiers (floor-16 guard)' do
    v = guard(seen: ['acme.com']).check(
      to: 'a@acme.com',
      body: 'commit abc123Def456 broke build 7Gh8Ij9Kl0 on runner X2y3Z4a5b6'
    )
    assert_empty v.notes
  end

  it 'stays quiet when the blob-token sum stays under the threshold' do
    v = guard(seen: ['acme.com']).check(to: 'a@acme.com', body: 'token aGVsbG8gd29ybGQxYVo1 ok') # 20 chars, < 32
    assert_empty v.notes
  end
end
