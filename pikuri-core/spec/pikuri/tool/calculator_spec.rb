# frozen_string_literal: true

RSpec.describe Pikuri::Tool::Calculator do
  describe '.calculate' do
    it 'evaluates basic arithmetic with operator precedence' do
      assert_equal '11', described_class.calculate('5 + 3 * 2')
      assert_equal '16', described_class.calculate('(5 + 3) * 2')
      assert_equal '18', described_class.calculate('2 * 3 ** 2')
    end

    it 'keeps integer arithmetic exact at arbitrary precision' do
      assert_equal '1024', described_class.calculate('2**10')
      assert_equal '18446744073709551616', described_class.calculate('2**64')
    end

    it 'follows Python ** semantics: right-associative, looser than unary minus' do
      assert_equal '512', described_class.calculate('2**3**2')
      assert_equal '-4', described_class.calculate('-2**2')
      assert_equal '4', described_class.calculate('(-2)**2')
      assert_equal '0.5', described_class.calculate('2**-1')
    end

    it 'treats / as Python true division, // as floor division' do
      assert_equal '0.5', described_class.calculate('1 / 2')
      assert_equal '3', described_class.calculate('7 // 2')
      assert_equal '-4', described_class.calculate('-7 // 2')
      assert_equal '3', described_class.calculate('7.5 // 2')
    end

    it 'follows Python sign semantics for modulo' do
      assert_equal '2', described_class.calculate('-7 % 3')
      assert_equal '1.5', described_class.calculate('5.5 % 2')
    end

    it 'handles unary signs and e-notation literals' do
      assert_equal '-2', described_class.calculate('-5 + 3')
      assert_equal '8', described_class.calculate('5 - -3')
      assert_equal '1500', described_class.calculate('1.5e3')
      assert_equal '0.5', described_class.calculate('.5')
    end

    it 'rounds decimal results to 3 places, plain decimal' do
      # Trailing zeros are stripped, so 1/2 renders as "0.5" rather
      # than "0.500", and whole-valued floats drop the ".0".
      assert_equal '0.5', described_class.calculate('1 / 2')
      assert_equal '9.621', described_class.calculate('155 / (58 * 1000.0 / 3600)')
      assert_equal '2', described_class.calculate('4 / 2')
      assert_equal '0.333', described_class.calculate('1 / 3')
    end

    it 'returns an Error: string for parse failures rather than raising' do
      ['5 + + +', 'two plus two', '(1 + 2', '1 + 2)', ''].each do |expression|
        result = described_class.calculate(expression)
        assert result.start_with?('Error:'),
               "expected error string for #{expression.inspect}, got #{result.inspect}"
      end
    end

    it 'returns "Error: division by zero" for zero division in /, //, and %' do
      assert_equal 'Error: division by zero', described_class.calculate('1 / 0')
      assert_equal 'Error: division by zero', described_class.calculate('1 // 0')
      assert_equal 'Error: division by zero', described_class.calculate('1 % 0')
      assert_equal 'Error: division by zero', described_class.calculate('0**-1')
    end

    it 'returns an Error: string for complex and non-finite results' do
      result = described_class.calculate('(-4) ** 0.5')
      assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
      result = described_class.calculate('2.0 ** 10000')
      assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
    end
  end
end
