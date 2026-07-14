# frozen_string_literal: true

describe Pikuri::Thunderbird::Format do
  Format = Pikuri::Thunderbird::Format

  describe 'date-range bounds' do
    it 'treats a bare date as the START of the day for the after bound' do
      after = Format.parse_after('2026-07-15')
      assert_equal 0, after.hour
      assert_equal 0, after.min
    end

    it 'treats a bare date as the END of the day for the before bound' do
      after = Format.parse_after('2026-07-15')
      before = Format.parse_before('2026-07-15')
      # same-day window spans the whole day, not the single midnight instant
      assert_equal 86_399, (before - after).to_i
    end

    it 'uses an explicit datetime verbatim (no end-of-day extension)' do
      t = Format.parse_before('2026-07-15 14:30')
      assert_equal 14, t.hour
      assert_equal 30, t.min
    end

    it 'returns nil for blank bounds' do
      assert_nil Format.parse_after(nil)
      assert_nil Format.parse_before('')
    end

    it 'raises on an unparseable date' do
      assert_raises(ArgumentError) { Format.parse_after('not-a-date') }
    end
  end
end
