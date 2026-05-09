# frozen_string_literal: true

# Value object describing a function the LLM can request via OpenAI-style tool
# calling: the metadata advertised in the +tools+ array, plus the callable that
# runs when the LLM invokes it. Tools are stateless — each is a single
# +Tool.new(...)+ constant rather than a subclass.
#
# Bundled tool implementations live under +lib/tool/+ and are required
# explicitly by the scripts that use them; +lib/tool.rb+ itself only
# introduces the {Tool} class and {Tool::Parameters} machinery.
#
# == Error handling convention
#
# Tools split failures into two buckets:
#
# * *Recoverable* failures — anything the LLM can react to by retrying with
#   different inputs (bad arguments, HTTP 4xx/5xx, network blips, search
#   provider rate-limits, division by zero in the calculator, ...). These
#   come back as a +"Error: <message>"+ String and become the next
#   observation; the model sees them and self-corrects on the following
#   turn instead of crashing the agent loop.
# * *Bugs* in pikuri's own code (parser regressions, schema misuse,
#   misconfigured clients, ...). These keep raising. The LLM cannot fix
#   them; a human needs to.
#
# {#run} enforces the first half: argument-validation failures from
# {Parameters#validate} are caught here and turned into +"Error: ..."+
# observations. The +execute+ Proc owns the rest — it should follow the
# same convention internally for tool-specific recoverable failures, and
# let bugs raise.
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
#     arguments and returns a +String+ observation. Recoverable failures
#     (HTTP errors, network blips, provider rate-limits, anything the LLM
#     can react to by trying again with different inputs) should be
#     returned as +"Error: <message>"+ Strings rather than raised — the
#     LLM sees them as the next observation and self-corrects. Genuine
#     bugs in pikuri's own code should still raise; those need a human
#     to fix, not the LLM.
Tool = Data.define(:name, :description, :parameters, :execute) do
  # Validate +args+ against {#parameters} and invoke the underlying callable.
  # Takes a +Hash+ (matching the JSON-decoded tool-call payload from the LLM)
  # rather than kwargs — validation lives at the boundary.
  #
  # Validation failures are caught and returned as +"Error: ..."+ strings
  # — the {Parameters::ValidationError} message is already designed to
  # be LLM-actionable (it lists every problem and reprints the schema),
  # so the model can read it as the next observation and self-correct on
  # the following turn rather than crashing the agent loop. See the
  # class-level "Error handling convention" note for the full picture.
  #
  # @param args [Hash] arguments as decoded from the tool-call JSON; keys may
  #   be Strings or Symbols
  # @return [String] observation text to feed back into the next chat turn;
  #   either +execute+'s return value or +"Error: ..."+ on a validation
  #   failure
  def run(args)
    validated = parameters.validate(args)
    execute.call(**validated)
  rescue Tool::Parameters::ValidationError => e
    "Error: #{e.message}"
  end
end

require_relative 'tool/parameters'
