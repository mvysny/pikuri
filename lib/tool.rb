# frozen_string_literal: true

require 'ruby_llm'

# Factory for tools the LLM can request via OpenAI-style tool calling.
# +Tool.new(name:, description:, parameters:, execute:)+ returns a synthetic
# +RubyLLM::Tool+ subclass — *not* a value object — so the result can be
# handed straight to ruby_llm's runtime via +Chat#with_tool+ while still
# answering pikuri's class-level surface (+name+, +description+,
# +parameters+, +run+) for everything that talked to the old +Data.define+
# shape.
#
# Bundled tool implementations live under +lib/tool/+ and are required
# explicitly by the scripts that use them; +lib/tool.rb+ itself only
# introduces the {Tool} factory and {Tool::Parameters} machinery.
#
# == Why a factory rather than a +Data.define+
#
# The migration to ruby_llm (see +MIGRATION.md+) hands the agent loop to
# +RubyLLM::Chat+. +Chat#with_tool+ expects a +RubyLLM::Tool+ subclass and
# instantiates it with +tool.new+, so pikuri's tools have to *be* those
# subclasses. The factory builds one per call, capturing pikuri's
# {Parameters} validator and the user-supplied callable in a closure that
# both the class-level +run+ (used directly by pikuri) and the instance-
# level +execute+ (used by ruby_llm's tool-calling path) delegate to.
#
# == Validation ordering
#
# Pikuri's {Parameters#validate} — DidYouMean suggestions, type coercion,
# all-errors-collected — is what the LLM must see when it emits bad
# arguments, not ruby_llm's keyword-presence checker. The synthetic class
# defines +execute(**args)+: the keyrest signature makes
# +RubyLLM::Tool#validate_keyword_arguments+ no-op (it bails out at the
# +accepts_extra_keywords+ check), and pikuri's validator runs inside the
# shared runner before any user code does.
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
# Argument-validation failures from {Parameters#validate} are caught by the
# shared runner and turned into +"Error: ..."+ observations. The +execute+
# Proc owns the rest — it should follow the same convention internally for
# tool-specific recoverable failures, and let bugs raise.
class Tool
  # Build a synthetic +RubyLLM::Tool+ subclass.
  #
  # @param name [String] function name advertised to the LLM
  # @param description [String] human-readable description used by the LLM
  #   to decide when to call the tool
  # @param parameters [Tool::Parameters] declared schema; validates incoming
  #   arguments and serializes to the JSON Schema shape advertised to the
  #   LLM
  # @param execute [Proc] callable invoked once arguments have been
  #   validated; receives validated keyword arguments and returns a +String+
  #   observation. Recoverable failures should be returned as
  #   +"Error: <message>"+ Strings rather than raised — see "Error handling
  #   convention" above.
  # @return [Class] anonymous +RubyLLM::Tool+ subclass that responds to
  #   +.name+, +.description+, +.parameters+, +.run(args)+ at the class
  #   level (pikuri's surface) and to +#execute(**args)+ at the instance
  #   level (ruby_llm's surface)
  def self.new(name:, description:, parameters:, execute:)
    runner = lambda do |args|
      validated = parameters.validate(args)
      execute.call(**validated)
    rescue Tool::Parameters::ValidationError => e
      "Error: #{e.message}"
    end

    schema     = parameters.to_h
    tool_name  = name
    tool_desc  = description
    tool_parms = parameters

    Class.new(RubyLLM::Tool) do
      description(tool_desc)
      params(schema)

      define_singleton_method(:name)        { tool_name }
      define_singleton_method(:description) { tool_desc }
      define_singleton_method(:parameters)  { tool_parms }
      define_singleton_method(:run)         { |args| runner.call(args) }

      define_method(:name)    { tool_name }
      define_method(:execute) { |**args| runner.call(args) }
    end
  end
end

require_relative 'tool/parameters'
