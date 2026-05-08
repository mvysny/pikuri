# frozen_string_literal: true

require_relative 'duckduckgo_search'

# Value object describing a function the LLM can request via OpenAI-style tool
# calling: the metadata advertised in the +tools+ array, plus the callable that
# runs when the LLM invokes it. Tools are stateless — each is a single
# +Tool.new(...)+ constant rather than a subclass.
#
# @!attribute [r] name
#   @return [String] function name as advertised to the LLM
# @!attribute [r] description
#   @return [String] human-readable description used by the LLM to decide
#     when to call the tool
# @!attribute [r] parameters
#   @return [Tool::Parameters] declared schema; validates incoming arguments
#     and serializes to the JSON Schema shape OpenAI expects
# @!attribute [r] execute
#   @return [Proc] callable invoked by {#run}; receives validated keyword
#     arguments and returns a +String+
Tool = Data.define(:name, :description, :parameters, :execute) do
  # Validate +args+ against {#parameters} and invoke the underlying callable.
  # Takes a +Hash+ (matching the JSON-decoded tool-call payload from the LLM)
  # rather than kwargs — validation lives at the boundary.
  #
  # @param args [Hash] arguments as decoded from the tool-call JSON; keys may
  #   be Strings or Symbols
  # @return [String] observation text to feed back into the next chat turn
  # @raise [Tool::Parameters::ValidationError] if +args+ does not match the
  #   declared schema; the message is LLM-actionable and can be returned to
  #   the model as the next observation
  def run(args)
    validated = parameters.validate(args)
    execute.call(**validated)
  end
end

require_relative 'tool/parameters'
require_relative 'tool/calculator'

# DuckDuckGo web-search tool. Thin wrapper over {DuckDuckGoSearch.search}
# that exposes it to the agent loop in OpenAI tool-call shape.
#
# @return [Tool]
WEB_SEARCH_TOOL = Tool.new(
  name: 'web_search',
  description: 'Performs a web search for a query and returns the top ' \
               'results formatted as Markdown with titles, links, and ' \
               'descriptions.',
  parameters: Tool::Parameters.build { |p|
    p.required_string :query, 'The search query to perform.'
  },
  execute: ->(query:) { DuckDuckGoSearch.search(query) }
)

# Arithmetic-evaluation tool backed by {Tool::Calculator.calculate}. Accepts
# Python-flavored operator syntax (+, -, *, /, ** for exponentiation,
# %, parentheses, decimals) so the model can emit the syntax it
# already knows.
#
# @return [Tool]
CALCULATOR_TOOL = Tool.new(
  name: 'calculator',
  description: 'Evaluates a basic arithmetic expression and returns ' \
               'the numeric result. Supports +, -, *, /, ** ' \
               '(exponentiation), %, parentheses, and decimal ' \
               'numbers. No variables or functions — pass concrete ' \
               'numbers only.',
  parameters: Tool::Parameters.build { |p|
    p.required_string :expression,
                      'Arithmetic expression to evaluate, e.g. ' \
                      '"155 / (58 * 1000.0 / 3600)" or "2**10".'
  },
  execute: ->(expression:) { Tool::Calculator.calculate(expression) }
)
