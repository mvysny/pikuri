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
  # == Display lines
  #
  # A chrome shows one call as three short strings it styles, caps and defangs
  # but never composes:
  #
  #   Write(lib/shared/config.rb)
  #     Added 2 lines, removed 3 lines
  #
  # The tool owns all three, because at +execute+ time it still holds the
  # structure it is about to flatten for the model — 23 result structs, a line
  # count, an exit status — which no renderer can recover from the Markdown it
  # gets. {#display_name} and {#describe_call} answer the call side;
  # {Result#summary} answers the result side. Each default is mechanical
  # ({.display_name_for}, the first required parameter, {.describe_content}), so
  # a tool declaring nothing — every MCP tool, every third-party +Tool+ — still
  # renders.
  #
  # Never the *model*: a narrated status line is steerable through a fetched
  # page. {Result} carries the two rules a summary obeys.
  #
  # == One return type
  #
  # An +execute+ returns a {Result}, always — the observation plus its display
  # line, with {Result.error} for a recoverable failure. {#run} enforces it,
  # wrapping a bare String from a third-party +Tool+ rather than refusing it.
  #
  # There is no second success shape to choose between: an *attachment*
  # observation (the image {Pikuri::Workspace::Read} answers for a PNG) is a
  # +Result+ with non-empty {Result#attachments}, and the sole place that
  # distinction is visible is the four-line wrapper in
  # {#to_ruby_llm_tool}, which no tool reads.
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
  #
  # The one way to break the premise from outside pikuri: ruby_llm's
  # +tool_concurrency+ config (default +false+) makes +Chat+ run a tool batch on
  # threads, so a *single* agent would enter its own +P_one_agent+ tools
  # concurrently. Leave it off.
  #
  # == Cancellation
  #
  # A tool that *waits* can opt into being interrupted: pass
  # +wants_context: true+ and take a +context:+ keyword, then wait through
  # {Pikuri::Agent::Control::Cancellable#sleep} on the {ExecuteContext} handed
  # in.
  #
  #   wants_context: true,
  #   execute: ->(query:, context:) { backend.search(query, cancellable: context.cancellable) }
  #
  # Opt-in rather than universal because most tools have nothing to cancel, and
  # because a token only reaches *waits* — a tool blocked in IO (a Faraday read,
  # +Subprocess#wait+) stays uninterruptible however many tokens it holds.
  #
  # Per *call*, not per construction, and that is the point: {#to_ruby_llm_tool}
  # mints a fresh wrapper per agent, so even a +P_shared_locked+ tool shared by
  # ten agents honours whichever one is actually waiting. The context is always
  # a real object ({ExecuteContext.default}, whose cancellation never trips,
  # when the host wired none), so an +execute+ never nil-checks it.
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
    #   returning the observation as a {Result} — see +== One return type+.
    attr_reader :execute

    # @return [Tool::TrifectaLegs] which lethal-trifecta legs this tool
    #   contributes, for {Pikuri::Trifecta}
    attr_reader :trifecta_legs

    # @param name [String] function name advertised to the LLM
    # @param description [String] human-readable description used by the LLM
    #   to decide when to call the tool
    # @param parameters [Tool::Parameters] declared schema
    # @param execute [Proc] callable invoked with validated keyword arguments,
    #   returning a {Result} (see {#execute}). Recoverable failures answer
    #   {Result.error} rather than raise.
    # @param trifecta_legs [Tool::TrifectaLegs] legs this tool contributes.
    #   Compute them here rather than at a later resolution pass: construction
    #   *is* wiring time, since every collaborator that decides a leg (the
    #   workspace, the sandbox, the confirmer) is already a kwarg of the tool
    #   that uses it. Defaults to {TrifectaLegs::ASSUMED} — an undeclared tool is
    #   presumed hostile on both axes the framework could have determined.
    # @param wants_context [Boolean] when +true+, {#run} additionally passes a
    #   +context:+ keyword carrying this call's {ExecuteContext} — so +execute+
    #   must declare one. Declared rather than inferred from the Proc, and both
    #   halves are mandatory, so either without the other is an +ArgumentError+
    #   on the first call rather than a silent +nil+.
    # @return [Tool]
    def initialize(name:, description:, parameters:, execute:,
                   trifecta_legs: TrifectaLegs::ASSUMED, wants_context: false)
      @name = name
      @description = description
      @parameters = parameters
      @execute = execute
      @trifecta_legs = trifecta_legs
      @wants_context = wants_context
    end

    # @return [Boolean] whether {#run} hands +execute+ a +context:+ keyword
    #   carrying the {ExecuteContext} for this call. Declared at construction,
    #   never inferred from the Proc's signature — see the +== Cancellation+
    #   section.
    attr_reader :wants_context

    # CamelCase display form of a *raw* tool name, for the three cases with no
    # +Tool+ instance to ask: an MCP tool (which bypasses {Pikuri::Tool}),
    # ruby_llm's unavailable-tool error, a replayed history.
    #
    #   Tool.display_name_for('web_search')                # => "WebSearch"
    #   Tool.display_name_for('openlibrary__search_books') # => "Openlibrary::SearchBooks"
    #
    # +__+ is {Pikuri::Mcp::Servers}' server separator, so the halves CamelCase
    # and join with +::+; inside a half any non-alphanumeric run is a word break
    # (an MCP name may carry +-+ or +.+, which ruby_llm sanitizes to +_+).
    #
    # Deterministic beats pretty — +vectordb_search+ becomes +VectordbSearch+
    # and a tool wanting +LSP+ overrides {#display_name}.
    #
    # @param name [String] the function name advertised to the LLM
    # @return [String] display form; +""+ for a blank name
    def self.display_name_for(name)
      name.to_s.split('__').filter_map { |segment|
        words = segment.split(/[^A-Za-z0-9]+/).reject(&:empty?)
        words.map { |w| w[0].upcase + w[1..] }.join unless words.empty?
      }.join('::')
    end

    # Every supplied argument as +k=v+ — the display line for a tool whose
    # {Parameters} are unknown (an MCP tool, a replayed call) or which declares
    # no required parameter.
    #
    #   Tool.describe_arguments('from' => 'bob', 'after' => '2026-09')
    #   # => "from=bob after=2026-09"
    #
    # @param arguments [Hash] raw tool-call arguments
    # @return [String] one line; +""+ for no arguments or a non-Hash
    def self.describe_arguments(arguments)
      return '' unless arguments.is_a?(Hash)

      one_line(arguments.map { |k, v| "#{k}=#{describe_value(v)}" }.join(' '))
    end

    # Generic structural summary of an observation — the result line for a tool
    # that returned a bare String rather than a {Result}.
    #
    #   Tool.describe_content("a\nb\nc")              # => "Returned 3 lines"
    #   Tool.describe_content('Error: no such file')  # => "Error: no such file"
    #
    # An +"Error: ..."+ observation shows its own first line, because that *is*
    # the status the reader needs. ruby_llm's unavailable-tool +Hash+ passes its
    # +:error+ through the same way.
    #
    # @param content [String, Array<String, RubyLLM::Attachment>, Hash]
    #   whatever reached +after_tool_result+ — an Array is an attachment
    #   observation as {#to_ruby_llm_tool} hands it over
    # @return [String] one line
    def self.describe_content(content)
      return one_line(content[:error].to_s) if content.is_a?(Hash) && content[:error]
      return describe_attachments(content) if content.is_a?(Array) && content.any?(RubyLLM::Attachment)

      text = content.to_s
      return one_line(text.lines.first.to_s) if text.start_with?('Error:')

      lines = text.lines.size
      lines > 1 ? "Returned #{lines} lines" : "Returned #{text.bytesize} bytes"
    end

    # Flatten +text+ to one line — every display string a tool composes goes
    # through this, since a summary or an argument spanning two lines would
    # break the one-call-one-line shape every renderer assumes.
    #
    # @param text [String, nil]
    # @return [String] whitespace runs collapsed to single spaces, stripped
    def self.one_line(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end

    # A count with its noun pluralized — display lines are mostly counting.
    #
    #   "Matched #{Tool.pluralize(1, 'file')}"              # => "Matched 1 file"
    #   "Matched #{Tool.pluralize(7, 'match', 'matches')}"  # => "Matched 7 matches"
    #
    # @param number [Integer]
    # @param singular [String]
    # @param plural [String, nil] defaults to +singular+ + +"s"+
    # @return [String]
    def self.pluralize(number, singular, plural = nil)
      number == 1 ? "#{number} #{singular}" : "#{number} #{plural || "#{singular}s"}"
    end

    # Byte count in the largest unit that keeps it short.
    #
    #   Tool.format_bytes(3_162)  # => "3.1 kB"
    #
    # @param bytes [Integer]
    # @return [String]
    def self.format_bytes(bytes)
      return "#{bytes} B" if bytes < 1024
      return format('%.1f kB', bytes / 1024.0) if bytes < 1024 * 1024

      format('%.1f MB', bytes / (1024.0 * 1024))
    end

    # @param value [String, Numeric, Boolean, Array, nil] one argument value,
    #   as ruby_llm parsed it out of the model's JSON
    # @return [String] +to_s+, except an Array, which joins with +", "+ so a
    #   list argument reads as a list rather than as +["a", "b"]+
    def self.describe_value(value)
      value.is_a?(Array) ? value.join(', ') : value.to_s
    end

    # @param parts [Array<String, RubyLLM::Attachment>] holding at least one
    #   attachment
    # @return [String] +"Returned image/png, 40.2 kB"+, or the mime alone when
    #   the size isn't free
    def self.describe_attachments(parts)
      attachment = parts.find { |p| p.is_a?(RubyLLM::Attachment) }

      size = attachment_bytesize(attachment)
      size ? "Returned #{attachment.mime_type}, #{format_bytes(size)}" : "Returned #{attachment.mime_type}"
    end
    private_class_method :describe_attachments

    # @param attachment [RubyLLM::Attachment]
    # @return [Integer, nil] the attachment's size, or +nil+ when reading it
    #   would cost more than a display line is worth
    def self.attachment_bytesize(attachment)
      # +Attachment#content+ fetches a URL-backed source over the network — a
      # display line must never do that, and no test would catch it.
      return File.size(attachment.source.to_s) if attachment.path?
      return attachment.content&.bytesize if attachment.io_like?

      nil
    rescue SystemCallError
      nil
    end
    private_class_method :attachment_bytesize

    # This tool's name as a chrome shows it — {.display_name_for} of {#name}.
    # Override where the mechanical form misreads it:
    #
    #   class LspTool < Pikuri::Tool
    #     def display_name = 'LSP'
    #   end
    #
    # @return [String]
    def display_name
      Tool.display_name_for(@name)
    end

    # The one argument worth showing beside {#display_name} — by default the
    # value of the first *required* parameter, which is the primary argument for
    # most tools (+path+ for read/write/edit, +query+ for web_search, +command+
    # for bash):
    #
    #   read.describe_call('path' => 'lib/code/app.rb')   # => "lib/code/app.rb"
    #   #  → Read(lib/code/app.rb)
    #
    # Override when that parameter is the wrong one to show — an enum, an
    # integer id, a whole Markdown plan:
    #
    #   def describe_call(arguments)
    #     Tool.one_line("#{arguments['operation']} #{arguments['symbol']}")
    #   end
    #
    # Runs on the *unvalidated* arguments ruby_llm parsed from the model's JSON,
    # before +execute+, so an override tolerates a missing or wrong-typed value.
    # Neither capped nor sanitized here: only the renderer knows its width, and
    # defanging is its job too.
    #
    # @param arguments [Hash] raw tool-call arguments; keys String or Symbol
    # @return [String] one line; +""+ renders the call bare (+EnterPlanMode+)
    def describe_call(arguments)
      key = @parameters.required.first
      return Tool.describe_arguments(arguments) if key.nil? || !arguments.is_a?(Hash)

      value = arguments.key?(key) ? arguments[key] : arguments[key.to_sym]
      return Tool.describe_arguments(arguments) if value.nil?

      Tool.one_line(Tool.describe_value(value))
    end

    # The display line for an observation this tool returned as a bare String —
    # Validate +args+ against {#parameters} and forward them as kwargs to
    # {#execute}, always answering a {Result}. Validation failures come back as
    # {Result.error} for the next observation; everything else bubbles up.
    #
    # A bare String from +execute+ is wrapped here, with
    # {.describe_content}'s generic display line — that is the floor a
    # third-party +Tool+ subclass lands on, not a shape pikuri's own tools use.
    #
    # @param args [Hash] raw arguments supplied by the LLM
    # @param context [ExecuteContext] this invocation's environment, forwarded
    #   as a +context:+ keyword only when {#wants_context}. Never part of
    #   +args+ — the LLM cannot supply it, since {Parameters#validate} refuses
    #   unknown keys. Positional against the house style on purpose: give this
    #   method *any* keyword and Ruby 3 re-reads the bare hash in
    #   +run('text' => 'hi')+ as keywords, so +args+ arrives empty at every
    #   existing call site.
    # @return [Result] tool observation.
    def run(args, context = ExecuteContext.default)
      validated = @parameters.validate(args)
      raw = if @wants_context
              @execute.call(**validated, context: context)
            else
              @execute.call(**validated)
            end
      raw.is_a?(Result) ? raw : Result.new(content: raw, summary: Tool.describe_content(raw))
    rescue Tool::Parameters::ValidationError => e
      Result.error(e.message)
    end

    # Build a synthetic +RubyLLM::Tool+ subclass wrapping this Tool — what
    # +RubyLLM::Chat#with_tools+ accepts. ruby_llm instantiates it and routes
    # tool calls through +#execute(**args)+, which delegates to {#run}.
    #
    # A wrapper is per *agent* even when this +Tool+ is shared between several,
    # which is what lets it close over one agent's cancellation token.
    #
    # The wrapper instance answers +#pikuri_tool+ with this Tool, so a holder of
    # ruby_llm's +Chat#tools+ table can get from a called name back to
    # {#display_name} / {#describe_call}.
    #
    # == The one place a Result is unwrapped
    #
    # ruby_llm hands the *same* value to +after_tool_result+ and to the +:tool+
    # message it builds, and sends attachments only for a value that *is* an
    # Array of Strings and +RubyLLM::Attachment+s — a test a {Result} cannot
    # pass. So an attachment Result crosses as +[content, *attachments]+, each
    # {Pikuri::Attachment} converted by {Pikuri::Attachment#to_ruby_llm}, and
    # its display line is derived ({.describe_content}: mime plus size, which
    # is all the structure there is); text keeps the +Result+, which ruby_llm
    # stores as {Result#to_s}, so {Result#summary} reaches the listeners
    # verbatim. That one line below is the whole boundary — {#run} answers a
    # +Result+ either way, and no tool sees this.
    #
    # @param context [ExecuteContext] passed to {#run} on every call; see the
    #   +== Cancellation+ section.
    # @return [Class] anonymous +RubyLLM::Tool+ subclass
    def to_ruby_llm_tool(context: ExecuteContext.default)
      pikuri_tool = self
      schema      = @parameters.to_openai
      tool_name   = @name
      tool_desc   = @description

      Class.new(RubyLLM::Tool) do
        description(tool_desc)
        parameters(schema)

        define_singleton_method(:name) { tool_name }
        define_method(:execute) do |**args|
          result = pikuri_tool.run(args, context)
          result.attachment? ? [result.content, *result.attachments.map(&:to_ruby_llm)] : result
        end
        define_method(:pikuri_tool) { pikuri_tool }
      end
    end
  end
end
