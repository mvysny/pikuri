# frozen_string_literal: true

require 'dentaku'

# Loaded by +lib/tools.rb+ after {Tool} itself is defined; the +class Tool+
# reopening below assumes that order.
class Tool
  # Evaluates a basic arithmetic expression using Dentaku, with light
  # preprocessing so the LLM can emit Python-flavored syntax (notably
  # +**+ for exponentiation) instead of learning Dentaku's dialect.
  #
  # Scope is intentionally narrow: operators (+, -, *, /, **, %),
  # parentheses, and decimal numbers. No variables, functions, or
  # booleans — those would mean teaching the model a dialect, which we
  # specifically want to avoid for this tool.
  module Calculator
    # Translate the operator differences between Python and Dentaku. In
    # practice that is only +**+ → +^+; everything else in the supported
    # subset is byte-identical.
    #
    # @param expression [String] raw expression as the model wrote it
    # @return [String] expression with Python-style operators rewritten
    def self.normalize(expression)
      expression.gsub('**', '^')
    end

    # Evaluate +expression+ and return the result formatted as a String.
    # Parse, unbound-variable, and division-by-zero failures are caught
    # and returned as +"Error: ..."+ strings so the model can read the
    # failure as the next observation and self-correct rather than
    # crashing the agent loop.
    #
    # @param expression [String]
    # @return [String] numeric result, or +"Error: ..."+ on failure
    def self.calculate(expression)
      result = Dentaku::Calculator.new.evaluate!(normalize(expression))
      format_result(result)
    rescue Dentaku::ZeroDivisionError, ZeroDivisionError
      'Error: division by zero'
    rescue Dentaku::Error => e
      "Error: #{e.message}"
    end

    # Dentaku returns BigDecimal for any expression that touches division
    # or a decimal literal, with full BigDecimal precision (47-digit tails
    # for the leopard expression). Round to 3 places and strip the
    # default scientific-notation formatting so the model sees a short
    # readable number; integer/other results pass through unchanged.
    def self.format_result(result)
      case result
      when BigDecimal then result.round(3).to_s('F')
      else result.to_s
      end
    end
    private_class_method :format_result
  end

  # Arithmetic-evaluation tool backed by {Tool::Calculator.calculate}.
  # Accepts Python-flavored operator syntax (+, -, *, /, ** for
  # exponentiation, %, parentheses, decimals) so the model can emit the
  # syntax it already knows.
  #
  # @return [Tool]
  CALCULATOR = new(
    name: 'calculator',
    description: 'Evaluates a basic arithmetic expression and returns ' \
                 'the numeric result. Supports +, -, *, /, ** ' \
                 '(exponentiation), %, parentheses, and decimal ' \
                 'numbers. No variables or functions — pass concrete ' \
                 'numbers only.',
    parameters: Parameters.build { |p|
      p.required_string :expression,
                        'Arithmetic expression to evaluate, e.g. ' \
                        '"155 / (58 * 1000.0 / 3600)" or "2**10".'
    },
    execute: ->(expression:) { Calculator.calculate(expression) }
  )
end
