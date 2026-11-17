# frozen_string_literal: true

describe Pikuri::Thunderbird::Recurrence do
  Recurrence = Pikuri::Thunderbird::Recurrence

  def starts(start:, tz:, lines:, after:, before:, overridden: Set.new)
    Recurrence.new(start:, tz:, lines:, overridden:).starts(after:, before:)
  end

  it 'expands a weekly rule on the local weekday, DTSTART first even off-rule' do
    # The testbed's standup: DTSTART a Sunday, BYDAY Mon/Wed/Fri, 09:00 Helsinki.
    got = starts(start: Time.utc(2026, 11, 8, 7), tz: 'Europe/Helsinki',
                 lines: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR\r\n"],
                 after: Time.utc(2026, 11, 7), before: Time.utc(2026, 11, 13, 21, 59, 59))
    assert_equal [8, 9, 11, 13].map { |d| Time.utc(2026, 11, d, 7) }, got
  end

  it 'keeps the wall-clock time across a DST change' do
    # 09:00 Helsinki is 06:00 UTC in summer time, 07:00 UTC after 25 Oct 2026.
    got = starts(start: Time.utc(2026, 6, 1, 6), tz: 'Europe/Helsinki', lines: ['RRULE:FREQ=WEEKLY;BYDAY=MO'],
                 after: Time.utc(2026, 10, 15), before: Time.utc(2026, 10, 31))
    assert_equal [Time.utc(2026, 10, 19, 6), Time.utc(2026, 10, 26, 7)], got
  end

  it 'drops EXDATEs and occurrences stored as their own rows' do
    got = starts(start: Time.utc(2026, 6, 1, 6), tz: 'Europe/Helsinki',
                 lines: ['RRULE:FREQ=WEEKLY;BYDAY=MO', 'EXDATE;TZID=Europe/Helsinki:20261019T090000'],
                 overridden: Set[Time.utc(2026, 10, 26, 7).to_i],
                 after: Time.utc(2026, 10, 10), before: Time.utc(2026, 11, 4))
    assert_equal [Time.utc(2026, 10, 12, 6), Time.utc(2026, 11, 2, 7)], got
  end

  it 'expands an all-day rule and includes the whole day of a DATE UNTIL' do
    got = starts(start: Time.utc(2026, 11, 5), tz: 'floating',
                 lines: ['RRULE:FREQ=MONTHLY;BYMONTHDAY=5;UNTIL=20270205'],
                 after: Time.utc(2026, 12, 1), before: nil)
    assert_equal [Time.utc(2026, 12, 5), Time.utc(2027, 1, 5), Time.utc(2027, 2, 5)], got
  end

  it "reads UTC and other-zone dates in the event's own zone" do
    # 10:00 New York: 15:00 UTC until US DST starts on 8 Mar 2026, 14:00 after.
    got = starts(start: Time.utc(2026, 1, 5, 15), tz: 'America/New_York',
                 lines: ['RRULE:FREQ=WEEKLY;UNTIL=20260330T150000Z', 'EXDATE:20260309T140000Z',
                         'RDATE;TZID=Europe/Helsinki:20260402T170000'],
                 after: Time.utc(2026, 3, 1), before: Time.utc(2026, 4, 30))
    assert_equal [Time.utc(2026, 3, 2, 15), Time.utc(2026, 3, 16, 14), Time.utc(2026, 3, 23, 14),
                  Time.utc(2026, 3, 30, 14), Time.utc(2026, 4, 2, 14)], got
  end

  it 'expands at most MAX_SPAN past the window start' do
    got = starts(start: Time.utc(2020, 1, 1), tz: 'floating', lines: ['RRULE:FREQ=YEARLY'],
                 after: Time.utc(2026, 1, 1), before: Time.utc(2040, 1, 1))
    assert_equal [2026, 2027, 2028].map { |y| Time.utc(y, 1, 1) }, got # 731 days reach 2028-01-01
  end

  # A stranger's invitation can carry the rule, and ice_cube has no loop guard.
  it 'refuses what it cannot bound or read' do
    ['RRULE:FREQ=SECONDLY', 'RRULE:FREQ=DAILY;COUNT=5000', 'RRULE:FREQ=WEEKLY;BYDAY=XX',
     'EXRULE:FREQ=WEEKLY', 'EXDATE:tomorrow'].each do |line|
      assert_raises(Recurrence::Unexpandable, line) do
        starts(start: Time.utc(2026, 1, 1), tz: 'UTC', lines: [line], after: Time.utc(2026, 1, 1), before: nil)
      end
    end
    assert_raises(Recurrence::Unexpandable) do
      Recurrence.new(start: Time.utc(2026, 1, 1), tz: 'Mars/Olympus', lines: [], overridden: Set.new)
    end
  end
end
