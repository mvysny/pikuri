# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  # A tool the LLM can request via OpenAI-style tool calling.
  #
  # A plain value object — +name+, +description+, +parameters+, and an
  # +execute+ Proc that produces the observation. Pikuri's code talks to this
  # surface; conversion to ruby_llm's runtime shape happens at exactly one seam,
  # {#to_ruby_llm_tool}, which the +Agent+ calls when wiring tools into the
  # +RubyLLM::Chat+. Bundled implementations live under +lib/tool/+ and are
  # required explicitly by the scripts that use them.
  #
  # == Validation ordering
  #
  # Pikuri's {Parameters#validate} (DidYouMean suggestions, type coercion,
  # all-errors-collected) is what the LLM must see on bad arguments, not
  # ruby_llm's keyword-presence checker. The synthetic class from
  # {#to_ruby_llm_tool} defines +execute(**args)+: the keyrest signature makes
  # +RubyLLM::Tool#validate_keyword_arguments+ no-op, so pikuri's validator runs
  # inside {#run} before any user code.
  #
  # == Error handling convention
  #
  # * *Recoverable* failures (bad arguments, HTTP 4xx/5xx, network blips,
  #   rate-limits, division by zero, ...) come back as +"Error: <message>"+
  #   Strings and become the next observation, so the model self-corrects.
  # * *Bugs* in pikuri's own code (parser regressions, schema misuse, ...) keep
  #   raising — the LLM can't fix them.
  #
  # {#run} catches {Parameters#validate} failures into +"Error: ..."+; the
  # +execute+ Proc follows the same convention for its own recoverable failures
  # and lets bugs raise.
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

    # @return [Proc] callable invoked with validated keyword arguments,
    #   returning the observation — usually a +String+, or a +RubyLLM::Content+
    #   with attachments for multimodal observations (e.g.
    #   {Pikuri::Workspace::Read} on a PNG), which +RubyLLM::Chat+ turns into
    #   the right image/document blocks.
    attr_reader :execute

    # @param name [String] function name advertised to the LLM
    # @param description [String] human-readable description used by the LLM
    #   to decide when to call the tool
    # @param parameters [Tool::Parameters] declared schema
    # @param execute [Proc] callable invoked with validated keyword arguments,
    #   returning a +String+ or +RubyLLM::Content+ (see {#execute}). Recoverable
    #   failures return +"Error: <message>"+ rather than raise.
    # @return [Tool]
    def initialize(name:, description:, parameters:, execute:)
      @name = name
      @description = description
      @parameters = parameters
      @execute = execute
    end

    # Validate +args+ against {#parameters} and forward them as kwargs to
    # {#execute}. Validation failures come back as +"Error: <message>"+ Strings
    # for the next observation; everything else bubbles up.
    #
    # @param args [Hash] raw arguments supplied by the LLM
    # @return [String, RubyLLM::Content] tool observation — validation failures
    #   always +"Error: ..."+; success is whatever +execute+ returns.
    def run(args)
      validated = @parameters.validate(args)
      @execute.call(**validated)
    rescue Tool::Parameters::ValidationError => e
      "Error: #{e.message}"
    end

    # Build a synthetic +RubyLLM::Tool+ subclass wrapping this Tool — what
    # +RubyLLM::Chat#with_tool+ accepts. ruby_llm instantiates it and routes
    # tool calls through +#execute(**args)+, which delegates to {#run}.
    #
    # @return [Class] anonymous +RubyLLM::Tool+ subclass
    def to_ruby_llm_tool
      pikuri_tool = self
      schema      = @parameters.to_openai
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
