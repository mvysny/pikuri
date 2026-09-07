# frozen_string_literal: true

module Pikuri
  class Tool
    # Evaluates a basic arithmetic expression with Python operator syntax and
    # semantics, via the hand-rolled recursive-descent {Parser} below. A
    # great-circle distance, the call that motivated {FUNCTIONS}:
    #
    #   Calculator.calculate('6371 * acos(sin(radians(60.1699)) * sin(radians(41.3874)) + ' \
    #                        'cos(radians(60.1699)) * cos(radians(41.3874)) * ' \
    #                        'cos(radians(2.1734) - radians(24.9410)))')   # => "2603.339"
    #
    # Scope is intentionally narrow: operators (+, -, *, /, //, %, **), unary
    # minus, parentheses, numeric literals, and the fixed-arity real functions
    # and constants in {FUNCTIONS} / {CONSTANTS}. No variables, sequences,
    # assignment or comparisons — every name is spelled the way Python spells
    # it rather than as a pikuri dialect. See +DECISIONS.md+
    # +D_calculator_functions+.
    #
    # Hand-rolled rather than a gem: the previous backend (dentaku) pulled in
    # concurrent-ruby (~16k lines — pikuri's single heaviest audit item) plus
    # bigdecimal and tsort just for four-function arithmetic. The parser here
    # implements Python's grammar directly, which also retires the old
    # +**+→+^+ preprocessing (the model's native syntax is now the grammar).
    module Calculator
      # Raised internally for anything {.calculate} should return as an
      # +"Error: ..."+ observation rather than crash the loop. Names the
      # offending token, operands or call.
      class Error < StandardError; end

      # The callable names, as +name => [permitted argument counts, callable]+.
      # Every entry is pure, fixed-arity and real→real: that shape *is* the
      # closed surface, so a new entry has to fit it. Trigonometry is in
      # radians, as Python's is — +radians+ / +degrees+ are here because the
      # conversion is otherwise unexpressible, and a model that feeds degrees
      # to +sin+ gets a plausible wrong answer rather than an error.
      #
      # @return [Hash{String => Array(Range, #call)}]
      FUNCTIONS = {
        'sin' => [1..1, Math.method(:sin)],
        'cos' => [1..1, Math.method(:cos)],
        'tan' => [1..1, Math.method(:tan)],
        'asin' => [1..1, Math.method(:asin)],
        'acos' => [1..1, Math.method(:acos)],
        'atan' => [1..1, Math.method(:atan)],
        'atan2' => [2..2, Math.method(:atan2)],
        'hypot' => [2..2, Math.method(:hypot)],
        'sqrt' => [1..1, Math.method(:sqrt)],
        'exp' => [1..1, Math.method(:exp)],
        'log' => [1..2, Math.method(:log)], # log(x) is natural; log(x, base) is Python's second form
        'log10' => [1..1, Math.method(:log10)],
        'log2' => [1..1, Math.method(:log2)],
        'floor' => [1..1, ->(x) { x.floor }],
        'ceil' => [1..1, ->(x) { x.ceil }],
        'abs' => [1..1, ->(x) { x.abs }],
        'radians' => [1..1, ->(deg) { deg * Math::PI / 180 }],
        'degrees' => [1..1, ->(rad) { rad * 180 / Math::PI }]
      }.freeze

      # The names that evaluate to a number with no call syntax.
      #
      # @return [Hash{String => Float}]
      CONSTANTS = { 'pi' => Math::PI, 'e' => Math::E }.freeze

      # Evaluate +expression+ and return the result as a String. Parse and
      # arithmetic failures (division by zero, overflow to infinity, complex
      # results, a function outside its domain) come back as +"Error: ..."+ so
      # the model self-corrects.
      #
      # @param expression [String] Python-syntax arithmetic expression
      # @return [String] numeric result, or +"Error: ..."+ on failure
      def self.calculate(expression)
        result = Parser.new(expression).parse
        if result.is_a?(Float) && !result.finite?
          raise Error, "result of #{expression.inspect} is not a finite number"
        end

        format_result(result)
      rescue Error => e
        "Error: #{e.message}"
      end

      # Integers pass through exact (division never produces them — +/+ is
      # Python-3 true division). Floats round to 3 places, and whole-valued
      # floats drop the +.0+ (+4 / 2+ → +"2"+).
      def self.format_result(result)
        return result.to_s if result.is_a?(Integer)

        rounded = result.round(3)
        rounded == rounded.truncate ? rounded.truncate.to_s : rounded.to_s
      end
      private_class_method :format_result

      # Recursive-descent parser-evaluator for Python's arithmetic grammar:
      #
      #   additive       := multiplicative (('+' | '-') multiplicative)*
      #   multiplicative := unary (('*' | '/' | '//' | '%') unary)*
      #   unary          := ('+' | '-') unary | power
      #   power          := atom ('**' unary)?
      #   atom           := NUMBER | NAME '(' additive (',' additive)* ')'
      #                   | NAME | '(' additive ')'
      #
      # The +power+→+unary+ recursion on the right operand makes +**+
      # right-associative (+2**3**2+ is 512) and lets a sign follow it
      # (+2**-3+); +unary+ *above* +power+ on the left makes +-2**2+ evaluate to
      # -4 — both as Python parses them.
      #
      # Semantics follow Python 3 where Ruby differs: +/+ is always true (float)
      # division, +//+ floors, +2**-1+ is Float 0.5 (not a Rational), and a
      # negative base under a fractional exponent is rejected (not a Complex).
      class Parser
        # One number, name or operator. +**+/+//+ listed before their
        # single-char prefixes so the two-char operators win; number literals
        # cover +42+, +4.2+, +5.+, +.5+, and e-notation; a name carries an
        # optional +math.+ / +Math.+ qualifier as part of the token, so
        # +math.cos+ and a bare +cos+ both parse. +\G+ anchors each match at
        # the scan position so nothing between tokens is missed.
        TOKEN_RE = %r{\G\s*(\*\*|//|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?|(?:[Mm]ath\.)?[A-Za-z_]\w*|[-+*/%(),])}

        # Tail of every unknown-name error: the tool description lists the same
        # set, but a small model recovers from the error string on the next
        # turn instead of guessing a second name.
        AVAILABLE = "available functions: #{FUNCTIONS.keys.join(', ')}; " \
                    "constants: #{CONSTANTS.keys.join(', ')}"

        # @param expression [String] raw expression as the model wrote it
        # @raise [Error] when +expression+ contains a character no token matches
        def initialize(expression)
          @tokens = tokenize(expression)
          @pos = 0
        end

        # Parse and evaluate the whole token stream.
        #
        # @return [Integer, Float] the value of the expression
        # @raise [Error] on syntax errors, division by zero, or a complex result
        def parse
          value = additive
          raise Error, "unexpected #{peek.inspect} after expression" if peek

          value
        end

        private

        # @param expression [String]
        # @return [Array<String>] token strings in source order
        def tokenize(expression)
          tokens = []
          pos = 0
          while (match = TOKEN_RE.match(expression, pos))
            tokens << match[1]
            pos = match.end(0)
          end
          rest = expression[pos..].to_s.strip
          raise Error, "unexpected character #{rest[0].inspect} in #{expression.inspect}" unless rest.empty?

          tokens
        end

        def additive
          value = multiplicative
          while (op = accept('+', '-'))
            rhs = multiplicative
            value = op == '+' ? value + rhs : value - rhs
          end
          value
        end

        def multiplicative
          value = unary
          while (op = accept('*', '/', '//', '%'))
            value = apply_multiplicative(op, value, unary)
          end
          value
        end

        def unary
          op = accept('+', '-')
          return power unless op

          value = unary
          op == '-' ? -value : value
        end

        def power
          base = atom
          return base unless accept('**')

          apply_power(base, unary)
        end

        def atom
          return parenthesized if accept('(')

          case (token = peek)
          when nil then raise Error, 'unexpected end of expression'
          when /\A[.\d]/
            @pos += 1
            token.match?(/[.eE]/) ? token.to_f : token.to_i
          when /\A[A-Za-z_]/
            @pos += 1
            named(token)
          else raise Error, "unexpected #{token.inspect}"
          end
        end

        def parenthesized
          value = additive
          raise Error, 'missing closing parenthesis' unless accept(')')

          value
        end

        # A function call if a +(+ follows, a constant otherwise.
        def named(token)
          name = token.sub(/\A[Mm]ath\./, '')
          return apply_function(name, arguments) if accept('(')
          return CONSTANTS[name] if CONSTANTS.key?(name)
          raise Error, "#{name} takes arguments; write #{name}(x)" if FUNCTIONS.key?(name)

          raise Error, "unknown name #{token.inspect}; #{AVAILABLE}"
        end

        # The argument list of a call, positioned just past the opening +(+.
        #
        # @return [Array<Integer, Float>] one or more evaluated arguments
        def arguments
          args = [additive]
          args << additive while accept(',')
          raise Error, 'missing closing parenthesis' unless accept(')')

          args
        end

        # +Math+ raises +DomainError+ where Python's +math+ raises +ValueError+
        # (+acos(1.0000000001)+, reachable from real haversine rounding), and
        # +floor+/+ceil+ raise +FloatDomainError+ on an infinite argument.
        # Both are the model's error to see, not the loop's to die on.
        def apply_function(name, args)
          arities, callable = FUNCTIONS.fetch(name) { raise Error, "unknown function #{name.inspect}; #{AVAILABLE}" }
          unless arities.cover?(args.size)
            raise Error, "#{name} takes #{arities.to_a.join(' or ')} argument(s), got #{args.size}"
          end

          callable.call(*args)
        rescue Math::DomainError, FloatDomainError
          raise Error, "#{name}(#{args.join(', ')}) is undefined"
        end

        # @return [String, nil] the next token without consuming it
        def peek
          @tokens[@pos]
        end

        # Consume and return the next token if it is one of +expected+.
        #
        # @return [String, nil] the consumed token, or nil on no match
        def accept(*expected)
          token = peek
          return nil unless expected.include?(token)

          @pos += 1
          token
        end

        # +/+ is Python-3 true division (always Float); +//+ floors (Ruby's
        # +Integer#/+ already floors like Python's +//+ for two Integers); +%+
        # delegates to Ruby's +%+, whose sign-of-divisor matches Python's.
        def apply_multiplicative(op, lhs, rhs)
          return lhs * rhs if op == '*'
          raise Error, 'division by zero' if rhs.zero?

          case op
          when '/' then lhs.fdiv(rhs)
          when '//' then lhs.is_a?(Integer) && rhs.is_a?(Integer) ? lhs / rhs : lhs.fdiv(rhs).floor
          when '%' then lhs % rhs
          end
        end

        # Two Python-compat shims over Ruby's +**+: an Integer to a negative
        # Integer yields a Float (Ruby → Rational), and a Complex result
        # (negative base, fractional exponent) is rejected loudly.
        def apply_power(base, exponent)
          if base.is_a?(Integer) && exponent.is_a?(Integer) && exponent.negative?
            raise Error, 'division by zero' if base.zero?

            return base.to_f**exponent
          end
          result = base**exponent
          if result.is_a?(Complex)
            raise Error, "(#{base})**(#{exponent}) is a complex number; only real arithmetic is supported"
          end

          result
        end
      end
    end

    # Arithmetic-evaluation tool backed by {Tool::Calculator.calculate}. Accepts
    # Python expression syntax (+, -, *, /, //, %, **, unary minus, parentheses,
    # decimals) plus {Tool::Calculator::FUNCTIONS} / {Tool::Calculator::CONSTANTS},
    # so the model emits syntax it already knows.
    #
    # Stays wired even in shells that have +bash+: it is the only *unconfirmed*
    # float arithmetic there, since a shell's own +$((…))+ is integer-only and
    # every interpreter that isn't must stay off the passive allowlist. See
    # +DECISIONS.md+ +D_keep_calculator+.
    #
    # Sharing: +P_stateless+ — arithmetic over the argument, no I/O, no state.
    # Hand this one constant to every agent in the VM.
    #
    # @return [Tool]
    CALCULATOR = new(
      name: 'calculator',
      description: <<~DESC,
        Evaluates a basic arithmetic expression and returns the numeric result.

        Usage:
        - Use this for any arithmetic beyond simple mental math — do not eyeball multi-digit work.
        - Decimal results are rounded to 3 places; integer results are exact.
      DESC
      parameters: Parameters.build { |p|
        p.required_string :expression,
                          'Arithmetic expression in Python syntax: + - * ' \
                          '/ (true division), // (floor division), % (modulo), ' \
                          '** (exponentiation), unary minus, parentheses, ' \
                          'decimals. Also these functions, with or without a ' \
                          'math. prefix: sin cos tan asin acos atan atan2 ' \
                          'hypot sqrt exp log (log(x) natural, log(x, base) ' \
                          'for another base) log10 log2 floor ceil abs ' \
                          'radians degrees, and the constants pi and e. ' \
                          'Trigonometric functions take RADIANS, so convert ' \
                          'degrees first: sin(radians(30)), never sin(30). ' \
                          'E.g. "155 / (58 * 1000.0 / 3600)", "2**10", or ' \
                          '"hypot(3, 4)".'
      },
      execute: ->(expression:) { Calculator.calculate(expression) },
      # No legs: pure arithmetic over the argument, no I/O of any kind.
      trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
    )
  end
end
