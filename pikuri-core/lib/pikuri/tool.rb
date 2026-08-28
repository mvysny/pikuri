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
  #
  # == Sharing: may one instance serve two agents?
  #
  # {Pikuri::Agent} is thread-unsafe, so a host running ten agents in one VM
  # serializes each agent's own calls — usually a thread apiece. That makes
  # "may a second agent have this tool?" and "is this reachable from two
  # threads?" one question. Every tool answers it, as a +Sharing:+ tail or a
  # +== Sharing+ section, naming one posture:
  #
  # * *P_stateless* — no mutable state. Share freely.
  # * *P_shared_locked* — process-wide mutable state under a lock. Sharing is
  #   intended, and for anything pacing a shared *external* resource it is
  #   mandatory: a per-agent {Search::RateLimiter} would let ten agents fire
  #   ten simultaneous requests from one IP and earn the ban it exists to
  #   avoid.
  # * *P_shared_benign* — unprotected process-wide state whose race is
  #   harmless; the doc names the race ({Pikuri::UrlCache}: both callers
  #   compute a cold key and write identical bytes).
  # * *P_one_agent* — agent-scoped state, so exactly one agent. It needs no
  #   lock because its only caller is that agent, whose calls are already
  #   serialized; wire it twice and you lose that for free. And the first
  #   failure isn't a race but a correctness bug — agent A would read agent B's
  #   facts single-threaded too.
  #
  # +P_one_agent+ is a fine answer, not a defect: most of what a tool knows is
  # one conversation's business. Nothing enforces it, so the doc *is* the
  # contract. The two axes stay independent — a {Skill::Activation} locks *and*
  # is per-agent, so "thread-safe" is no licence to share.
  #
  # A +Tool+ is a value object holding a +Proc+, so its posture is its
  # collaborators': each tool names the one that owns the state, which is also
  # where any lock lives.
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

    # @return [Tool::TrifectaLegs] which lethal-trifecta legs this tool
    #   contributes, for {Pikuri::Trifecta}
    attr_reader :trifecta_legs

    # @param name [String] function name advertised to the LLM
    # @param description [String] human-readable description used by the LLM
    #   to decide when to call the tool
    # @param parameters [Tool::Parameters] declared schema
    # @param execute [Proc] callable invoked with validated keyword arguments,
    #   returning a +String+ or +RubyLLM::Content+ (see {#execute}). Recoverable
    #   failures return +"Error: <message>"+ rather than raise.
    # @param trifecta_legs [Tool::TrifectaLegs] legs this tool contributes.
    #   Compute them here rather than at a later resolution pass: construction
    #   *is* wiring time, since every collaborator that decides a leg (the
    #   workspace, the sandbox, the confirmer) is already a kwarg of the tool
    #   that uses it. Defaults to {TrifectaLegs::ASSUMED} — an undeclared tool is
    #   presumed hostile on both axes the framework could have determined.
    # @return [Tool]
    def initialize(name:, description:, parameters:, execute:, trifecta_legs: TrifectaLegs::ASSUMED)
      @name = name
      @description = description
      @parameters = parameters
      @execute = execute
      @trifecta_legs = trifecta_legs
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
