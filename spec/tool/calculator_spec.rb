# frozen_string_literal: true

require 'tool'
require 'tool/calculator'

RSpec.describe Tool::Calculator do
  describe '.calculate' do
    it 'evaluates basic arithmetic with operator precedence' do
      assert_equal '11', described_class.calculate('5 + 3 * 2')
      assert_equal '16', described_class.calculate('(5 + 3) * 2')
    end

    it 'translates Python-style ** to Dentaku exponentiation' do
      assert_equal '1024', described_class.calculate('2**10')
    end

    it 'rounds BigDecimal results to 3 places, plain decimal' do
      # Exercises the float-division-by-default behavior and the
      # round(3).to_s('F') formatting path. Trailing zeros are stripped,
      # so 1/2 renders as "0.5" rather than "0.500".
      assert_equal '0.5', described_class.calculate('1 / 2')
      assert_equal '9.621', described_class.calculate('155 / (58 * 1000.0 / 3600)')
    end

    it 'returns an Error: string for parse failures rather than raising' do
      result = described_class.calculate('5 + + +')
      assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
    end

    it 'returns "Error: division by zero" for zero division' do
      assert_equal 'Error: division by zero', described_class.calculate('1 / 0')
    end
  end
end
