# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  # A tool the LLM can request via OpenAI-style tool calling.
  #
  # {Tool} is a plain value object: +name+, +description+, +parameters+,
  # and an +execute+ Proc that produces the observation. Pikuri's own
  # code talks to this surface (the bundled tools, the sub-agent factory,
  # the +Agent+ constructor); the conversion to ruby_llm's runtime shape
  # happens at exactly one named seam — {#to_ruby_llm_tool} — which the
  # +Agent+ calls when wiring tools into the underlying +RubyLLM::Chat+.
  #
  # Bundled tool implementations live under +lib/tool/+ and are required
  # explicitly by the scripts that use them; +lib/tool.rb+ itself only
  # introduces the {Tool} class and {Tool::Parameters} machinery.
  #
  # == Validation ordering
  #
  # Pikuri's {Parameters#validate} — DidYouMean suggestions, type coercion,
  # all-errors-collected — is what the LLM must see when it emits bad
  # arguments, not ruby_llm's keyword-presence checker. The synthetic
  # class produced by {#to_ruby_llm_tool} defines +execute(**args)+: the
  # keyrest signature makes +RubyLLM::Tool#validate_keyword_arguments+
  # no-op (it bails out at the +accepts_extra_keywords+ check), so
  # pikuri's validator runs inside {#run} before any user code does.
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
  # Argument-validation failures from {Parameters#validate} are caught by
  # {#run} and turned into +"Error: ..."+ observations. The +execute+ Proc
  # owns the rest — it should follow the same convention internally for
  # tool-specific recoverable failures, and let bugs raise.
  class Tool
    # @return [String] function name advertised to the LLM
    attr_reader :name

    # @return [String] human-readable description used by the LLM to decide
    #   when to call the tool
    attr_reader :description

    # @return [Tool::Parameters] declared schema; validates incoming
    #   arguments and serializes to the JSON Schema shape advertised to the
    #   LLM
    attr_reader :parameters

    # @return [Proc] callable invoked once arguments have been validated;
    #   receives validated keyword arguments and returns a +String+
    #   observation
    attr_reader :execute

    # @param name [String] function name advertised to the LLM
    # @param description [String] human-readable description used by the LLM
    #   to decide when to call the tool
    # @param parameters [Tool::Parameters] declared schema
    # @param execute [Proc] callable invoked with validated keyword arguments
    #   that returns a +String+ observation. Recoverable failures should be
    #   returned as +"Error: <message>"+ Strings rather than raised — see
    #   "Error handling convention" above.
    # @return [Tool]
    def initialize(name:, description:, parameters:, execute:)
      @name = name
      @description = description
      @parameters = parameters
      @execute = execute
    end

    # Validate +args+ against {#parameters} and forward them as keyword
    # arguments to {#execute}. Validation failures are caught and rendered
    # as +"Error: <message>"+ Strings so the agent loop can feed them back
    # to the LLM as the next observation; everything else bubbles up.
    #
    # @param args [Hash] raw arguments supplied by the LLM
    # @return [String] tool observation, or +"Error: ..."+ on validation
    #   failure
    def run(args)
      validated = @parameters.validate(args)
      @execute.call(**validated)
    rescue Tool::Parameters::ValidationError => e
      "Error: #{e.message}"
    end

    # Build a synthetic +RubyLLM::Tool+ subclass that wraps this Tool. The
    # subclass is what +RubyLLM::Chat#with_tool+ accepts: ruby_llm
    # instantiates it (+tool.new+) and routes tool calls through
    # +instance.call(args)+, which lands in +#execute(**args)+ and
    # delegates back to {#run} on this instance.
    #
    # @return [Class] anonymous +RubyLLM::Tool+ subclass
    def to_ruby_llm_tool
      pikuri_tool = self
      schema      = @parameters.to_h
      tool_name   = @name
      tool_desc   = @description

      Class.new(RubyLLM::Tool) do
        description(tool_desc)
        params(schema)

        define_singleton_method(:name) { tool_name }
        define_method(:execute) { |**args| pikuri_tool.run(args) }
      end
    end
  end
end
