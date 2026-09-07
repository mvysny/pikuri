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

    it 'evaluates functions and constants, bare or math.-qualified' do
      assert_equal '2', described_class.calculate('sqrt(4)')
      assert_equal '2', described_class.calculate('math.sqrt(4)')
      assert_equal '2', described_class.calculate('Math.sqrt(4)')
      assert_equal '3.142', described_class.calculate('pi')
      assert_equal '3.142', described_class.calculate('math.pi')
      assert_equal '5', described_class.calculate('hypot(3, 4)')
      assert_equal '1', described_class.calculate('sin(radians(90))')
    end

    it 'takes radians in trigonometry, as Python does' do
      # A haversine over Helsinki–Barcelona. Passing the degrees straight in
      # (the shape a model reaches for) yields 11953.814 — plausible garbage —
      # so radians() is what makes the function set usable rather than a trap.
      expression = '6371 * acos(sin(radians(60.1699)) * sin(radians(41.3874)) + ' \
                   'cos(radians(60.1699)) * cos(radians(41.3874)) * ' \
                   'cos(radians(2.1734) - radians(24.9410)))'
      assert_equal '2603.339', described_class.calculate(expression)
      assert_equal '90', described_class.calculate('degrees(pi / 2)')
    end

    it 'composes functions with the operator grammar' do
      assert_equal '4', described_class.calculate('sqrt(4)**2')
      assert_equal '4', described_class.calculate('2**sqrt(4)')
      assert_equal '-2', described_class.calculate('-sqrt(4)')
      assert_equal '5', described_class.calculate('abs(floor(-4.2))')
      assert_equal '3', described_class.calculate('log(8, 2)')
      assert_equal '2.079', described_class.calculate('log(8)')
    end

    it 'returns an Error: string for a name outside the fixed surface' do
      # Nothing here is a dialect to guess at: no variables, no sequences.
      ['sqrt', 'cbrt(8)', 'foo(1)', 'x + 1', 'sum(1, 2)', 'min(1, 2)'].each do |expression|
        result = described_class.calculate(expression)
        assert result.start_with?('Error:'),
               "expected error string for #{expression.inspect}, got #{result.inspect}"
      end
    end

    it 'names the available functions in an unknown-name error' do
      # The recovery path for a small model: the next turn should not need a
      # second guess at what this calculator calls things.
      result = described_class.calculate('cbrt(8)')
      assert_includes result, 'sqrt'
      assert_includes result, 'constants: pi, e'
      assert_equal 'Error: sqrt takes arguments; write sqrt(x)', described_class.calculate('sqrt')
    end

    it 'returns an Error: string for wrong arity and out-of-domain arguments' do
      assert_equal 'Error: sqrt takes 1 argument(s), got 2', described_class.calculate('sqrt(4, 5)')
      assert_equal 'Error: atan2 takes 2 argument(s), got 1', described_class.calculate('atan2(1)')
      assert_equal 'Error: log takes 1 or 2 argument(s), got 3', described_class.calculate('log(1, 2, 3)')
      # acos just past 1.0 is reachable from real haversine rounding, and
      # floor of an infinity raises a different Ruby error on the same path.
      assert_equal 'Error: acos(1.0000000001) is undefined', described_class.calculate('acos(1.0000000001)')
      assert_equal 'Error: sqrt(-1) is undefined', described_class.calculate('sqrt(-1)')
      assert described_class.calculate('floor(2.0**10000)').start_with?('Error:')
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
