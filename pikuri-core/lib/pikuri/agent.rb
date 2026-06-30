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
  #    — pure consumers of the event stream; they never write back.
  #    The +Agent+ emits every loop-narration {Event} variant;
  #    extensions emit their own domain events through the
  #    {ExtensionContext} capability facade handed to
  #    {Extension#bind}. There is no public path from an +Agent+
  #    reference to emission — no +listeners+ reader, no +chat+
  #    reader, no emit method — so holding an agent grants read
  #    access to its configuration and nothing more. New rendering
  #    or capture targets (a web sink, a structured log) are added
  #    as listeners without touching {Agent}.
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
  # single grep for +@listeners.emit+ in this file (loop narration)
  # plus the capability calls in {ExtensionContext} (domain events).
  #
  # == Step-exhaustion policy
  #
  # If the +step_limit:+ {Control::StepLimit} trips during
  # completion, {#run_loop} catches the +Exceeded+ exception and
  # applies the budget's {Control::StepLimit#on_exhausted} policy
  # (see that class header for how hosts pick):
  #
  # - +:raise+ (the default) — re-raise to the host, same shape as
  #   the cancellation rescue below. The chat history survives and
  #   {Control::StepLimit#reset!} fires at the next turn boundary,
  #   so a REPL user can simply say "continue".
  # - +:synthesize+ — emit an {Event::FallbackNotice} and run the
  #   {Synthesizer} prompt on a nested tools-free +Agent+ (the
  #   same construction shape the +agent+ tool from
  #   +pikuri-subagents+ uses for sub-agents): parent's listener
  #   stream derived via {ListenerList#for_sub_agent} (Terminal
  #   padded, TokenLog zeroed, recorder shared by reference),
  #   parent's +cancellable+ shared so a user cancel during
  #   synthesis still works, a defensive +step_limit+ at +max: 1+
  #   (the synth has no tools and shouldn't tick it). The synth's
  #   answer becomes the value reported by
  #   {#last_assistant_content}, so callers (notably the +agent+
  #   tool from +pikuri-subagents+) still get a usable reply.
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

    # @param transport [ChatTransport] the model-resolution bundle
    #   (+model+ / +provider+ / +assume_model_exists+ and, for a model
    #   on a non-global server, +api_base+ / +api_key+) the chat is
    #   built from. Bundled into one value object so every construction
    #   site — this constructor, the synthesizer rescue below, a
    #   mid-conversation switch — can forward it with one assignment
    #   instead of loose kwargs (where dropping one would silently
    #   route the chat elsewhere or raise
    #   +RubyLLM::ModelNotFoundError+). If +transport.model+ is
    #   +nil+, it's filled in from +RubyLLM.config.default_model+.
    # @param system_prompt [String] base system message. The chat's
    #   actual instructions are this base plus every extension's
    #   {Extension#system_prompt_snippets} (e.g. +<available_skills>+,
    #   +<available_mcps>+), assembled by {#assemble_system_prompt} at
    #   construction and re-assembled on {#clear_conversation}.
    # @param step_limit [Control::StepLimit, nil] step budget
    #   control. When set, {Control::StepLimit#tick!} fires on
    #   every +before_tool_call+ and {Control::StepLimit#reset!}
    #   at the start of each turn; the budget's
    #   {Control::StepLimit#on_exhausted} policy decides what
    #   {#run_loop} does when it trips (see "Step-exhaustion
    #   policy" in the class header). +nil+ means "no step budget"
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
    # @param id [String] unique identifier for this agent. Empty
    #   for the main agent; sub-agents get persona-rooted ids
    #   like +"researcher 0"+, +"researcher 1"+, +"file_miner 0"+, ...
    #   generated by the +agent+ tool from +pikuri-subagents+ from
    #   the persona name + a per-persona counter. Forwarded to
    #   listeners through {ListenerList#for_sub_agent} so id-aware
    #   ones (notably {Listener::TokenLog}) can tag their output.
    #   The word "id" is deliberate — "name" is reserved throughout
    #   the codebase for the persona-name load (the value the LLM
    #   picks in the +agent+ tool's +name:+ argument).
    # @param streaming [Boolean] opt into chunk-level streaming.
    #   When +true+, {#run_loop} passes a per-chunk block to
    #   +Chat#complete+, and ruby_llm requests
    #   SSE responses from the provider — chunks are normalized
    #   into {Event::ThinkingDelta} / {Event::AssistantDelta} on
    #   the listener stream as they arrive. When +false+ (the
    #   default), +Chat#ask+ runs in single-shot mode and only
    #   the message-level {Event::Thinking} / {Event::Assistant}
    #   bookends fire from +after_message+. Read by the +agent+
    #   tool from +pikuri-subagents+ so spawned sub-agents inherit
    #   the same mode without an extra kwarg.
    # @yield [Configurator] yields a {Configurator} that collects
    #   tools (via {Configurator#add_tool} / {Configurator#add_tools}),
    #   listeners (via {Configurator#add_listener} /
    #   {Configurator#add_listeners}), extension instances
    #   (via {Configurator#add_extension} — which fires +configure+
    #   immediately), and close handlers (via
    #   {Configurator#on_close}). System-prompt contributions are not
    #   pushed here — they are pulled from each extension's
    #   {Extension#system_prompt_snippets} at assembly time. The
    #   Configurator is the *only*
    #   path for adding any of these — there are no parallel ctor
    #   kwargs. The block is optional; an agent constructed without
    #   one has no tools, no listeners, no extensions.
    # @return [Agent]
    def initialize(transport:, system_prompt:,
                   step_limit: nil, cancellable: nil, interloper: nil,
                   id: '',
                   streaming: false,
                   &block)
      @transport = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      @cancellable = cancellable
      @closed = false

      # The raw constructor prompt, kept separate from the assembled
      # +@system_prompt+ so {#assemble_system_prompt} can recompute the
      # full prompt (base + each extension's {Extension#system_prompt_snippets})
      # from scratch — at construction and again on every
      # {#clear_conversation}, which is what lets dynamic sections refresh.
      @system_prompt_base = system_prompt
      @system_prompt = system_prompt
      @step_limit = step_limit
      @interloper = interloper
      @id = id
      @streaming = streaming
      @synth_answer = nil
      @on_close_handlers = []
      # Stashed for {#run_configure}, which runs the failure-prone
      # build phase below out of a separate method.
      @block = block

      # Register *before* the build phase so a mid-construction raise
      # is still recoverable: extensions arm their cleanup via
      # +c.on_close+ (which writes straight to +@on_close_handlers+,
      # see {Configurator}), and the rescue below fires whatever was
      # armed before the failure. On the happy path this registration
      # is the at-exit backstop if the host forgets {#close}; an
      # explicit {#close} unregisters, so the agent isn't pinned alive
      # until process exit.
      Pikuri::Finalizers.register(self)

      begin
        run_configure
      rescue StandardError
        # Half-built agent (e.g. an extension's +configure+ raised
        # Cancelled mid-spawn). Fire the handlers armed so far, drop
        # out of the registry, and re-raise — no partial state leaks.
        close
        raise
      end
    end

    # @return [ChatTransport] the resolved transport bundle this
    #   agent was constructed with — same model id / provider /
    #   assume-model-exists flag passed to every +RubyLLM.chat+
    #   call originating from this agent (the main chat, the
    #   synthesizer rescue, the +agent+ tool from
    #   +pikuri-subagents+). Read by extensions that need to spawn
    #   their own ruby_llm calls (e.g. MCP description synthesis,
    #   sub-agent delegation).
    attr_reader :transport

    # @return [Array<Tool>] this agent's tool list in declaration
    #   order. Read by extensions that filter against it (notably
    #   the +agent+ tool from +pikuri-subagents+, which picks the
    #   sub-agent's toolset from the parent's instances so any
    #   already-bound workspace/confirmer wiring travels along).
    #   Tools listed here are also the ones registered with
    #   ruby_llm — the parent LLM can call any of them. Compare
    #   with {#sub_agent_tools}.
    attr_reader :tools

    # @return [Array<Tool>] tools registered via
    #   {Configurator#add_sub_agent_tool}, in declaration order.
    #   Invisible to the parent LLM (never sent to ruby_llm);
    #   available only to sub-agents whose persona +tool_names+
    #   match. See {Configurator}'s "Two tool pools" header for
    #   the trifecta-defense rationale.
    attr_reader :sub_agent_tools

    # @return [String] resolved model id from {#transport}.
    #   Convenience delegator for callers that don't need the
    #   full transport bundle.
    def model
      @transport.model
    end

    # @return [String] system prompt actually sent to the chat —
    #   the assembled result of the constructor's +system_prompt:+
    #   argument plus every extension's {Extension#system_prompt_snippets}
    #   (extensions' +<available_skills>+ / +<available_mcps>+ /
    #   +<available_agents>+, a resident memory persona, ...). Re-assembled
    #   on {#clear_conversation}, so a dynamic section may differ from its
    #   construction-time value. Not inherited by sub-agents — each persona
    #   owns its own system prompt verbatim. See {#assemble_system_prompt}.
    attr_reader :system_prompt

    # @return [Control::StepLimit, nil] the step-budget control
    #   this agent was constructed with, or +nil+ when none.
    attr_reader :step_limit

    # @return [Control::Cancellable, nil] the cancellation
    #   control this agent was constructed with, or +nil+ when
    #   none. Read by extensions that propagate cancellation to
    #   their own LLM calls (e.g. the +agent+ tool from
    #   +pikuri-subagents+ shares it with spawned sub-agents so
    #   one Ctrl+C stops the tree).
    attr_reader :cancellable

    # @return [Control::Interloper, nil] the mid-loop user-input
    #   control this agent was constructed with, or +nil+ when
    #   none.
    attr_reader :interloper

    # @return [String] this agent's unique identifier — empty for
    #   the main agent; for sub-agents, the persona-rooted id
    #   assigned by the +agent+ tool from +pikuri-subagents+ (e.g.
    #   +"researcher 0"+, +"researcher 1"+, +"file_miner 0"+).
    #   Propagated to listeners via {ListenerList#for_sub_agent(id:)}
    #   so id-aware ones can tag output. Distinct from the persona's
    #   +name+ (the value the LLM picks in the +agent+ tool's
    #   +name:+ argument).
    attr_reader :id

    # @return [Boolean] +true+ when this agent opted into
    #   chunk-level streaming (see the +streaming:+ kwarg on
    #   {#initialize}); +false+ otherwise. Read by extensions that
    #   spawn their own ruby_llm calls (notably the +agent+ tool
    #   from +pikuri-subagents+, so spawned sub-agents inherit the
    #   same mode).
    attr_reader :streaming

    # @return [Array<Extension>] extension instances bound to this
    #   agent — added via {Configurator#add_extension} inside the
    #   +Agent.new+ block. Each instance's +configure+ runs during
    #   the block and its +bind+ runs at the end of
    #   {#initialize}, once per registration (so once per parent
    #   agent in the typical setup; sub-agents do not inherit
    #   extensions).
    attr_reader :extensions

    # @return [Integer, nil] resolved context-window cap — the
    #   {ChatTransport#context_window} if one was given, else what
    #   {ContextWindowDetector} probed. +nil+ when neither produced
    #   a value (a non-llama server with no explicit cap). Re-resolved
    #   on every model switch (see {#run_loop}'s +transport:+). Read by
    #   extensions that spawn their own ruby_llm calls (notably the
    #   +agent+ tool from +pikuri-subagents+, which hands a sub-agent
    #   +parent.transport.with(context_window: this)+ so the resolved
    #   cap rides along without a re-probe).
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
    # If the +step_limit+ control trips during completion, the
    # rescue branch applies its {Control::StepLimit#on_exhausted}
    # policy: +:raise+ re-raises the +Exceeded+ exception to the
    # host (chat history intact — the next turn's +reset!+
    # refreshes the budget, so "continue" just works);
    # +:synthesize+ emits an {Event::FallbackNotice} and runs the
    # {Synthesizer} prompt on a nested tools-free agent, capturing
    # its answer for {#last_assistant_content}. See
    # "Step-exhaustion policy" in the class header.
    #
    # If the +cancellable+ control trips during +ask+, the rescue
    # branch emits an {Event::Cancelled} and re-raises the
    # +Cancelled+ exception. No synthesizer fallback runs — see
    # the "Cancellation rescue" section in the class header.
    #
    # Subsequent calls keep building on the same chat history, so
    # the model sees full multi-turn context.
    #
    # == Switching models mid-conversation
    #
    # Passing a +transport:+ that differs from the current one
    # switches the underlying chat to that model — via
    # +Chat#with_model+, so the history and the registered
    # callbacks survive — re-resolves the context-window cap, and
    # emits an {Event::ModelSwitched} followed by a fresh
    # {Event::ContextCap}. The switch is deliberately confined to
    # the top of this method (a private +apply_transport!+) rather
    # than exposed as a standalone setter: the chat is
    # single-thread-confined, so doing it here serializes the swap
    # with the turn on the loop's own thread — a background thread
    # mutating +with_model+'s connection mid-completion would tear
    # an in-flight stream. A +nil+ +transport:+ (the default) keeps
    # the current model. The conversation is *not* re-baselined: a
    # switch is the same conversation under a new model, so the
    # message count and running context size carry over (the next
    # turn's token report self-corrects to the new model's count).
    #
    # @param user_message [String] the user's request for this
    #   turn; must not be +nil+, empty, or whitespace-only
    # @param transport [ChatTransport, nil] when non-+nil+ and
    #   structurally different from the current transport, switch to
    #   it before running the turn (see above); +nil+ keeps the
    #   current model
    # @raise [ArgumentError] if +user_message+ is +nil+, empty,
    #   or contains only whitespace — an empty turn would poison
    #   the chat history and burn a step budget on nothing
    # @raise [Control::Cancellable::Cancelled] if the registered
    #   {Control::Cancellable} was triggered during the turn;
    #   the listener stream sees an {Event::Cancelled} first
    # @raise [Control::StepLimit::Exceeded] if the step budget
    #   tripped and its policy is +:raise+ (the default)
    # @return [nil]
    def run_loop(user_message:, transport: nil)
      raise ArgumentError, "user_message must not be blank, got #{user_message.inspect}" \
        if user_message.nil? || user_message.to_s.strip.empty?

      apply_transport!(transport) if transport
      @synth_answer = nil
      @step_limit&.reset!
      @cancellable&.reset!
      # Append the user turn, emit it, then run the memory dispatch — so
      # any <memory-context> the dispatch injects lands as a :system
      # message *after* the user turn it annotates (append-only at the
      # tail; see {#dispatch_ext_on_user_message}). `ask` would bundle the
      # user-message append with completion atomically, leaving no seam to
      # inject between them, so the two halves run explicitly here:
      # add_message + complete (the exact pair `ask` is sugar for). A raw
      # String content matches the interloper drain path.
      @chat.add_message(role: :user, content: user_message)
      @listeners.emit(Event::UserTurn.new(content: user_message, mid_loop: false))
      dispatch_ext_on_user_message(user_message)
      if @streaming
        @chat.complete(&streaming_block)
      else
        @chat.complete
      end
      nil
    rescue Control::Cancellable::Cancelled
      @listeners.emit(Event::Cancelled.new)
      raise
    rescue Control::StepLimit::Exceeded => e
      raise unless @step_limit&.on_exhausted == :synthesize

      @synth_answer = Synthesizer.run_synthesizer(@extension_context, @chat.messages, user_message)
      nil
    end

    # Clear the conversation log, returning this agent to a
    # fresh-conversation state *without* tearing down its wiring — the
    # host "/clear". Distinct from {#close}, which fires the teardown
    # handlers (killing MCP subprocesses, docker-backed servers, the
    # memory worker); +clear_conversation+ keeps every one of those
    # alive and only resets what belongs to the conversation that just
    # ended. It is the cheap counterpart to building a new {Agent}:
    # nothing is re-probed, re-synthesized, or re-connected.
    #
    # What it resets, in order:
    #
    # 1. The chat history, via +Chat#reset_messages!+ — which also
    #    drops the mid-conversation +:system+ injections (memory
    #    +<memory-context>+ blocks land as +:system+) — then re-applies
    #    a freshly **re-assembled** system prompt via +with_instructions+.
    #    Re-assembly ({#assemble_system_prompt}) re-pulls every
    #    extension's {Extension#system_prompt_snippets}, so *dynamic*
    #    sections refresh — a resident memory persona re-fetched from the
    #    store, +MACHINE.md+ re-read from disk — while static sections and
    #    the base prompt are reproduced unchanged. (This is why a clear
    #    does the dynamic sections' I/O; an expensive one-shot source is
    #    expected to memoize so the re-pull is free.) The registered
    #    callbacks and tool registrations live on the same reused +@chat+
    #    object and are untouched.
    # 2. The controls — +@step_limit+ / +@cancellable+ reset, the
    #    interloper queue drained (stale mid-loop input from the old
    #    conversation must not leak into the new one), and the cached
    #    synthesizer answer dropped.
    # 3. The listener stream, via a single {Event::Reset} — so
    #    pure-consumer listeners reset their display state
    #    ({Listener::TokenLog} zeroes its running context-size
    #    snapshot; a chrome can print a separator).
    # 4. Extension-owned state, via {Extension#on_conversation_reset}
    #    on every extension — the tasks list clears (emitting
    #    +Tasks::ListChanged+), the workspace read-record clears.
    #    Infrastructure extensions inherit the no-op default and keep
    #    running.
    #
    # The model and transport are left as-is: a clear is a fresh
    # conversation with the *same* model, not a model switch. Safe to
    # call between turns on the agent's own thread; not designed to race
    # an in-flight {#run_loop} (the chat is single-thread-confined, same
    # as a mid-conversation model switch).
    #
    # @return [void]
    def clear_conversation
      @chat.reset_messages!
      @system_prompt = assemble_system_prompt
      @chat.with_instructions(@system_prompt)
      @synth_answer = nil
      @step_limit&.reset!
      @cancellable&.reset!
      @interloper&.drain!
      @listeners.emit(Event::Reset.new)
      @extensions.each { |ext| ext.on_conversation_reset(@extension_context) }
      nil
    end

    # Release agent-owned resources. Fires every handler registered
    # via {Configurator#on_close} (during the +Agent.new+ block) and
    # {ExtensionContext#on_close} (during {Extension#bind} or any
    # later hook), in LIFO order — matches Ruby +ensure+-block semantics
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
      # Drop out of the process-global registry first: a deliberate
      # close means this agent no longer needs the at-exit fallback,
      # and removing the reference lets it be garbage-collected.
      Pikuri::Finalizers.unregister(self)
      @on_close_handlers.reverse_each do |handler|
        handler.call
      rescue StandardError => e
        LOGGER.warn("on_close handler raised #{e.class}: #{e.message}")
      end
    end

    # Short, single-line config dump suitable for a startup
    # banner or a debug print.
    #
    # @example
    #   agent.to_s
    #   # => "Agent(id=, model=qwen3-35b, tools=4, listeners=[Terminal])"
    #
    # @return [String]
    def to_s
      "Agent(id=#{@id}, model=#{model}, tools=#{@tools.size}, listeners=#{@listeners})"
    end

    private

    # The failure-prone build phase, split out of {#initialize} so the
    # constructor can wrap it in a rescue and self-heal. Funnels the
    # +Agent.new+ block through a single {Configurator} — tools,
    # listeners, system-prompt snippets, extensions, and +on_close+
    # handlers — then wires the chat and runs the extension +bind+
    # sweep. The Configurator's +on_close_sink:+ is +@on_close_handlers+
    # itself, so a handler an extension arms via +c.on_close+ is live on
    # the agent the instant it's registered — that's what lets the
    # constructor's rescue close a half-built agent.
    #
    # @return [void]
    def run_configure
      configurator = Configurator.new(
        transport: @transport,
        system_prompt_base: @system_prompt,
        id: @id,
        streaming: @streaming,
        step_limit: @step_limit,
        cancellable: @cancellable,
        interloper: @interloper,
        on_close_sink: @on_close_handlers
      )

      @block&.call(configurator)

      @tools = configurator.tools.dup
      @sub_agent_tools = configurator.sub_agent_tools.dup
      @listeners = ListenerList.new(configurator.listeners)
      @extensions = configurator.extensions.dup
      # Assemble the prompt now that every extension's +configure+ has
      # run (so the state their snippets read is populated). The same
      # call re-runs on {#clear_conversation} to refresh dynamic sections.
      @system_prompt = assemble_system_prompt

      @chat = build_chat(@transport)
      @chat.with_instructions(@system_prompt)
      @tools.each { |t| @chat.with_tool(t.to_ruby_llm_tool) }

      # Wire @chat for pikuri's event stream and controls — the
      # three message-level registered callbacks (+after_message+,
      # +before_tool_call+, +after_tool_result+). The per-chunk
      # streaming callback is separate because ruby_llm takes it as
      # a block to +Chat#complete+ rather than a registered hook —
      # see {#streaming_block}. Together with the +@listeners.emit+
      # calls in {#run_loop} / {#dispatch_ext_on_user_message} this
      # is the complete "which callback emits which event" map.
      @chat.after_message do |msg|
        emit_after_message(msg)
      end
      @chat.before_tool_call do |tc|
        @listeners.emit(Event::ToolCall.new(name: tc.name, arguments: tc.arguments))
        @step_limit&.tick!
        @cancellable&.check!
      end
      @chat.after_tool_result do |result|
        @listeners.emit(Event::ToolResult.new(content: result))
        drain_interloper if @interloper
      end

      # Context-window cap: lets every listener that cares (notably
      # TokenLog) pick the value off the stream before any Tokens
      # event arrives. Re-fires on each model switch (see
      # {#apply_transport!}).
      detect_and_emit_context_cap!

      # The runtime capability facade — constructed once, after the
      # chat and listener list are final, and handed to every
      # extension's #bind / #on_user_message. The ONLY object that
      # grants emission / raw-tool-registration / close-handler
      # capabilities; the Agent itself exposes no public path to
      # them. See {ExtensionContext}.
      @extension_context = ExtensionContext.new(
        agent: self, chat: @chat, listeners: @listeners,
        on_close_sink: @on_close_handlers
      )

      # Bind sweep — each extension gets its chance to install
      # per-agent state (dynamic tools via
      # {ExtensionContext#add_raw_tool}, per-agent close hooks via
      # {ExtensionContext#on_close}, domain-event wiring via
      # {ExtensionContext#emit_event}, etc.) now that the chat is
      # fully wired. See IDEAS.md §"Extension protocol design" for
      # what #configure vs #bind are each for.
      @extensions.each { |ext| ext.bind(@extension_context) }
    end

    # Build the full system prompt from the base prompt plus every
    # extension's {Extension#system_prompt_snippets}, in
    # extension-registration order, joined with blank lines. Blank / nil
    # sections are dropped so an extension contributing nothing this pass
    # (an empty catalog, a memory store that's down) leaves no stray
    # separator. Pure function of the base prompt and the extensions'
    # current state — no side effects, no chat mutation — so it can be
    # called both at construction ({#run_configure}) and on every
    # {#clear_conversation}; the latter is what refreshes dynamic
    # sections. Sub-agents construct their own prompt and don't go
    # through here.
    #
    # @return [String]
    def assemble_system_prompt
      sections = @extensions.flat_map(&:system_prompt_snippets)
      [@system_prompt_base, *sections]
        .reject { |s| s.nil? || s.to_s.strip.empty? }
        .join("\n\n")
    end

    # Resolve the context-window cap and announce it on the listener
    # stream as an {Event::ContextCap}. The transport's explicit
    # +context_window+ wins verbatim; otherwise {ContextWindowDetector}
    # probes the server (yielding +nil+ for a non-llama one). Because the
    # cap rides {ChatTransport}, a model switch resolves the *new*
    # transport's cap — explicit caps don't bleed across models. Shared
    # by {#run_configure} (construction) and {#apply_transport!} (each
    # model switch) so "how the cap is resolved and emitted" lives in
    # one place.
    #
    # @return [void]
    def detect_and_emit_context_cap!
      # Probe the server this transport actually targets — after a
      # cross-server switch the chat's connection points at
      # +@transport.api_base+, but the process-global config the
      # detector defaults to still names the *old* server, so derive the
      # base from the transport (falling back to the global base for a
      # transport that rides it).
      @context_window_cap = @transport.context_window ||
                            ContextWindowDetector.detect(
                              @transport,
                              openai_base: @transport.api_base || RubyLLM.config.openai_api_base
                            )
      @listeners.emit(Event::ContextCap.new(cap: @context_window_cap))
    end

    # Switch the underlying chat to +transport+ when it differs from
    # the current one. Called only from the top of {#run_loop} — see
    # that method's "Switching models mid-conversation" section for why
    # the swap is confined to the loop's own thread.
    #
    # Mirrors {#initialize}'s +nil+-model fill before the structural
    # comparison, so a +transport+ that defers its model to the default
    # doesn't read as "different" and switch spuriously.
    # +Chat#with_model+ swaps only the model / provider / connection,
    # leaving +@chat+'s message history and registered callbacks
    # intact, so the conversation continues seamlessly under the new
    # model. Emits {Event::ModelSwitched} (the narration: old → new
    # transport, unformatted, for the chrome to present) then re-resolves
    # and re-emits the cap via {#detect_and_emit_context_cap!}.
    #
    # == Cross-server switches
    #
    # +with_model+ alone re-resolves against the chat's *existing*
    # connection, so it can only move between models on one server. When
    # either the new or the old transport overrides the connection
    # (+ChatTransport#connection_overrides?+ — a different +api_base+ /
    # +api_key+), the swap first installs a fresh +RubyLLM::Context+ via
    # +Chat#with_context+ (which re-points the connection and re-resolves
    # the model in place, again preserving history + callbacks) before
    # +with_model+ lands the new model id. The "old overrode" half of
    # the guard handles switching *back* to a global-config model: the
    # rebuilt context dups the process-global config, resetting the
    # connection the previous override installed.
    #
    # @param transport [ChatTransport] the model to switch to
    # @return [void]
    def apply_transport!(transport)
      filled = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      return if filled == @transport

      old = @transport
      @chat.with_context(build_context(filled)) if filled.connection_overrides? || old.connection_overrides?
      @chat.with_model(filled.model, provider: filled.provider, assume_exists: filled.assume_model_exists)
      @transport = filled
      @listeners.emit(Event::ModelSwitched.new(from: old, to: filled))
      detect_and_emit_context_cap!
    end

    # Build the chat for +transport+: through a dedicated
    # +RubyLLM::Context+ when it overrides the connection, else through
    # the process-global +RubyLLM.chat+ (which the construction-time
    # path has always used).
    #
    # @param transport [ChatTransport]
    # @return [RubyLLM::Chat]
    def build_chat(transport)
      if transport.connection_overrides?
        build_context(transport).chat(**transport.chat_kwargs)
      else
        RubyLLM.chat(**transport.chat_kwargs)
      end
    end

    # A +RubyLLM::Context+ carrying +transport+'s connection overrides
    # mapped onto the provider's ruby_llm config slots
    # (+#{provider}_api_base+ / +#{provider}_api_key+). +RubyLLM.context+
    # dups the process-global config, so an absent override inherits the
    # global value; a transport with no overrides yields a plain dup
    # (used by {#apply_transport!} to reset a prior override). The
    # +ChatTransport+ guarantees a non-+nil+ +provider+ whenever an
    # override is set, so the slot name is always resolvable.
    #
    # @param transport [ChatTransport]
    # @return [RubyLLM::Context]
    def build_context(transport)
      slug = transport.provider
      RubyLLM.context do |c|
        c.public_send("#{slug}_api_base=", transport.api_base) unless transport.api_base.nil?
        c.public_send("#{slug}_api_key=", transport.api_key) unless transport.api_key.nil?
      end
    end

    # Fire the per-turn {Extension#on_user_message} hook on every
    # extension that defines it, appending any returned
    # String text block to the chat as a +role: :system+
    # message right after the user turn it annotates (callers append
    # the +:user+ message first; this runs last). The system role is
    # load-bearing — it tags the block as recalled reference (not new
    # input) and keeps it excludable from a later extraction pass.
    # See {Extension#on_user_message}.
    #
    # Each injected block also emits an {Event::SystemInjected} at
    # this site, so the listener stream mirrors the log growth (the
    # Terminal renders it; otherwise an injection would be invisible
    # except as a downstream echo in the assistant's reasoning).
    #
    # Private and the single place the chat log grows by a memory
    # block — keeps "what mutates the log, when" one grep in this
    # file. Fired from {#run_loop} (initial turn) and from
    # {#drain_interloper} (mid-loop interlopers). Called on every
    # extension unconditionally — same as {Extension#configure} /
    # {Extension#bind}: the hook is part of the protocol and the
    # {Extension} module supplies a no-op default, so any extension
    # that includes the module responds. An extension is "opted out"
    # by leaving the default in place (it returns +nil+, injecting
    # nothing), not by omitting the method.
    #
    # @param content [String] the incoming user message
    # @return [void]
    def dispatch_ext_on_user_message(content)
      @extensions.each do |ext|
        message = ext.on_user_message(@extension_context, content)
        next unless message.is_a?(String) && !message.strip.empty?

        block = message.strip
        @chat.add_message(role: :system, content: block)
        @listeners.emit(Event::SystemInjected.new(content: block))
      end
      nil
    end

    # Build the per-chunk streaming block passed to +Chat#complete+.
    # Each invocation of the returned proc converts one
    # +RubyLLM::Chunk+ into zero, one, or two delta events
    # ({Event::ThinkingDelta} / {Event::AssistantDelta}) on
    # +@listeners+. Tool-call chunks are intentionally ignored —
    # partial JSON has no useful rendering; the assembled
    # +tool_calls+ surface through {Event::ToolCall} once the
    # message completes.
    #
    # == Cancellation polling
    #
    # When +@cancellable+ is non-nil, {Control::Cancellable#check!}
    # fires *before* each chunk's emit. The +before_tool_call+
    # wiring in {#run_configure} only fires when the model requests a
    # tool, which leaves a no-tool turn (e.g. a plain greeting)
    # with zero cancellation points — Ctrl+C trips the flag but
    # nothing reads it. Polling on every streamed chunk closes
    # that gap: an in-flight Cancellation+check! raises on the
    # next chunk delivered after the flag flips, the exception
    # propagates out through ruby_llm's streaming path
    # (+Chat#complete+ doesn't rescue), and {#run_loop} catches it,
    # emits {Event::Cancelled}, and re-raises. The pre-emit
    # ordering is deliberate: a chunk that arrives after a cancel
    # request shouldn't render — the user has said stop.
    #
    # @return [Proc] a +-> (chunk) { ... }+ proc suitable for
    #   passing to +Chat#complete+ with +&+
    def streaming_block
      ->(chunk) {
        @cancellable&.check!
        emit_chunk(chunk)
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
    # @return [void]
    def emit_after_message(msg)
      return unless msg.role == :assistant

      text = msg.thinking&.text
      @listeners.emit(Event::Thinking.new(content: text)) if text && !text.empty?

      content = msg.content
      @listeners.emit(Event::Assistant.new(content: content)) if content.is_a?(String) && !content.empty?

      @listeners.emit(Event::Tokens.new(
                        input: msg.input_tokens,
                        output: msg.output_tokens,
                        cached: msg.cached_tokens,
                        cache_creation: msg.cache_creation_tokens,
                        thinking: msg.thinking_tokens,
                        model_id: msg.model_id
                      ))
    end

    # Normalize a +RubyLLM::Chunk+ from a streaming completion
    # into zero, one, or two delta events
    # ({Event::ThinkingDelta} / {Event::AssistantDelta}). Empty
    # +thinking.text+ and empty +content+ are filtered here so
    # listeners never see vacuous fragments. Tool-call deltas are
    # intentionally skipped — see {#streaming_block}.
    #
    # +chunk+ is a +RubyLLM::Chunk+ (subclass of +RubyLLM::Message+),
    # so the same +.thinking+ / +.content+ accessors used in
    # {#emit_after_message} apply.
    #
    # @param chunk [RubyLLM::Chunk]
    # @return [void]
    def emit_chunk(chunk)
      thinking = chunk.thinking&.text
      @listeners.emit(Event::ThinkingDelta.new(content: thinking)) if thinking && !thinking.empty?

      content = chunk.content
      @listeners.emit(Event::AssistantDelta.new(content: content)) if content.is_a?(String) && !content.empty?
    end

    # Drain the interloper queue: for each pending item, append a
    # +role: :user+ message to the chat history so the next
    # round-trip sees it, emit an {Event::UserTurn} with
    # +mid_loop: true+ to the listener stream so renderers see the
    # injection, then run the per-turn {Extension#on_user_message}
    # dispatch (so mid-loop injections are prefetched + recorded
    # exactly like initial turns).
    #
    # The dispatch runs *after* the +:user+ append so any
    # +<memory-context>+ it injects lands as a +:system+ message
    # right behind the user turn it annotates — the same
    # append-at-the-tail ordering {#run_loop} produces for initial
    # turns.
    #
    # @return [void]
    def drain_interloper
      @interloper.drain!.each do |content|
        @chat.add_message(role: :user, content: content)
        @listeners.emit(Event::UserTurn.new(content: content, mid_loop: true))
        dispatch_ext_on_user_message(content)
      end
    end
  end
end
