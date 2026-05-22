# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  # Thin wrapper around +RubyLLM::Chat+: pikuri owns the *extension
  # surface* (the event-stream listeners that consume normalized
  # chat events, plus the controls that signal back into the loop)
  # while ruby_llm owns the loop itself. The Thought / Tool-call /
  # Observation iteration lives in +Chat#complete+; pikuri's job
  # is wiring ruby_llm's three callbacks at construction time,
  # emitting {Event} variants from each, and forwarding control
  # signals (step-budget tick, cancellation check, mid-loop input
  # drain) to the appropriate {Control}.
  #
  # == Roles in this file
  #
  # Two seams are visible:
  #
  # 1. **Listeners** ({ListenerList} + {Listener::Base} subclasses)
  #    — pure consumers of the event stream. The +Agent+ is the
  #    sole emitter; listeners never write back. New rendering or
  #    capture targets (a web sink, a structured log) are added
  #    here without touching {Agent}.
  # 2. **Controls** ({Control::StepLimit}, {Control::Cancellable},
  #    {Control::Interloper}) — host-facing signal holders. The
  #    +Agent+ reads from them at well-defined boundaries:
  #    {Control::StepLimit#tick!} on every +before_tool_call+ (and
  #    {Control::StepLimit#reset!} at turn start),
  #    {Control::Cancellable#check!} on every +before_tool_call+
  #    (and {Control::Cancellable#reset!} at turn start),
  #    {Control::Interloper#drain!} on every +after_tool_result+.
  #
  # The two roles are named separately so "what fires when" is a
  # single grep for +@listeners.emit+ in this file.
  #
  # == Step-exhaustion rescue
  #
  # If the +step_limit:+ {Control::StepLimit} trips during
  # +Chat#ask+, {#run_loop} catches the +Exceeded+ exception,
  # emits an {Event::FallbackNotice} to the listener stream, and
  # hands off to {Synthesizer.run} on a fresh +RubyLLM::Chat+.
  # The synth reuses the parent's listener stream via
  # {ListenerList#for_sub_agent} (Terminal padded, TokenLog
  # zeroed, recorder shared by reference) with a +name:+ derived
  # from the parent's. The synth shares the parent's
  # +cancellable+ so a user cancel during synthesis still works,
  # and gets a fresh +step_limit+ at +max: 1+ (defensive — the
  # synth has no tools and shouldn't trip it). The synth's
  # answer becomes the value reported by
  # {#last_assistant_content}, so callers (notably
  # {Tool::SubAgent}) still get a usable reply.
  #
  # == Cancellation rescue
  #
  # If the +cancellable:+ {Control::Cancellable} trips during
  # +Chat#ask+, {#run_loop} catches the +Cancelled+ exception,
  # emits an {Event::Cancelled} to the listener stream, and
  # re-raises. No synthesizer fallback runs: cancellation means
  # the user asked the agent to drop everything, so salvaging a
  # partial answer would be the wrong move. The caller (typically
  # a REPL) rescues the re-raised exception and returns control
  # to the user; because {#run_loop} calls
  # {Control::Cancellable#reset!} at the start of every turn, the
  # same agent instance can take a fresh turn immediately
  # afterwards.
  class Agent
    LOGGER = Pikuri.logger_for('Agent')
    private_constant :LOGGER

    # Wire one +RubyLLM::Chat+ for pikuri's event stream and
    # controls. Used by both {#initialize} (on the main chat) and
    # {Synthesizer.run} (on the synth chat) so the two share one
    # source of truth for "which callback emits which event."
    #
    # Handles the three message-level registered callbacks
    # (+after_message+, +before_tool_call+, +after_tool_result+);
    # the per-chunk streaming callback is separate because
    # ruby_llm takes it as a block to +Chat#ask+ rather than a
    # registered hook — see {.streaming_block}.
    #
    # @param chat [RubyLLM::Chat] the chat instance to wire
    # @param listeners [ListenerList] the listener stream events
    #   flow into
    # @param step_limit [Control::StepLimit, nil] when set,
    #   {Control::StepLimit#tick!} is poked on every
    #   +before_tool_call+ (and raises {Control::StepLimit::Exceeded}
    #   when over budget)
    # @param cancellable [Control::Cancellable, nil] when set,
    #   {Control::Cancellable#check!} is poked on every
    #   +before_tool_call+ (and raises
    #   {Control::Cancellable::Cancelled} when the flag is up)
    # @param interloper [Control::Interloper, nil] when set, the
    #   queue is drained on every +after_tool_result+, each item
    #   appended as a +role: :user+ message and emitted as
    #   {Event::UserTurn} with +mid_loop: true+
    # @return [void]
    def self.wire_chat(chat, listeners:, step_limit: nil, cancellable: nil, interloper: nil)
      chat.after_message do |msg|
        emit_after_message(msg, listeners)
      end
      chat.before_tool_call do |tc|
        listeners.emit(Event::ToolCall.new(name: tc.name, arguments: tc.arguments))
        step_limit&.tick!
        cancellable&.check!
      end
      chat.after_tool_result do |result|
        listeners.emit(Event::ToolResult.new(content: result))
        drain_interloper(interloper, chat, listeners) if interloper
      end
    end

    # Build the per-chunk streaming block passed to +Chat#ask+.
    # Each invocation of the returned proc converts one
    # +RubyLLM::Chunk+ into zero, one, or two delta events
    # ({Event::ThinkingDelta} / {Event::AssistantDelta}) on
    # +listeners+. Tool-call chunks are intentionally ignored —
    # partial JSON has no useful rendering; the assembled
    # +tool_calls+ surface through {Event::ToolCall} once the
    # message completes.
    #
    # Lives parallel to {.wire_chat} (instead of being folded into
    # it) because +Chat#ask+ takes the streaming block as an
    # argument rather than a registered callback, so both
    # {#run_loop} and {Synthesizer.run} pass it inline at the call
    # site with +&Agent.streaming_block(listeners: ..., cancellable: ...)+.
    #
    # == Cancellation polling
    #
    # When +cancellable+ is non-nil, {Control::Cancellable#check!}
    # fires *before* each chunk's emit. The +before_tool_call+
    # wiring in {.wire_chat} only fires when the model requests a
    # tool, which leaves a no-tool turn (e.g. a plain greeting)
    # with zero cancellation points — Ctrl+C trips the flag but
    # nothing reads it. Polling on every streamed chunk closes
    # that gap: an in-flight Cancellation+check! raises on the
    # next chunk delivered after the flag flips, the exception
    # propagates out through ruby_llm's streaming path
    # (+Chat#ask+ doesn't rescue), and {#run_loop} catches it,
    # emits {Event::Cancelled}, and re-raises. The pre-emit
    # ordering is deliberate: a chunk that arrives after a cancel
    # request shouldn't render — the user has said stop.
    #
    # @param listeners [ListenerList] the listener stream chunk
    #   events flow into
    # @param cancellable [Control::Cancellable, nil] when non-nil,
    #   polled on every chunk so a flag flipped mid-stream raises
    #   {Control::Cancellable::Cancelled} on the very next chunk
    # @return [Proc] a +-> (chunk) { ... }+ proc suitable for
    #   passing to +Chat#ask+ with +&+
    def self.streaming_block(listeners:, cancellable: nil)
      ->(chunk) {
        cancellable&.check!
        emit_chunk(chunk, listeners)
      }
    end

    # Normalize a +RubyLLM::Chat+ +after_message+ payload into
    # zero, one, or two {Event} variants (+Thinking+ and/or
    # +Assistant+) plus one {Event::Tokens} for the usage block.
    # Empty thinking / empty content are filtered here so
    # listeners never see vacuous events. Non-assistant roles
    # (e.g. tool-role messages echoed back through
    # +after_message+) are skipped entirely.
    #
    # +msg+ is a +RubyLLM::Message+. Beyond +role+, +content+,
    # +thinking+, and the +*_tokens+ accessors used here, it also
    # carries +msg.tool_calls+ on assistant turns that requested
    # one and +msg.raw+ for the unparsed provider payload.
    #
    # @param msg [RubyLLM::Message]
    # @param listeners [ListenerList]
    # @return [void]
    def self.emit_after_message(msg, listeners)
      return unless msg.role == :assistant

      text = msg.thinking&.text
      listeners.emit(Event::Thinking.new(content: text)) if text && !text.empty?

      content = msg.content
      listeners.emit(Event::Assistant.new(content: content)) if content.is_a?(String) && !content.empty?

      listeners.emit(Event::Tokens.new(
                       input: msg.input_tokens,
                       output: msg.output_tokens,
                       cached: msg.cached_tokens,
                       cache_creation: msg.cache_creation_tokens,
                       thinking: msg.thinking_tokens,
                       model_id: msg.model_id
                     ))
    end
    private_class_method :emit_after_message

    # Normalize a +RubyLLM::Chunk+ from a streaming +Chat#ask+
    # into zero, one, or two delta events
    # ({Event::ThinkingDelta} / {Event::AssistantDelta}). Empty
    # +thinking.text+ and empty +content+ are filtered here so
    # listeners never see vacuous fragments. Tool-call deltas are
    # intentionally skipped — see {.streaming_block}.
    #
    # +chunk+ is a +RubyLLM::Chunk+ (subclass of +RubyLLM::Message+),
    # so the same +.thinking+ / +.content+ accessors used in
    # {.emit_after_message} apply.
    #
    # @param chunk [RubyLLM::Chunk]
    # @param listeners [ListenerList]
    # @return [void]
    def self.emit_chunk(chunk, listeners)
      thinking = chunk.thinking&.text
      listeners.emit(Event::ThinkingDelta.new(content: thinking)) if thinking && !thinking.empty?

      content = chunk.content
      listeners.emit(Event::AssistantDelta.new(content: content)) if content.is_a?(String) && !content.empty?
    end
    private_class_method :emit_chunk

    # Drain the interloper queue: for each pending item, append a
    # +role: :user+ message to the chat history so the next
    # round-trip sees it, then emit an {Event::UserTurn} with
    # +mid_loop: true+ to the listener stream so renderers see
    # the injection.
    #
    # @param interloper [Control::Interloper]
    # @param chat [RubyLLM::Chat]
    # @param listeners [ListenerList]
    # @return [void]
    def self.drain_interloper(interloper, chat, listeners)
      interloper.drain!.each do |content|
        chat.add_message(role: :user, content: content)
        listeners.emit(Event::UserTurn.new(content: content, mid_loop: true))
      end
    end
    private_class_method :drain_interloper

    # One-shot inference. Builds a fresh +RubyLLM::Chat+ with no
    # tools, no MCP, no listeners, no step budget, asks +prompt+ as
    # the single user turn, and returns the assistant's reply as a
    # plain String. Lives parallel to {#initialize} / {#run_loop}
    # because the use case (e.g. summarizing an MCP server's tool
    # set into a short description block before any agent turn
    # runs) is genuinely one-shot — there is no loop, no tool
    # iteration, no listener stream.
    #
    # +prompt+ is sent as the user message. For a one-shot call
    # there is no behavioral difference between the system slot
    # and the user slot, so we use one parameter; pack any
    # "instructions + data" framing into +prompt+ directly.
    #
    # == Cancellation
    #
    # {Control::Cancellable#check!} fires once before the call and
    # once after, so a flag flipped right around the request
    # raises {Control::Cancellable::Cancelled} promptly. The
    # in-flight HTTP call itself is *not* interrupted — same
    # "gentle cancel" semantic the main loop offers (see
    # {Control::Cancellable}'s class header). For 30s synthesis
    # passes at boot this is still a useful escape hatch: the next
    # check raises and the call returns.
    #
    # == Failure
    #
    # Errors from the provider (HTTP failure, malformed response,
    # +RubyLLM+ raising) propagate to the caller verbatim — there
    # is no recovery layer here. Callers that want "fail soft on
    # synthesis errors" (e.g. {Mcp::Servers}) rescue at their level
    # and fall back to a default; this method stays loud.
    #
    # @param transport [ChatTransport] same model-resolution
    #   triple {#initialize} uses; if +model+ is +nil+, falls
    #   back to +RubyLLM.config.default_model+
    # @param prompt [String] the prompt sent as the single user
    #   turn; must be non-blank
    # @param cancellable [Control::Cancellable, nil] when set,
    #   checked before the call so a flag flipped right
    #   around the request raises {Control::Cancellable::Cancelled}
    # @return [String] the assistant's reply content
    # @raise [ArgumentError] when +prompt+ is +nil+, empty, or
    #   whitespace-only
    # @raise [Control::Cancellable::Cancelled] when the
    #   +cancellable+ flag was tripped at the pre-call check
    def self.think(transport:, prompt:, cancellable: nil)
      raise ArgumentError, "prompt must not be blank, got #{prompt.inspect}" \
        if prompt.nil? || prompt.to_s.strip.empty?

      transport = transport.with(model: RubyLLM.config.default_model) unless transport.model
      cancellable&.check!
      chat = RubyLLM.chat(**transport.to_h)
      chat.ask(prompt)
      last = chat.messages.reverse.find { |m| m.role == :assistant }
      last&.content.to_s
    end

    # @param transport [ChatTransport] the model-resolution triple
    #   (+model+ / +provider+ / +assume_model_exists+) forwarded
    #   to +RubyLLM.chat+. Bundled into one value object so every
    #   construction site — this constructor and the synthesizer
    #   rescue below — can forward all three with one assignment
    #   instead of three kwargs (where dropping one would silently
    #   route the chat elsewhere or raise
    #   +RubyLLM::ModelNotFoundError+). If +transport.model+ is
    #   +nil+, it's filled in from +RubyLLM.config.default_model+.
    # @param system_prompt [String] system message prepended to
    #   the chat
    # @param tools [Array<Tool>] pikuri tools registered with the
    #   underlying chat in declaration order. Each is converted
    #   to ruby_llm's runtime shape via {Tool#to_ruby_llm_tool}
    #   when wired in. Required — no default, because the tool
    #   set is a deliberate per-call decision (pass +[]+ for a
    #   tools-free agent).
    # @param listeners [ListenerList] the listener list whose
    #   listeners observe the event stream. Required — no
    #   default, because the renderer and capture choices are
    #   deliberate per-call decisions. Typical CLI shape:
    #   +ListenerList.new([Listener::Terminal.new, Listener::TokenLog.new])+.
    # @param step_limit [Control::StepLimit, nil] step budget
    #   control. When set, {Control::StepLimit#tick!} fires on
    #   every +before_tool_call+ and {Control::StepLimit#reset!}
    #   at the start of each turn. +nil+ means "no step budget"
    #   (the agent can loop indefinitely).
    # @param cancellable [Control::Cancellable, nil] cancellation
    #   control. When set, {Control::Cancellable#check!} fires on
    #   every +before_tool_call+ and
    #   {Control::Cancellable#reset!} at the start of each turn.
    #   +nil+ means "not cancellable" (the host has no way to
    #   stop a running turn except by killing the process).
    # @param interloper [Control::Interloper, nil] mid-loop
    #   user-input queue. When set, the queue is drained at
    #   every +after_tool_result+ and each item becomes a
    #   {Event::UserTurn} with +mid_loop: true+. +nil+ means
    #   "no mid-loop injection" (the bundled CLIs default).
    # @param context_window [Integer, nil] explicit override for
    #   the model's context-window cap. When set, it wins over
    #   ruby_llm's reported value and the llama.cpp probe — see
    #   {ContextWindowDetector} for precedence. Resolved cap is
    #   emitted as an {Event::ContextCap} immediately after
    #   construction.
    # @param llama_probe_url [String, nil] llama.cpp +/props+ URL
    #   used as the third detection source. Only consulted when
    #   neither +context_window+ nor ruby_llm's reported value is
    #   set. Typically derived by +bin/pikuri-chat+ from its
    #   configured +openai_api_base+; leave +nil+ when the
    #   configured server is anything other than llama.cpp.
    # @param name [String] identifier for this agent. Empty for
    #   the main agent; sub-agents get monotonic hierarchical
    #   names like +"sub_agent 0"+, +"sub_agent 1"+,
    #   +"sub_agent 0_0"+, ... generated by {Tool::SubAgent} from
    #   the parent's name + a per-parent counter. Forwarded to
    #   listeners through {ListenerList#for_sub_agent} so name-
    #   aware ones (notably {Listener::TokenLog}) can tag their
    #   output.
    # @param extensions [Array<Extension>, nil] pre-configured
    #   extension instances inherited from a parent agent. Used
    #   exclusively by {Tool::SubAgent.execute} when spawning a
    #   child; the child Agent calls +bind(self)+ on each but does
    #   NOT re-run +configure+ — the parent already drove configure,
    #   and the resulting state (tools / snippets / listeners) was
    #   inherited verbatim through the explicit kwargs (+tools:+,
    #   +system_prompt:+, +listeners:+). Main-agent callers leave
    #   this +nil+ and use the +Agent.new+ block's
    #   {Configurator#add_extension} for any extensions they want
    #   (Skills, MCP, custom hosts).
    # @param streaming [Boolean] opt into chunk-level streaming.
    #   When +true+, {#run_loop} passes the block returned by
    #   {.streaming_block} to +Chat#ask+, and ruby_llm requests
    #   SSE responses from the provider — chunks are normalized
    #   into {Event::ThinkingDelta} / {Event::AssistantDelta} on
    #   the listener stream as they arrive. When +false+ (the
    #   default), +Chat#ask+ runs in single-shot mode and only
    #   the message-level {Event::Thinking} / {Event::Assistant}
    #   bookends fire from +after_message+. Read by
    #   {Tool::SubAgent} so spawned sub-agents inherit the same
    #   mode without an extra kwarg.
    # @return [Agent]
    def initialize(transport:, system_prompt:, tools: [], listeners: nil,
                   step_limit: nil, cancellable: nil, interloper: nil,
                   context_window: nil, llama_probe_url: nil, name: '',
                   streaming: false,
                   extensions: nil,
                   &block)
      # +listeners:+ used to be required; with the block API it
      # defaults to an empty +ListenerList+ so the new shape
      # (+Agent.new(transport: ..., system_prompt: ...) { |c|
      # c.add_listener(...) }+) doesn't need the kwarg.
      listeners ||= ListenerList.new([])

      @transport = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      @cancellable = cancellable
      @closed = false

      @system_prompt = system_prompt
      @tools = tools.dup
      @listeners = listeners
      @step_limit = step_limit
      @interloper = interloper
      @name = name
      @streaming = streaming
      @synth_answer = nil
      @on_close_handlers = []
      # Inherited extensions arrive pre-configured (the parent
      # already drove +configure+ and the resulting tools / snippets
      # / listeners were inherited verbatim via the explicit kwargs
      # above). They will be re-bound to this agent below; they do
      # NOT re-run +configure+. Used exclusively by
      # {Tool::SubAgent.execute} for sub-agent construction; main-
      # agent callers leave +extensions:+ unset.
      @extensions = extensions ? extensions.dup : []

      # Single Configurator funnel for everything the block adds.
      # See IDEAS.md §"Extension protocol design".
      configurator = Configurator.new(
        transport: @transport,
        system_prompt_base: system_prompt,
        name: @name,
        streaming: @streaming,
        step_limit: @step_limit,
        cancellable: @cancellable,
        interloper: @interloper
      )

      block&.call(configurator)

      @tools.concat(configurator.tools)
      # Only call #with when there's something to merge — the
      # listener kwarg is duck-typed (any object responding to
      # +emit+ + +for_sub_agent+ works, see Tool::SubAgent specs),
      # and we don't want to force every duck implementation to
      # also provide +with+.
      @listeners = @listeners.with(*configurator.listeners) if configurator.listeners.any?
      configurator.system_prompt_additions.each do |snippet|
        @system_prompt = "#{@system_prompt}\n\n#{snippet}"
      end
      @on_close_handlers.concat(configurator.on_close_handlers)
      @extensions.concat(configurator.extensions)

      @chat = RubyLLM.chat(**@transport.to_h)
      @chat.with_instructions(@system_prompt)
      @tools.each { |t| @chat.with_tool(t.to_ruby_llm_tool) }

      @context_window_cap = ContextWindowDetector.new(
        override: context_window,
        ruby_llm_reported: @chat.model.context_window,
        llama_probe_url: llama_probe_url
      ).detect

      self.class.wire_chat(
        @chat,
        listeners: @listeners,
        step_limit: @step_limit,
        cancellable: @cancellable,
        interloper: @interloper
      )

      # One-shot context-window cap: lets every listener that
      # cares (notably TokenLog) pick the value off the stream
      # before any Tokens event arrives.
      @listeners.emit(Event::ContextCap.new(cap: @context_window_cap))

      # Sub-agent tool: constructed *after* @tools is final and
      # @context_window_cap is set, so its snapshot of the parent's
      # tool list doesn't include itself (recursion guard) and the
      # cap can be threaded through to spawned sub-agents. The new
      # +Tool::SubAgent+ instance is appended to both +@tools+ and
      # +@chat+, so sub-agents inheriting via the snapshot still
      # get the surrounding tool set but never the +sub_agent+ tool
      # itself. See {Configurator#allow_sub_agent}.
      if configurator.sub_agent_request
        if @tools.any?(Tool::SubAgent)
          raise 'Tool::SubAgent cannot be passed in tools: when allow_sub_agent is used; ' \
                'Agent auto-registers it from the Configurator request.'
        end

        sub_tool = Tool::SubAgent.new(self, max_steps: configurator.sub_agent_request.max_steps)
        @tools << sub_tool
        @chat.with_tool(sub_tool.to_ruby_llm_tool)
      end

      # Bind sweep — each extension gets its chance to install
      # per-agent state (dynamic tools via #internal_add_tool,
      # per-agent close hooks via #on_close, etc.) now that the
      # chat is fully wired. See IDEAS.md §"Extension protocol
      # design" for what #configure vs #bind are each for.
      @extensions.each { |ext| ext.bind(self) }

      # Fallback cleanup: if the host forgets to call #close, the
      # at_exit hook fires it on process exit. Idempotent, so an
      # explicit close earlier makes this a no-op. The closure
      # captures self, which keeps the agent reachable until
      # process exit — fine for the handful of agents a typical
      # host creates; if pikuri grows a long-running host that
      # constructs many short-lived agents, switch to a single
      # process-global registry that close-then-removes.
      at_exit { close }
    end

    # @return [RubyLLM::Chat] underlying chat; the extension seam
    attr_reader :chat

    # @return [ChatTransport] the resolved transport bundle this
    #   agent was constructed with — same model id / provider /
    #   assume-model-exists flag passed to every +RubyLLM.chat+
    #   call originating from this agent (the main chat, the
    #   synthesizer rescue, the sub-agent tool). Read by
    #   {Tool::SubAgent} so spawned sub-agents reuse the same
    #   transport.
    attr_reader :transport

    # @return [Array<Tool>] this agent's tool list in declaration
    #   order. Snapshotted by {Tool::SubAgent} so spawned
    #   sub-agents inherit the parent's tools (minus the
    #   sub-agent tool itself, which {#allow_sub_agent} appends
    #   to +@tools+ only after the snapshot has been taken —
    #   recursion guard).
    attr_reader :tools

    # @return [String] resolved model id from {#transport}.
    #   Convenience delegator for callers that don't need the
    #   full transport bundle.
    def model
      @transport.model
    end

    # @return [String] system prompt actually sent to the chat —
    #   equal to the constructor's +system_prompt:+ argument plus
    #   any snippets appended by extensions during
    #   {Configurator#append_system_prompt} (Skills'
    #   +<available_skills>+, MCP's +<available_mcps>+, ...).
    #   {Tool::SubAgent} forwards this already-augmented value to
    #   spawned sub-agents so they see the same advertisements
    #   without re-running extension configure.
    attr_reader :system_prompt

    # @return [ListenerList] the listener list attached to this
    #   agent's chat
    attr_reader :listeners

    # @return [Control::StepLimit, nil] the step-budget control
    #   this agent was constructed with, or +nil+ when none.
    #   Read by {Tool::SubAgent} so spawned sub-agents derive
    #   their own.
    attr_reader :step_limit

    # @return [Control::Cancellable, nil] the cancellation
    #   control this agent was constructed with, or +nil+ when
    #   none. Read by {Tool::SubAgent} so spawned sub-agents
    #   share the same instance.
    attr_reader :cancellable

    # @return [Control::Interloper, nil] the mid-loop user-input
    #   control this agent was constructed with, or +nil+ when
    #   none. Not propagated to sub-agents — see
    #   {Control::Interloper#for_sub_agent}.
    attr_reader :interloper

    # @return [String] this agent's identifier — empty for the
    #   main agent; for sub-agents, the hierarchical id assigned
    #   by {Tool::SubAgent} (e.g. +"sub_agent 0"+,
    #   +"sub_agent 1"+, +"sub_agent 0_0"+). Read by the
    #   sub-agent tool so spawned sub-agents prefix their own
    #   names with this one, and propagated to listeners via
    #   {ListenerList#for_sub_agent} so name-aware ones can tag
    #   output.
    attr_reader :name

    # @return [Boolean] +true+ when this agent opted into
    #   chunk-level streaming (see the +streaming:+ kwarg on
    #   {#initialize}); +false+ otherwise. Read by
    #   {Tool::SubAgent} so spawned sub-agents inherit the same
    #   mode.
    attr_reader :streaming

    # @return [Array<Extension>] extension instances bound to this
    #   agent — inherited via the +extensions:+ kwarg (for
    #   sub-agents) plus any added via {Configurator#add_extension}
    #   inside the +Agent.new+ block. Read by {Tool::SubAgent} so
    #   spawned sub-agents inherit the parent's extension list and
    #   re-bind them via the bind sweep.
    attr_reader :extensions

    # @return [Integer, nil] context-window cap resolved by
    #   {ContextWindowDetector} at construction time. +nil+ when
    #   no source produced a value (custom local model with no
    #   override and no reachable llama.cpp +/props+). Read by
    #   {Tool::SubAgent} so spawned sub-agents inherit the same
    #   cap without re-probing.
    attr_reader :context_window_cap

    # Final assistant message content for the most recent
    # {#run_loop}. When the synthesizer rescue fired, returns its
    # answer; otherwise walks the underlying chat's history.
    # Returns +nil+ if neither source has produced an assistant
    # turn yet.
    #
    # @return [String, nil]
    def last_assistant_content
      return @synth_answer if @synth_answer

      last = @chat.messages.reverse.find { |m| m.role == :assistant }
      last&.content
    end

    # Run the agent loop for a single user turn. Emits an
    # {Event::UserTurn} with +mid_loop: false+, resets the
    # step-budget and cancellation controls (so a stale state
    # from a prior turn doesn't poison this one), and forwards
    # +user_message+ to {#chat} via +ask+. Returns nil; rendering
    # and any other observable output is the listeners'
    # responsibility.
    #
    # If the +step_limit+ control trips during +ask+, the rescue
    # branch emits an {Event::FallbackNotice} and runs
    # {Synthesizer.run} on a fresh +RubyLLM::Chat+. The synth's
    # answer is captured for {#last_assistant_content}; the
    # exception does not bubble out.
    #
    # If the +cancellable+ control trips during +ask+, the rescue
    # branch emits an {Event::Cancelled} and re-raises the
    # +Cancelled+ exception. No synthesizer fallback runs — see
    # the "Cancellation rescue" section in the class header.
    #
    # Subsequent calls keep building on the same chat history, so
    # the model sees full multi-turn context.
    #
    # @param user_message [String] the user's request for this
    #   turn; must not be +nil+, empty, or whitespace-only
    # @raise [ArgumentError] if +user_message+ is +nil+, empty,
    #   or contains only whitespace — an empty turn would poison
    #   the chat history and burn a step budget on nothing
    # @raise [Control::Cancellable::Cancelled] if the registered
    #   {Control::Cancellable} was triggered during the turn;
    #   the listener stream sees an {Event::Cancelled} first
    # @return [nil]
    def run_loop(user_message:)
      raise ArgumentError, "user_message must not be blank, got #{user_message.inspect}" \
        if user_message.nil? || user_message.to_s.strip.empty?

      @synth_answer = nil
      @listeners.emit(Event::UserTurn.new(content: user_message, mid_loop: false))
      @step_limit&.reset!
      @cancellable&.reset!
      if @streaming
        @chat.ask(user_message, &self.class.streaming_block(listeners: @listeners, cancellable: @cancellable))
      else
        @chat.ask(user_message)
      end
      nil
    rescue Control::Cancellable::Cancelled
      @listeners.emit(Event::Cancelled.new)
      raise
    rescue Control::StepLimit::Exceeded => e
      @listeners.emit(Event::FallbackNotice.new(
                        reason: "agent exhausted #{e.max_steps} steps; synthesizing answer from gathered evidence"
                      ))

      # Synth runs under this agent's identity but on a fresh
      # chat with a different system prompt, so it gets a
      # distinct +_synthesizer+ suffix on the name — same +_+
      # separator the sub-agent generator uses, so main becomes
      # +"synthesizer"+ and a sub-agent +"sub_agent 0"+ becomes
      # +"sub_agent 0_synthesizer"+. Any +TokenLog+ in the list
      # tags the synth's prompt under that bracket so it's
      # obvious from the log which turns were the rescue rather
      # than the original loop.
      synth_name = @name.empty? ? 'synthesizer' : "#{@name}_synthesizer"
      synth_chat = RubyLLM.chat(**@transport.to_h)
      # Defensive step limit on the synth: the synth has no
      # tools so it should never trip +before_tool_call+, but
      # guarding the budget anyway means a buggy provider that
      # somehow returns a tool call doesn't loop forever.
      synth_step_limit = @step_limit && Control::StepLimit.new(max: 1)
      @synth_answer = Synthesizer.run(
        chat: synth_chat,
        parent_messages: @chat.messages,
        user_message: user_message,
        listeners: @listeners.for_sub_agent(name: synth_name),
        step_limit: synth_step_limit,
        cancellable: @cancellable,
        streaming: @streaming
      )
      nil
    end

    # Release agent-owned resources. Fires every handler registered
    # via {Configurator#on_close} (during the +Agent.new+ block) and
    # {#on_close} (during {Extension#bind} or any post-construction
    # call), in LIFO order — matches Ruby +ensure+-block semantics
    # so handlers registered later (which may depend on handlers
    # registered earlier) tear down first. Each handler runs inside
    # its own +rescue+; an exception is logged via
    # +Pikuri.logger_for+ but doesn't abort the rest. Idempotent —
    # subsequent calls are no-ops.
    #
    # @return [void]
    def close
      return if @closed

      @closed = true
      @on_close_handlers.reverse_each do |handler|
        handler.call
      rescue StandardError => e
        LOGGER.warn("on_close handler raised #{e.class}: #{e.message}")
      end
    end

    # Register a handler called by {#close}. Symmetric to
    # {Configurator#on_close} — same LIFO + per-handler-rescue +
    # idempotent semantics — but available post-construction, so
    # an {Extension}'s +bind(agent)+ can install per-agent cleanup
    # that's keyed to this specific agent rather than the parent.
    #
    # @yield called with no arguments at close time
    # @return [void]
    def on_close(&blk)
      raise ArgumentError, 'on_close requires a block' unless block_given?

      @on_close_handlers << blk
      nil
    end

    # Register a raw +RubyLLM::Tool+ subclass on this agent's
    # underlying chat, bypassing the {Pikuri::Tool} strict-validation
    # seam. Sole intended caller: {Mcp::Servers::Connect}, which uses
    # this to lazy-add MCP-exposed tools after the LLM invokes
    # +mcp_connect+ in a turn.
    #
    # The +internal_+ prefix is the warning: native pikuri tools
    # should go through {Pikuri::Tool} so they get
    # {Tool::Parameters} validation and the LLM-actionable
    # +"Error: ..."+ contract. MCP tools deliberately don't — see
    # IDEAS.md §"v1 implementation shape" / "MCP tools bypass
    # +Pikuri::Tool+ entirely."
    #
    # The added tool does NOT enter +@tools+, only +@chat+'s tool
    # list. {Tool::SubAgent} therefore cannot snapshot it (which is
    # the whole point — activation is strictly per-agent, see
    # IDEAS.md §"Per-agent activation, no propagation").
    #
    # @param ruby_llm_tool [Class] subclass of +RubyLLM::Tool+
    # @return [void]
    def internal_add_tool(ruby_llm_tool)
      @chat.with_tool(ruby_llm_tool)
    end

    # Short, single-line config dump suitable for a startup
    # banner or a debug print.
    #
    # @example
    #   agent.to_s
    #   # => "Agent(model=qwen3-35b, tools=4, listeners=[Terminal])"
    #
    # @return [String]
    def to_s
      "Agent(model=#{model}, tools=#{@tools.size}, listeners=#{@listeners})"
    end
  end
end
