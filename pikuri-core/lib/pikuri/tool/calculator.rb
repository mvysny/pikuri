# frozen_string_literal: true

module Pikuri
  class Tool
    # Evaluates a basic arithmetic expression with Python operator
    # syntax and semantics, via the hand-rolled recursive-descent
    # {Parser} below.
    #
    # Why hand-rolled rather than a gem: the previous backend, dentaku,
    # pulled in concurrent-ruby (~16k lines of Ruby — the single
    # heaviest audit item in pikuri's whole dependency closure) plus
    # bigdecimal and tsort, all to evaluate four-function arithmetic.
    # The ~100 lines here implement Python's expression grammar
    # directly, which also retires the old preprocessing step that
    # rewrote Python's +**+ into dentaku's +^+ dialect — the model's
    # native syntax is now simply the grammar.
    #
    # Scope is intentionally narrow: operators (+, -, *, /, //, %, **),
    # unary minus, parentheses, and integer / decimal / e-notation
    # literals. No variables, functions, or booleans — those would mean
    # teaching the model a dialect, which we specifically want to avoid
    # for this tool.
    module Calculator
      # Raised internally for anything {.calculate} should hand back to
      # the model as an +"Error: ..."+ observation rather than crash
      # the agent loop: parse failures, division by zero, complex or
      # non-finite results. The message always names the offending
      # token or operands.
      class Error < StandardError; end

      # Evaluate +expression+ and return the result formatted as a
      # String. Parse and arithmetic failures (division by zero,
      # overflow to infinity, complex results) are caught and returned
      # as +"Error: ..."+ strings so the model can read the failure as
      # the next observation and self-correct rather than crashing the
      # agent loop.
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

      # Integers (never produced by division — +/+ is Python-3-style
      # true division) pass through exact. Floats are rounded to 3
      # places so the model sees a short readable number, and
      # whole-valued floats drop the trailing +.0+ (+4 / 2+ renders as
      # +"2"+, not +"2.0"+).
      def self.format_result(result)
        return result.to_s if result.is_a?(Integer)

        rounded = result.round(3)
        rounded == rounded.truncate ? rounded.truncate.to_s : rounded.to_s
      end
      private_class_method :format_result

      # Recursive-descent parser-evaluator for Python's arithmetic
      # expression grammar:
      #
      #   additive       := multiplicative (('+' | '-') multiplicative)*
      #   multiplicative := unary (('*' | '/' | '//' | '%') unary)*
      #   unary          := ('+' | '-') unary | power
      #   power          := atom ('**' unary)?
      #   atom           := NUMBER | '(' additive ')'
      #
      # The +power+ → +unary+ recursion on the right operand is what
      # makes +**+ right-associative (+2**3**2+ is 512) and lets a sign
      # follow it (+2**-3+); +unary+ sitting *above* +power+ on the
      # left is what makes +-2**2+ evaluate to -4 — both exactly as
      # Python parses them.
      #
      # Semantics follow Python 3 where Ruby differs: +/+ is always
      # true (float) division, +//+ floors, +2**-1+ is the Float 0.5
      # (Ruby would return a Rational), and a negative base under a
      # fractional exponent is rejected (Ruby would return a Complex).
      class Parser
        # One number or operator. +**+ / +//+ listed before their
        # single-character prefixes so the two-character operators win;
        # number literals cover +42+, +4.2+, +5.+, +.5+, and e-notation
        # on any of them. +\G+ anchors each match at the scan position
        # so nothing between tokens goes unnoticed.
        TOKEN_RE = %r{\G\s*(\*\*|//|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?|[-+*/%()])}

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

          token = peek
          unless token&.match?(/\A[.\d]/)
            raise Error, token ? "unexpected #{token.inspect}" : 'unexpected end of expression'
          end

          @pos += 1
          token.match?(/[.eE]/) ? token.to_f : token.to_i
        end

        def parenthesized
          value = additive
          raise Error, 'missing closing parenthesis' unless accept(')')

          value
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

        # +/+ is Python-3 true division (always Float); +//+ floors
        # (kept exact in Ruby's arbitrary-precision Integer division
        # when both operands are Integers — Ruby's +Integer#/+ already
        # floors like Python's +//+); +%+ delegates to Ruby's +%+,
        # whose sign-of-divisor semantics match Python's exactly.
        def apply_multiplicative(op, lhs, rhs)
          return lhs * rhs if op == '*'
          raise Error, 'division by zero' if rhs.zero?

          case op
          when '/' then lhs.fdiv(rhs)
          when '//' then lhs.is_a?(Integer) && rhs.is_a?(Integer) ? lhs / rhs : lhs.fdiv(rhs).floor
          when '%' then lhs % rhs
          end
        end

        # Two Python-compatibility shims over Ruby's +**+: an Integer
        # raised to a negative Integer yields a Float (Ruby would
        # return a Rational), and a Complex result — negative base
        # under a fractional exponent — is rejected loudly.
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

    # Arithmetic-evaluation tool backed by {Tool::Calculator.calculate}.
    # Accepts Python expression syntax (+, -, *, /, //, %, ** for
    # exponentiation, unary minus, parentheses, decimals) so the model
    # can emit the syntax it already knows.
    #
    # @return [Tool]
    CALCULATOR = new(
      name: 'calculator',
      description: <<~DESC,
        Evaluates a basic arithmetic expression and returns the numeric result.

        Usage:
        - Use this for any arithmetic beyond simple mental math — do not eyeball multi-digit work.
        - Python expression syntax: +, -, *, / (true division), // (floor division), % (modulo), ** (exponentiation), unary minus, parentheses, decimal numbers.
        - Decimal results are rounded to 3 places; integer results are exact.
        - Failures (parse error, division by zero) come back as "Error: ..." — read the message and re-call with a corrected expression.
      DESC
      parameters: Parameters.build { |p|
        p.required_string :expression,
                          'Arithmetic expression to evaluate, e.g. ' \
                          '"155 / (58 * 1000.0 / 3600)" or "2**10".'
      },
      execute: ->(expression:) { Calculator.calculate(expression) }
    )
  end
end
