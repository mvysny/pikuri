# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  # Thin wrapper around +RubyLLM::Chat+: ruby_llm owns the Thought /
  # Tool-call / Observation loop (+Chat#complete+); pikuri owns the
  # *extension surface* — it wires ruby_llm's three callbacks at
  # construction, emits {Event} variants from each, and forwards control
  # signals to the {Control}s.
  #
  # Two seams meet here:
  #
  # 1. **Listeners** ({ListenerList} + {Listener::Base}) — pure consumers
  #    of the event stream, never writing back. The +Agent+ emits every
  #    loop-narration {Event}; extensions emit domain events through the
  #    {ExtensionContext} handed to {Extension#bind}. No public path leads
  #    from an +Agent+ reference to emission (no +listeners+/+chat+ reader,
  #    no emit method), so holding an agent grants read access and nothing
  #    more. New sinks are added as listeners without touching {Agent}.
  # 2. **Controls** ({Control::StepLimit}, {Control::Cancellable},
  #    {Control::Interloper}) — host-facing signal holders the +Agent+
  #    reads at fixed boundaries: +tick!+/+check!+ on every
  #    +before_tool_call+, +reset!+ at turn start, +drain!+ once each tool
  #    batch is answered.
  #
  # "What fires when" is one grep for +@listeners.emit+ (loop narration)
  # plus the capability calls in {ExtensionContext} (domain events).
  #
  # == Step-exhaustion policy
  #
  # When +step_limit:+ trips during completion, {#run_loop} applies its
  # {Control::StepLimit#on_exhausted} policy:
  #
  # - +:raise+ (default) — re-raise to the host. History survives and
  #   {Control::StepLimit#reset!} fires next turn, so "continue" works.
  # - +:synthesize+ — emit an {Event::FallbackNotice} and run the
  #   {Synthesizer} prompt on a nested tools-free +Agent+ (listener stream
  #   via {ListenerList#for_sub_agent}, +cancellable+ shared so a user
  #   cancel still works, a defensive +step_limit+ at +max: 1+). Its answer
  #   becomes {#last_assistant_content}, so callers still get a reply.
  #
  # == Cancellation rescue
  #
  # When +cancellable:+ trips during +Chat#ask+, {#run_loop} emits an
  # {Event::Cancelled} and re-raises — no synthesizer fallback (cancel
  # means drop everything). {Control::Cancellable#reset!} at each turn
  # start lets the same instance take a fresh turn afterwards.
  class Agent
    LOGGER = Pikuri.logger_for('Agent')
    private_constant :LOGGER

    # Envelope wrapped around every injected reference block by
    # {#append_reference_block}. +system-reminder+ is Claude Code's and
    # grok-build's tag, deliberately — an in-distribution envelope the model has
    # seen in training beats a pikuri-flavoured one it has to infer.
    REFERENCE_TAG = 'system-reminder'
    private_constant :REFERENCE_TAG

    # Provider slugs (matched against +@chat.model.provider+) whose wire format
    # carries system content in a top-level request field rather than as an
    # element of +messages+ — Anthropic's +system+ param, Bedrock's +system+
    # blocks. ruby_llm's provider splits it out at payload-render time
    # (+messages.partition { |m| m.role == :system }+), so a conversation
    # holding nothing but the system prompt renders +messages: []+ and the API
    # 400s — see {EmptyTurnError}. Everywhere else +:system+ is an ordinary
    # array element (OpenAI, Gemini) and that same conversation is a legal
    # one-message request.
    #
    # Only +:system+ moves — a placement difference in the payload, not a
    # rewrite of what pikuri appended, so the +:user+ blocks of
    # {#append_reference_block} ride through untouched on every provider here.
    SEPARATE_SYSTEM_FIELD_PROVIDERS = %w[anthropic bedrock].freeze
    private_constant :SEPARATE_SYSTEM_FIELD_PROVIDERS

    # A blank turn was requested against a conversation holding nothing but the
    # assembled system prompt, on a provider that would render that as
    # +messages: []+ (see {SEPARATE_SYSTEM_FIELD_PROVIDERS}):
    #
    #   agent.run_loop(user_message: nil)   # fresh chat, backend Anthropic
    #   # => EmptyTurnError; the host catches it and prompts for a real message
    #
    # Narrow by construction: every *injected* block lands as +role: :user+
    # ({#append_reference_block}), so a skill-only or memory-only bare load has
    # a message to complete against and never reaches here. What remains is a
    # genuinely empty conversation.
    #
    # Content-neutral: {#provider} is all it carries — the host owns any
    # user-facing wording.
    class EmptyTurnError < StandardError
      # @return [String] the resolved provider slug that can't complete the turn
      attr_reader :provider

      # @param provider [String] the resolved provider slug (e.g. +"anthropic"+)
      def initialize(provider)
        @provider = provider
        super("#{provider} cannot complete a turn whose conversation holds only " \
              ':system content (no user or assistant message): it would send an ' \
              'empty messages array. Add a user message.')
      end
    end

    # @param transport [ChatTransport] model-resolution bundle (+model+ /
    #   +provider+ / +assume_model_exists+ and, off the global server,
    #   +api_base+ / +api_key+). A +nil+ +transport.model+ is filled from
    #   +RubyLLM.config.default_model+.
    # @param system_prompt [String] base system message; the chat sees
    #   this plus every extension's {Extension#system_prompt_snippets},
    #   assembled by {#assemble_system_prompt} at construction and on each
    #   {#clear_conversation}.
    # @param step_limit [Control::StepLimit, nil] step budget, or +nil+ for
    #   no budget (unbounded looping). Its {Control::StepLimit#on_exhausted}
    #   policy drives {#run_loop} on trip (see the class header).
    # @param cancellable [Control::Cancellable, nil] cancellation control,
    #   or +nil+ for none (no way to stop a running turn but killing the
    #   process).
    # @param interloper [Control::Interloper, nil] mid-loop user-input queue
    #   drained once each tool batch is answered (each item becomes an
    #   {Event::UserTurn} with +mid_loop: true+), or +nil+ for none.
    # @param id [String] unique id; empty for the main agent, persona-rooted
    #   for sub-agents (+"researcher 0"+, ...). Distinct from a persona's
    #   +name+ (the value the LLM picks in the +agent+ tool's +name:+ arg).
    # @param streaming [Boolean] opt into chunk-level streaming — {#run_loop}
    #   passes a per-chunk block to +Chat#complete+ and normalizes chunks
    #   into {Event::ThinkingDelta}/{Event::AssistantDelta}. Default +false+
    #   (only the +after_message+ bookends fire).
    # @yield [Configurator] the sole path for adding tools, listeners,
    #   extensions, and +on_close+ handlers — there are no parallel ctor
    #   kwargs. Optional; without it the agent has none of those.
    # @return [Agent]
    def initialize(transport:, system_prompt:,
                   step_limit: nil, cancellable: nil, interloper: nil,
                   id: '',
                   streaming: false,
                   &block)
      @transport = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      @cancellable = cancellable
      @closed = false

      # Kept separate from the assembled +@system_prompt+ so
      # {#assemble_system_prompt} can recompute (base + extensions'
      # snippets) from scratch at construction and on each
      # {#clear_conversation}, refreshing dynamic sections.
      @system_prompt_base = system_prompt
      @system_prompt = system_prompt
      @step_limit = step_limit
      @interloper = interloper
      @id = id
      @streaming = streaming
      @synth_answer = nil
      @on_close_handlers = []
      # Stashed for {#run_configure}, the failure-prone build phase.
      @block = block

      # Register *before* the build phase so a mid-construction raise is
      # recoverable: extensions arm cleanup via +c.on_close+ (straight into
      # +@on_close_handlers+), and the rescue below fires whatever was armed
      # before the failure. On the happy path this is the at-exit backstop
      # if the host forgets {#close}; an explicit {#close} unregisters.
      Pikuri::Finalizers.register(self)

      begin
        run_configure
      rescue StandardError
        # Half-built agent: fire the armed handlers, drop out of the
        # registry, re-raise — no partial state leaks.
        close
        raise
      end
    end

    # @return [ChatTransport] the resolved transport this agent was built
    #   with — the model/provider/connection every +RubyLLM.chat+ from this
    #   agent uses (main chat, synthesizer, sub-agents).
    attr_reader :transport

    # @return [Array<Tool>] tool list in declaration order. These are the
    #   tools registered with ruby_llm — the parent LLM can call any. Cf.
    #   {#sub_agent_tools}.
    attr_reader :tools

    # @return [Array<Tool>] tools added via
    #   {Configurator#add_sub_agent_tool}, in declaration order. Never sent
    #   to ruby_llm (invisible to the parent LLM); available only to
    #   sub-agents whose persona +tool_names+ match — the trifecta defense,
    #   see {Configurator}.
    attr_reader :sub_agent_tools

    # @return [String] resolved model id from {#transport}.
    def model
      @transport.model
    end

    # @return [String] system prompt actually sent — the base
    #   +system_prompt:+ plus every extension's
    #   {Extension#system_prompt_snippets}, re-assembled on
    #   {#clear_conversation} (so a dynamic section may differ from its
    #   construction value). Not inherited by sub-agents.
    attr_reader :system_prompt

    # @return [Control::StepLimit, nil] the step budget, or +nil+.
    attr_reader :step_limit

    # @return [Control::Cancellable, nil] the cancellation control, or
    #   +nil+. Extensions read it to propagate cancellation to their own
    #   LLM calls (the +agent+ tool shares it so one Ctrl+C stops the tree).
    attr_reader :cancellable

    # @return [Control::Interloper, nil] the mid-loop user-input control, or
    #   +nil+.
    attr_reader :interloper

    # @return [String] this agent's id — empty for the main agent,
    #   persona-rooted for sub-agents (+"researcher 0"+). Distinct from the
    #   persona +name+; propagated to listeners via
    #   {ListenerList#for_sub_agent} so id-aware ones tag their output.
    attr_reader :id

    # @return [Boolean] whether this agent opted into chunk-level streaming
    #   (see {#initialize}'s +streaming:+).
    attr_reader :streaming

    # @return [Array<Extension>] extensions bound to this agent. Each one's
    #   +configure+ ran during the +Agent.new+ block, its +bind+ at the end
    #   of {#initialize}. Not inherited by sub-agents.
    attr_reader :extensions

    # @return [Integer, nil] resolved context-window cap — the
    #   {ChatTransport#context_window} if given, else the
    #   {ContextWindowDetector} probe; +nil+ when neither yields one.
    #   Re-resolved on every model switch.
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

    # Run the agent loop for one turn. With a +user_message+, emits an
    # {Event::UserTurn} (+mid_loop: false+) and appends it; with none, runs a
    # *bare* turn against whatever the conversation + drained injections
    # already hold — the case a host uses after loading a skill on its own
    # initiative, so the agent reacts to it. Resets the step/cancellation
    # controls, drains any pending {Control::Interloper} injections, then
    # +complete+s the chat. Output is the listeners' job; subsequent calls
    # build on the same history.
    #
    # A blank +user_message+ against a conversation holding nothing but the
    # system prompt is provider-split: providers that can't complete it raise
    # {EmptyTurnError}, the rest run the turn against that history. A blank turn
    # *mid-conversation* always proceeds — real turns remain to answer, and a
    # drained injection is itself one.
    #
    # Step-limit and cancellation trips are handled per the class header's
    # "Step-exhaustion policy" / "Cancellation rescue".
    #
    # == Switching models mid-conversation
    #
    # A +transport:+ differing from the current one switches the chat to it
    # (via {#apply_transport!}), re-resolves the cap, and emits
    # {Event::ModelSwitched} + a fresh {Event::ContextCap}. The switch is
    # confined to the top of this method because the chat is
    # single-thread-confined — a background thread mutating the connection
    # mid-completion would tear an in-flight stream. The conversation is
    # *not* re-baselined: same conversation, new model, so message count and
    # running context size carry over. +nil+ keeps the current model.
    #
    # @param user_message [String, nil] the turn's request; +nil+/blank runs a
    #   bare turn (see above)
    # @param transport [ChatTransport, nil] when non-+nil+ and structurally
    #   different, switch to it before the turn; +nil+ keeps the model
    # @raise [Control::Cancellable::Cancelled] if cancelled mid-turn (an
    #   {Event::Cancelled} is emitted first)
    # @raise [Control::StepLimit::Exceeded] if the budget tripped under the
    #   +:raise+ policy
    # @raise [EmptyTurnError] on a blank turn against a prompt-only
    #   conversation when the provider carries +:system+ outside +messages+
    #   (see above)
    # @return [nil] after a turn runs
    def run_loop(user_message: nil, transport: nil)
      apply_transport!(transport) if transport
      @synth_answer = nil
      @step_limit&.reset!
      @cancellable&.reset!

      # Deliver host-scheduled injections (e.g. a UI-loaded skill) before the
      # first complete, so a freshly-scheduled block lands this turn rather
      # than only after the next tool batch — ordered ahead of the user
      # message appended below.
      drain_interloper if @interloper

      blank = user_message.nil? || user_message.to_s.strip.empty?
      # These providers would send `messages: []` here (see EmptyTurnError).
      # The drain above is what usually saves this case: an injected block is a
      # :user message, so a skill-only bare load has something to complete
      # against and falls through.
      if blank && @chat.messages.all? { |m| m.role == :system } &&
         SEPARATE_SYSTEM_FIELD_PROVIDERS.include?(@chat.model.provider.to_s)
        raise EmptyTurnError, @chat.model.provider
      end

      unless blank
        # Append the user turn, emit it, then run the memory dispatch — so any
        # <memory-context> the dispatch injects lands as a :system message
        # *after* the user turn it annotates. (+ask+ bundles append+complete
        # atomically, leaving no seam to inject between; the halves run
        # explicitly instead.)
        @chat.add_message(role: :user, content: user_message)
        @listeners.emit(Event::UserTurn.new(content: user_message, mid_loop: false))
        dispatch_ext_on_user_message(user_message)
      end

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

    # Return the agent to a fresh-conversation state without tearing down
    # its wiring — the host "/clear". Unlike {#close} (which fires the
    # teardown handlers), everything stays alive; nothing is re-probed or
    # re-connected. Resets, in order:
    #
    # 1. Chat history (+Chat#reset_messages!+, which also drops every injected
    #    reference block), then re-applies a freshly **re-assembled** prompt —
    #    {#assemble_system_prompt} re-pulls every extension's snippets, so
    #    dynamic sections refresh (a resident memory persona, a re-read
    #    +MACHINE.md+). Callbacks and tool registrations on the reused +@chat+
    #    are untouched.
    # 2. Controls — step/cancellation reset, interloper queue drained (stale
    #    mid-loop input must not leak forward), cached synth answer dropped.
    # 3. Listeners — a single {Event::Reset} so they reset display state.
    # 4. Extension state — {Extension#on_conversation_reset} on each.
    #
    # Model/transport are left as-is (a clear is not a model switch). Runs on
    # the agent's own thread; not designed to race an in-flight {#run_loop}.
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

    # Release agent-owned resources: fire every handler registered via
    # {Configurator#on_close} and {ExtensionContext#on_close} in LIFO order,
    # so a handler that depends on an earlier one tears down first. Each runs
    # in its own +rescue+ (an exception is logged, not propagated).
    # Idempotent.
    #
    # @return [void]
    def close
      return if @closed

      @closed = true
      # Drop out of the registry first: a deliberate close no longer needs
      # the at-exit fallback, and dropping the reference frees it for GC.
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

    # This agent's lethal-trifecta picture: which legs it holds, which its
    # sub-agents hold, the verdict at every node.
    #
    #   puts agent.trifecta.render        # the map a bin script prints
    #   agent.trifecta.tree_verdict       # => :soft
    #
    # Memoized and pure, so a UI may call it as often as it likes. Nothing
    # reports this for you: an Agent computes the picture and stops, because a
    # library writing to a log its embedder never asked for is noise. Surfacing
    # it is the host's job — the bundled +bin/pikuri-*+ scripts print
    # {Trifecta::Report#render} at boot.
    #
    # Valid only after construction (it reads the wired tool list), and it
    # reflects the tools present *then*.
    #
    # @return [Trifecta::Report] root of the walked tree
    def trifecta
      @trifecta ||= Trifecta.walk(Trifecta.build(self))
    end

    private

    # The failure-prone build phase, split out of {#initialize} so the
    # constructor can wrap it in a rescue and self-heal. Funnels the
    # +Agent.new+ block through one {Configurator} (tools, listeners,
    # snippets, extensions, +on_close+), wires the chat, then runs the
    # extension +bind+ sweep. The Configurator's +on_close_sink:+ is
    # +@on_close_handlers+ itself, so a handler armed via +c.on_close+ is
    # live the instant it's registered — what lets the rescue close a
    # half-built agent.
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
      # Assemble now that every extension's +configure+ has run (their
      # snippets read populated state); re-runs on {#clear_conversation}.
      @system_prompt = assemble_system_prompt

      @chat = build_chat(@transport)
      @chat.with_instructions(@system_prompt)
      @tools.each { |t| @chat.with_tool(t.to_ruby_llm_tool) }

      # Wire @chat for the event stream and controls via ruby_llm's three
      # registered callbacks. (The per-chunk streaming callback is separate
      # — {#streaming_block} — since ruby_llm takes it as a block to
      # +Chat#complete+, not a registered hook.) With the +@listeners.emit+
      # calls in {#run_loop}/{#dispatch_ext_on_user_message}, this is the
      # complete callback→event map.
      @chat.after_message do |msg|
        emit_after_message(msg)
        drain_interloper if @interloper && tool_batch_complete?(msg)
      end
      @chat.before_tool_call do |tc|
        @listeners.emit(Event::ToolCall.new(name: tc.name, arguments: tc.arguments))
        @step_limit&.tick!
        @cancellable&.check!
      end
      @chat.after_tool_result do |result|
        @listeners.emit(Event::ToolResult.new(content: result))
      end

      # Context-window cap on the stream before any Tokens event; re-fires
      # on each model switch (see {#apply_transport!}).
      detect_and_emit_context_cap!

      # The runtime capability facade — the ONLY object granting
      # emission / raw-tool / close-handler capabilities; the Agent exposes
      # no public path to them. Handed to every extension's #bind /
      # #on_user_message. See {ExtensionContext}.
      @extension_context = ExtensionContext.new(
        agent: self, chat: @chat, listeners: @listeners,
        on_close_sink: @on_close_handlers
      )

      # Bind sweep — each extension installs per-agent state now the chat is
      # fully wired (dynamic tools, close hooks, domain-event wiring). See
      # {Extension} for #configure vs #bind.
      @extensions.each { |ext| ext.bind(@extension_context) }
    end

    # Build the full prompt: base plus every extension's
    # {Extension#system_prompt_snippets}, in registration order, joined by
    # blank lines. Blank/nil sections drop (an extension contributing
    # nothing leaves no stray separator). Pure function of the base + the
    # extensions' current state, so it serves both construction and
    # {#clear_conversation} (the latter refreshing dynamic sections).
    #
    # @return [String]
    def assemble_system_prompt
      sections = @extensions.flat_map(&:system_prompt_snippets)
      [@system_prompt_base, *sections]
        .reject { |s| s.nil? || s.to_s.strip.empty? }
        .join("\n\n")
    end

    # Resolve the context-window cap and announce it as an
    # {Event::ContextCap}. The transport's explicit +context_window+ wins;
    # else {ContextWindowDetector} probes the server (+nil+ for a non-llama
    # one). The cap rides {ChatTransport}, so a switch resolves the *new*
    # transport's cap. Shared by {#run_configure} and {#apply_transport!}.
    #
    # @return [void]
    def detect_and_emit_context_cap!
      # Probe the server this transport targets: after a cross-server switch
      # the chat points at +@transport.api_base+, but the global config still
      # names the old server — so derive the base from the transport.
      @context_window_cap = @transport.context_window ||
                            ContextWindowDetector.detect(
                              @transport,
                              openai_base: @transport.api_base || RubyLLM.config.openai_api_base
                            )
      @listeners.emit(Event::ContextCap.new(cap: @context_window_cap))
    end

    # Switch the chat to +transport+ when it differs from the current one.
    # Called only from the top of {#run_loop} (see its "Switching models"
    # section for the thread-confinement reason). Mirrors {#initialize}'s
    # +nil+-model fill before the structural compare, so a transport
    # deferring to the default model doesn't switch spuriously.
    # +Chat#with_model+ keeps history and callbacks. Emits
    # {Event::ModelSwitched}, then re-resolves and re-emits the cap.
    #
    # == Cross-server switches
    #
    # +with_model+ re-resolves against the chat's existing connection, so it
    # only moves between models on one server. When either transport
    # overrides the connection (+ChatTransport#connection_overrides?+), a
    # fresh +RubyLLM::Context+ is installed via +Chat#with_context+ first
    # (re-pointing the connection, preserving history + callbacks). The "old
    # overrode" half handles switching *back* to a global-config model: the
    # rebuilt context dups the global config, resetting the prior override.
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

    # Build the chat for +transport+: through a dedicated +RubyLLM::Context+
    # when it overrides the connection, else through the process-global
    # +RubyLLM.chat+.
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

    # A +RubyLLM::Context+ carrying +transport+'s connection overrides on the
    # provider's config slots (+#{provider}_api_base+ / +_api_key+).
    # +RubyLLM.context+ dups the global config, so an absent override inherits
    # the global value and a no-override transport yields a plain dup (used by
    # {#apply_transport!} to reset a prior override). +ChatTransport+
    # guarantees a non-+nil+ +provider+ whenever an override is set.
    #
    # A transport's +faraday_adapter+ (if any) is installed here too: the
    # adapter rides *this* context's config, not the process-global
    # +RubyLLM.config+, so it stays per-agent — the seam
    # {Pikuri::Testing.fake_transport} uses to run the real ruby_llm loop
    # against a scripted HTTP backend.
    #
    # @param transport [ChatTransport]
    # @return [RubyLLM::Context]
    def build_context(transport)
      slug = transport.provider
      RubyLLM.context do |c|
        c.public_send("#{slug}_api_base=", transport.api_base) unless transport.api_base.nil?
        c.public_send("#{slug}_api_key=", transport.api_key) unless transport.api_key.nil?
        c.faraday_adapter = transport.faraday_adapter if transport.faraday_adapter
        # ruby_llm defaults an OpenAI-family `:system` message to the newer
        # `developer` role. OpenAI treats the two alike, but a local
        # llama.cpp hands the role straight to the model's chat template,
        # and a Qwen/Llama template has never seen `developer` — the system
        # prompt then arrives under a role token the model was not trained
        # on. pikuri targets local servers first, so ask for `system`.
        c.openai_use_system_role = true if c.respond_to?(:openai_use_system_role=)
      end
    end

    # Fire {Extension#on_user_message} on every extension, appending any
    # returned text via {#append_reference_block} right after the user turn it
    # annotates (the caller appends the +:user+ message first).
    #
    # Called unconditionally — the {Extension} no-op default returns +nil+
    # (injects nothing), so opting out means leaving the default, not omitting
    # the method.
    #
    # @param content [String] the incoming user message
    # @return [void]
    def dispatch_ext_on_user_message(content)
      @extensions.each do |ext|
        message = ext.on_user_message(@extension_context, content)
        next unless message.is_a?(String) && !message.strip.empty?

        append_reference_block(message.strip)
      end
      nil
    end

    # Append host-originated reference text — a memory block, a loaded skill, a
    # path-activation promotion, retrieved context — and emit
    # {Event::SystemInjected}. Lands as a +role: :user+ message wrapped in
    # +<system-reminder>+:
    #
    #   append_reference_block('<memory-context>…</memory-context>')
    #   # the chat log grows by one :user message:
    #   #   <system-reminder>
    #   #   <memory-context>…</memory-context>
    #   #   </system-reminder>
    #
    # The event carries the block *unwrapped* — the envelope is wire plumbing,
    # and a listener rendering the tag would be showing the reader framing they
    # did not write.
    #
    # == Implementation details
    #
    # +:user+ rather than +:system+ because a mid-conversation +:system+ message
    # is not portable: Qwen3.6's chat template silently drops every one past the
    # leading header, and providers carrying +:system+ in a separate field
    # (Anthropic, Bedrock — see {SEPARATE_SYSTEM_FIELD_PROVIDERS}) merge it into
    # the standing system prompt, so the block is presented as though it had
    # always been there and stays in force. Neither failure is visible from
    # anything pikuri can observe: the message is in the payload, the listener
    # stream renders it, the history holds it. See +DECISIONS.md+
    # +D-reference-text-as-user-turn+.
    #
    # A closing tag inside +content+ is escaped, so injected text (a file, a web
    # page, an MCP tool's description) cannot close the envelope early and have
    # what follows read as conversation.
    #
    # @param content [String] the block to inject, already stripped; callers
    #   with their own semantic tag (+<memory-context>+) keep it — the envelope
    #   nests around it
    # @return [void]
    def append_reference_block(content)
      close = "</#{REFERENCE_TAG}>"
      # Block form, not a replacement String: gsub reads `\&`, `\1` etc. out of
      # the latter, so a tag carrying one would be mangled rather than escaped.
      body = content.gsub(close) { "<\\/#{REFERENCE_TAG}>" }
      @chat.add_message(role: :user, content: "<#{REFERENCE_TAG}>\n#{body}\n#{close}")
      @listeners.emit(Event::SystemInjected.new(content: content))
      nil
    end

    # Build the per-chunk block passed to +Chat#complete+. Each call converts
    # one +RubyLLM::Chunk+ into zero, one, or two delta events
    # ({Event::ThinkingDelta}/{Event::AssistantDelta}). Tool-call chunks are
    # ignored — partial JSON has no useful rendering; the assembled call
    # surfaces via {Event::ToolCall} once the message completes.
    #
    # == Cancellation polling
    #
    # When +@cancellable+ is set, {Control::Cancellable#check!} fires *before*
    # each chunk's emit. The +before_tool_call+ wiring only fires on a tool
    # request, so a no-tool turn (a plain greeting) has zero cancellation
    # points; polling per chunk closes that gap. Pre-emit ordering is
    # deliberate — a chunk arriving after a cancel request shouldn't render.
    #
    # @return [Proc] a +->(chunk) { ... }+ for +Chat#complete+
    def streaming_block
      ->(chunk) {
        @cancellable&.check!
        emit_chunk(chunk)
      }
    end

    # Normalize an +after_message+ payload into zero, one, or two {Event}s
    # (+Thinking+ and/or +Assistant+) plus one {Event::Tokens}. Empty
    # thinking/content are filtered here so listeners never see vacuous
    # events; non-assistant roles are skipped.
    #
    # @param msg [RubyLLM::Message]
    # @return [void]
    # Whether +msg+ closed a tool batch — the only mid-turn moment an injected
    # message may be appended.
    #
    # An assistant message carrying +tool_calls+ and the +:tool+ messages
    # answering it are one indivisible unit on the wire: OpenAI rejects a
    # +tool+ message that does not follow its call, Anthropic requires the
    # results to open the very next message, and a local chat template groups
    # them into one block. Anything appended between the two halves is
    # therefore either an error or, worse, silently mangled prose — which is
    # what draining at ruby_llm's +after_tool_result+ did, since that fires
    # *before* the result message is added.
    #
    # @param msg [RubyLLM::Message]
    # @return [Boolean] true when +msg+ is the last tool result its assistant
    #   message was waiting for (so parallel calls drain once, at the end)
    def tool_batch_complete?(msg)
      return false unless msg.role == :tool

      messages = @chat.messages
      opener_index = messages.rindex { |m| m.role == :assistant && m.tool_calls&.any? }
      return true if opener_index.nil?

      answered = messages[(opener_index + 1)..].filter_map { |m| m.tool_call_id if m.role == :tool }
      messages[opener_index].tool_calls.each_key.all? { |id| answered.include?(id) }
    end

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

    # Normalize a streaming +RubyLLM::Chunk+ into zero, one, or two delta
    # events ({Event::ThinkingDelta}/{Event::AssistantDelta}). Empty
    # fragments are filtered; tool-call deltas skipped (see {#streaming_block}).
    #
    # @param chunk [RubyLLM::Chunk]
    # @return [void]
    def emit_chunk(chunk)
      thinking = chunk.thinking&.text
      @listeners.emit(Event::ThinkingDelta.new(content: thinking)) if thinking && !thinking.empty?

      content = chunk.content
      @listeners.emit(Event::AssistantDelta.new(content: content)) if content.is_a?(String) && !content.empty?
    end

    # Drain the interloper queue, landing each item per its
    # {Control::Interloper::Item#kind}:
    #
    # - +:user+ — append +role: :user+ verbatim, emit {Event::UserTurn}
    #   (+mid_loop: true+), then run the {Extension#on_user_message} dispatch
    #   (so mid-loop injections are prefetched + recorded like initial turns).
    #   The dispatch runs *after* the append so an injected +<memory-context>+
    #   lands right behind the turn it annotates.
    # - +:system+ — {#append_reference_block}: reference text, so no
    #   +on_user_message+ dispatch and no +UserTurn+.
    #
    # Both kinds reach the wire as +role: :user+ and differ in dispatch and in
    # the envelope — only the +:system+ kind is wrapped. That is the whole
    # distinction, and it is why the queue keeps two kinds rather than a
    # +wrap:+ flag.
    #
    # @return [void]
    # @raise [RuntimeError] on an unknown item kind (a bug — only the two
    #   +inject_*+ producers exist)
    def drain_interloper
      @interloper.drain!.each do |item|
        case item.kind
        when :user
          @chat.add_message(role: :user, content: item.content)
          @listeners.emit(Event::UserTurn.new(content: item.content, mid_loop: true))
          dispatch_ext_on_user_message(item.content)
        when :system
          append_reference_block(item.content)
        else
          raise "unknown interloper item kind: #{item.kind.inspect}"
        end
      end
    end
  end
end
