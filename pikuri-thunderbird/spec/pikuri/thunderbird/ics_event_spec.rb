# frozen_string_literal: true

require 'stringio'
require 'time'

describe Pikuri::Thunderbird::IcsEvent do
  Ics = Pikuri::Thunderbird::IcsEvent

  # Pin the zone so getlocal (all-day dates) and local→UTC (timed) are stable.
  around do |ex|
    old = ENV['TZ']
    ENV['TZ'] = 'UTC'
    ex.run
    ENV['TZ'] = old
  end

  def build(**kw)
    Ics.build(uid: 'fixed@pikuri', dtstamp: Time.utc(2026, 1, 1, 0, 0, 0), **kw)
  end

  it 'wraps one VEVENT in a VCALENDAR with CRLF line endings' do
    out = build(title: 'Q2 review', start: Time.parse('2026-07-20 14:00'))
    assert_match(/\ABEGIN:VCALENDAR\r\n/, out)
    assert_match(/BEGIN:VEVENT\r\n/, out)
    assert_equal 1, out.scan('BEGIN:VEVENT').size
    assert_match(/END:VCALENDAR\r\n\z/, out)
  end

  it 'emits a timed event as UTC, defaulting DTEND to start + 1h' do
    out = build(title: 'x', start: Time.parse('2026-07-20 14:00'))
    assert_match(/^DTSTART:20260720T140000Z\r$/, out)
    assert_match(/^DTEND:20260720T150000Z\r$/, out)
  end

  it 'honors an explicit end time' do
    out = build(title: 'x', start: Time.parse('2026-07-20 14:00'), finish: Time.parse('2026-07-20 16:30'))
    assert_match(/^DTEND:20260720T163000Z\r$/, out)
  end

  it 'emits an all-day event as VALUE=DATE with an exclusive next-day DTEND' do
    out = build(title: 'Holiday', start: Time.parse('2026-07-20'), all_day: true)
    assert_match(/^DTSTART;VALUE=DATE:20260720\r$/, out)
    assert_match(/^DTEND;VALUE=DATE:20260721\r$/, out) # single day → +1
  end

  it 'treats an all-day end as the inclusive last day (DTEND = last + 1)' do
    out = build(title: 'Trip', start: Time.parse('2026-07-20'), finish: Time.parse('2026-07-22'), all_day: true)
    assert_match(/^DTEND;VALUE=DATE:20260723\r$/, out)
  end

  it 'escapes commas, semicolons, backslashes and newlines in text (injection defense)' do
    out = build(title: 'a,b;c\\d', start: Time.parse('2026-07-20 14:00'),
                description: "line1\nline2")
    assert_match(/^SUMMARY:a\\,b\\;c\\\\d\r$/, out)
    assert_match(/^DESCRIPTION:line1\\nline2\r$/, out)
  end

  it 'cannot inject a second property via a smuggled newline' do
    out = build(title: "Meeting\r\nATTENDEE:mailto:evil@x.com", start: Time.parse('2026-07-20 14:00'))
    refute_match(/^ATTENDEE:/, out)
    assert_match(/^SUMMARY:Meeting\\nATTENDEE:mailto:evil@x.com\r$/, out)
  end

  it 'strips raw control bytes' do
    out = build(title: "a\x07b\x00c", start: Time.parse('2026-07-20 14:00'))
    assert_match(/^SUMMARY:abc\r$/, out)
  end

  # The one non-ASCII example, and it asserts content *and* silence together on
  # purpose: Ruby emits the /n-vs-UTF-8 warning once per Regexp object, so a
  # separate accented example would burn it and let a regressed escape() slip
  # past the stderr guard. Nothing else in this gem's specs builds an ICS with
  # non-ASCII text, so this is the first — and only — build that could warn.
  it 'passes non-ASCII text through verbatim, with no interpreter warning' do
    prior = $stderr
    $stderr = StringIO.new
    begin
      out = build(title: 'Stretnutie s Máriou', start: Time.parse('2026-07-20 14:00'),
                  location: "Zasadačka č.\x013")
      captured = $stderr.string
    ensure
      $stderr = prior
    end

    assert_match(/^SUMMARY:Stretnutie s Máriou\r$/, out)
    assert_match(/^LOCATION:Zasadačka č.3\r$/, out)
    assert_equal Encoding::UTF_8, out.encoding
    # A /n-flagged regexp meeting a UTF-8 string warns straight to the raw
    # $stderr, which lands on a TUI's screen instead of in its log window.
    assert_equal '', captured
  end

  it 'omits LOCATION and DESCRIPTION when blank' do
    out = build(title: 'x', start: Time.parse('2026-07-20 14:00'), location: '  ', description: nil)
    refute_match(/^LOCATION:/, out)
    refute_match(/^DESCRIPTION:/, out)
  end
end
