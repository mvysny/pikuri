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
  #    {Configurator} handed to {Extension#configure}. No public path leads
  #    from an +Agent+ reference to emission (no +listeners+/+chat+ reader,
  #    no emit method), so holding an agent grants read access and nothing
  #    more. New sinks are added as listeners without touching {Agent}.
  # 2. **Controls** ({Control::Cancellable}, {Control::Interloper}) —
  #    host-facing signal holders the +Agent+ reads at fixed boundaries:
  #    +check!+ on every +before_tool_call+, +drain!+ once each tool batch
  #    is answered. Resetting the cancel flag per turn is the host's job.
  #
  # "What fires when" is one grep for +@listeners.on_event+ (loop narration)
  # plus {Configurator#emit_event} (domain events).
  #
  # == One agent, one conversation
  #
  # An agent lives exactly as long as its conversation; nothing clears it or
  # loads another conversation into it. To start over or to resume, close it
  # and build a new one — from the same wiring code, with fresh extension
  # instances:
  #
  #   history = agent.export_history
  #   agent.close
  #   agent = Pikuri::Agent.new(transport: t, system_prompt: p, history: history) { |c| wire(c) }
  #
  # A conversation boundary must not carry state across — not the tools an
  # MCP server registered mid-conversation, not the browser session behind
  # them. See +design/decisions.md+ +D_agent_is_one_conversation+. Compaction
  # crosses no boundary, so it rewrites the conversation in place:
  # {Configurator#replace_compacted_history}.
  #
  # == The loop is unbounded
  #
  # Nothing here caps how many tool calls a turn may make. A turn ends when
  # the model stops asking for tools, when {Control::Cancellable} trips, or
  # when the context window fills. Why there is no budget, and what to reach
  # for instead if a runaway loop ever shows up: +design/decisions.md+
  # +D_no_step_limit+.
  #
  # == Cancellation rescue
  #
  # When +cancellable:+ trips during +Chat#ask+, {#run_loop} emits an
  # {Event::Cancelled} and re-raises. The host calls
  # {Control::Cancellable#reset!} before each turn so the same instance takes a
  # fresh turn afterwards; {#run_loop} itself never clears the flag.
  #
  # == Threading
  #
  # **Thread-unsafe** — and that is the whole guarantee, deliberately no
  # stronger. +@chat+, the message-identity map and the +on_close+ list are
  # plain unguarded state, and {#run_loop} is not re-entrant, so a second
  # thread calling in mid-turn corrupts the conversation rather than raising.
  # Preventing concurrent access is the caller's job, by any means: one thread
  # per agent, a mutex around every call, an actor mailbox. Nothing here is
  # *confined* to a particular thread — an +Agent+ may be driven from a
  # different thread on each turn, so never key anything about it off
  # +Thread.current+.
  #
  # Several agents in one VM is then the easy case, one thread each:
  #
  #   agents.map { |a| Thread.new { a.run_loop(user_message: task_for(a)) } }.each(&:join)
  #
  # Thread-safety is not the only question those N agents raise, though: they
  # usually point at *one* inference server, and N simultaneous completions
  # against a llama.cpp started with +--parallel 1+ queue up inside the server,
  # where pikuri can neither cancel nor reorder them. The +around_request:+
  # hook is where a host rations that — one permit per HTTP request, never per
  # turn (see {#initialize}).
  #
  # Two {Control}s are the sanctioned doors *in* from another thread, which is
  # why they carry locks and the agent does not: {Control::Cancellable} (stop
  # the turn) and {Control::Interloper} (queue a mid-turn message, delivered at
  # the next tool-batch boundary). Every other method needs the caller's own
  # serialization.
  #
  # Tools inherit nothing from this: an instance handed to two agents is
  # reachable from both, so each declares its own posture (see
  # {Pikuri::Tool}'s +== Sharing+).
  class Agent
    LOGGER = Pikuri.logger_for('Agent')
    private_constant :LOGGER

    # Envelope wrapped around every injected reference block by
    # {#append_reference_block}. +system-reminder+ is Claude Code's and
    # grok-build's tag, deliberately — an in-distribution envelope the model has
    # seen in training beats a pikuri-flavoured one it has to infer.
    REFERENCE_TAG = 'system-reminder'
    private_constant :REFERENCE_TAG

    # A turn carried an attachment the model is known not to accept — an image
    # to a llama.cpp model launched without a vision projector:
    #
    #   agent.run_loop(user_message: "what's wrong here?", attachments: [png])
    #   # => UnsupportedAttachmentError: shot.png (image/png): model
    #   #    Qwen3.8-Dense-text takes no vision input
    #
    # Raised before the turn is appended, so the conversation is untouched and
    # the host can simply let the user retry. Sending it instead would cost far
    # more than one failed turn: the server answers HTTP 500, ruby_llm retries
    # that three times, and the image then stays in the history, failing every
    # later turn the same way.
    #
    # The verdict is the transport's stated {ChatTransport#modalities}: only a
    # +false+ for the attachment's kind refuses it (+image/*+ → +:vision+,
    # +audio/*+ → +:audio+, +video/*+ → +:video+), so unstated means it goes
    # out. A tool's refused attachment becomes a note in its result instead.
    class UnsupportedAttachmentError < StandardError
      # @return [Pikuri::Attachment] the refused attachment
      attr_reader :attachment

      # @param attachment [Pikuri::Attachment]
      # @param reason [String] why, e.g. "model X takes no vision input"
      def initialize(attachment, reason)
        @attachment = attachment
        super("#{attachment.filename} (#{attachment.mime}): #{reason}")
      end
    end

    # What {#run_loop} answers a tool call with when its batch unwound — see
    # +== Repairing an unwound tool batch+. Public so a renderer can tell one
    # from a real observation, as {History::INTERRUPTED_RESULT} is for the
    # on-disk shape.
    #
    # Paired per cause: the first unanswered call is the one that raised or was
    # about to, the rest never started, and telling a skipped call "you failed"
    # invites a pointless retry. A tool failure has no constant — it reports
    # +"Error: <class>: <message>"+, the shape {Tool#run} already returns for a
    # validation failure.
    CANCELLED_RESULT = '[Cancelled by the user]'
    # @see CANCELLED_RESULT
    CANCELLED_SKIPPED_RESULT = '[Not executed — the user cancelled this turn]'
    # @see CANCELLED_RESULT
    FAILED_SKIPPED_RESULT = '[Not executed — a previous tool call in this batch failed]'

    # Display line ({Event::ToolResult}'s +summary+) for a call answered by a
    # repair rather than by its tool. One word for all three causes above: the
    # *content* says which, and a status line only has to report that no
    # observation came back.
    INTERRUPTED_SUMMARY = 'Interrupted'

    # @param transport [ChatTransport] model-resolution bundle (+model+ /
    #   +provider+ / +assume_model_exists+ and, off the global server,
    #   +api_base+ / +api_key+). A +nil+ +transport.model+ is filled from
    #   +RubyLLM.config.default_model+.
    # @param system_prompt [String] base system message; the chat sees
    #   this plus every extension's {Extension#system_prompt_snippets},
    #   assembled once by {#assemble_system_prompt}.
    # @param cancellable [Control::Cancellable, nil] cancellation control,
    #   or +nil+ for none (no way to stop a running turn but killing the
    #   process).
    # @param around_request [#call, nil] runs around every LLM HTTP request,
    #   streamed response and retries included — the seam a host throttles
    #   requests against a small server through:
    #
    #     around_request: ->(api_base, cancellable, &request) {
    #       permits_for(api_base).acquire(cancellable) { request.call }
    #     }
    #
    #   Called with the base URL the connection dials (+nil+ for a fixed-base
    #   provider such as Anthropic) and the agent's +cancellable+; must return
    #   the block's value. One request, never a turn: a sub-agent's requests
    #   run while its parent's turn is still open. Survives a model switch, so
    #   it keys on +api_base+ per call rather than closing over a server. Not
    #   inherited by itself — whoever builds a child agent passes
    #   {#around_request} on, as the +agent+ tool does. +nil+ for none.
    # @param id [String] unique id; empty for the main agent, persona-rooted
    #   for sub-agents (+"researcher 0"+, ...). Distinct from a persona's
    #   +name+ (the value the LLM picks in the +agent+ tool's +name:+ arg).
    # @param streaming [Boolean] opt into chunk-level streaming — {#run_loop}
    #   passes a per-chunk block to +Chat#complete+ and normalizes chunks
    #   into {Event::ThinkingDelta}/{Event::AssistantDelta}. Default +false+
    #   (only the +after_message+ bookends fire).
    # @param history [History, nil] a conversation to resume, as
    #   {#export_history} handed it out, or +nil+ to start empty. An extension
    #   reads it as {Configurator#history}; {Event::HistoryLoaded} is emitted
    #   once the agent is built. See {#restore_history} for what comes back
    #   and what is repaired on the way in.
    # @yield [Configurator] the sole path for adding tools, listeners,
    #   extensions, and +on_close+ handlers — there are no parallel ctor
    #   kwargs. Optional; without it the agent has none of those.
    # @return [Agent]
    # @raise [ArgumentError] if +history+ is neither +nil+ nor a {History}.
    def initialize(transport:, system_prompt:,
                   cancellable: nil,
                   around_request: nil,
                   id: '',
                   streaming: false,
                   history: nil,
                   &block)
      unless history.nil? || history.is_a?(History)
        raise ArgumentError, "expected a Pikuri::Agent::History, got #{history.class}"
      end

      @transport = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      @cancellable = cancellable
      @around_request = around_request
      @closed = false

      @system_prompt_base = system_prompt
      @system_prompt = system_prompt
      # Built here, never passed in: a queue handed from one agent to the
      # next would carry a stale mid-turn message into the new conversation.
      @interloper = Control::Interloper.new
      @id = id
      @streaming = streaming
      @on_close_handlers = []
      # Stashed for {#run_configure}, the failure-prone build phase.
      @block = block
      @history = history

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

    # The model the next turn talks to, and what is stated about it:
    #
    #   agent.transport.context_window   # => 32768, or nil when unstated
    #   agent.transport.modalities       # => {vision: false}, or nil when unstated
    #
    # The agent never probes the server, so these are exactly what the host
    # stated, at construction or on a later +run_loop(transport:)+.
    #
    # @return [ChatTransport] with its +model+ filled from
    #   +RubyLLM.config.default_model+ when it was +nil+
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

    # @return [String] system prompt actually sent — the base
    #   +system_prompt:+ plus every extension's
    #   {Extension#system_prompt_snippets}. Not inherited by sub-agents.
    attr_reader :system_prompt

    # @return [Control::Cancellable, nil] the cancellation control, or
    #   +nil+. Extensions read it to propagate cancellation to their own
    #   LLM calls (the +agent+ tool shares it so one Ctrl+C stops the tree).
    attr_reader :cancellable

    # @return [#call, nil] the +around_request:+ hook (see {#initialize}), for
    #   whoever builds a child agent to pass on.
    attr_reader :around_request

    # The agent's own mid-loop input queue — the door a host uses to reach a
    # running turn from another thread:
    #
    #   agent.interloper.inject_user_message('also check the tests')   # lands after this tool batch
    #
    # Drained at turn start and once each tool batch is answered.
    #
    # @return [Control::Interloper]
    attr_reader :interloper

    # @return [String] this agent's id — empty for the main agent,
    #   persona-rooted for sub-agents (+"researcher 0"+). Distinct from the
    #   persona +name+; propagated to listeners via
    #   {ListenerList#for_sub_agent} so id-aware ones tag their output.
    attr_reader :id

    # @return [Boolean] whether this agent opted into chunk-level streaming
    #   (see {#initialize}'s +streaming:+).
    attr_reader :streaming

    # @return [Array<Extension>] extensions added to this agent, whose
    #   +configure+ ran during the +Agent.new+ block. Not inherited by
    #   sub-agents.
    attr_reader :extensions

    # Final assistant message content for the most recent {#run_loop} — the
    # last +:assistant+ message in the underlying chat's history. +nil+ until
    # one has been produced.
    #
    # @return [String, nil]
    def last_assistant_content
      last = @chat.messages.reverse.find { |m| m.role == :assistant }
      last&.content
    end

    # Run the agent loop for one turn. With a +user_message+ or +attachments+,
    # emits an {Event::UserTurn} (+mid_loop: false+) and appends it; with
    # neither, runs a *bare* turn against whatever the conversation + drained injections
    # already hold — the case a host uses after loading a skill on its own
    # initiative, so the agent reacts to it, or for a mid-turn message that
    # arrived after the last tool batch (+D_mid_turn_user_message+). Drains any pending
    # {Control::Interloper} injections, then +complete+s the chat. Output is
    # the listeners' job; subsequent calls build on the same history.
    #
    #   agent.run_loop(user_message: "what's wrong here?",
    #                  attachments: [Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png)])
    #
    # An attachment-only turn is not blank: it goes out with no text part
    # at all, since Anthropic refuses an empty one. {Extension#on_user_message}
    # still fires, with +""+ and the attachments.
    #
    # Cancellation trips are handled per the class header's "Cancellation
    # rescue". A cancel sent before this call — the host already counts the
    # turn as running, its worker hasn't got here yet — ends the turn once the
    # user message is recorded, before any request: the message stays in the
    # history, unanswered, as after a cancel during the prefill.
    #
    # == Switching models mid-conversation
    #
    # A +transport:+ naming another model or connection switches the chat to
    # it (via {#apply_transport!}) and emits {Event::ModelSwitched}. One that
    # differs only in its stated facts — +context_window+, +modalities+ — is
    # the same model, newly described: the agent adopts it silently, emitting
    # nothing. That is how a host that probes the server hands the agent what
    # it learnt:
    #
    #   agent.run_loop(user_message: text, transport: transport.with(context_window: 32_768))
    #
    # The switch is confined to the top of this method because the chat is
    # single-thread-confined — a background thread mutating the connection
    # mid-completion would tear an in-flight stream. The conversation is
    # *not* re-baselined: same conversation, new model, so message count and
    # running context size carry over. +nil+ keeps the current model.
    #
    # == Repairing an unwound tool batch
    #
    # ruby_llm appends the assistant +tool_calls+ message *before* running any
    # of them, so anything unwinding out of the batch — a tool raising, a
    # {Control::Cancellable::Cancelled}, an untrapped +Interrupt+ — leaves
    # calls no +:tool+ message answers. OpenAI and Anthropic 400 on that; a
    # local llama.cpp feeds it to the chat template and the model improvises.
    # So an +ensure+ answers each dangling call
    # ({#repair_dangling_tool_calls!}) and the exception then propagates: a
    # host that keeps the conversation gets one it can still send.
    #
    # +ensure+ rather than a clause per +rescue+, because it also catches what
    # nobody enumerated (+Interrupt+ is no +StandardError+) and it is a no-op
    # on the success path.
    #
    # Unlike {History#repair_interrupted_tool_calls} — the resume path, where a
    # killed process leaves no clue and {History::INTERRUPTED_RESULT} has to be
    # generic — the cause is in hand here and picks the wording.
    #
    # @param user_message [String, nil] the turn's request; +nil+/blank with
    #   no +attachments+ runs a bare turn (see above)
    # @param attachments [Array<Pikuri::Attachment>] files shown to the model
    #   with the request, e.g. a screenshot
    # @param transport [ChatTransport, nil] the transport this turn and later
    #   ones use (see above); +nil+ keeps the current one
    # @raise [Control::Cancellable::Cancelled] if cancelled mid-turn (an
    #   {Event::Cancelled} is emitted first)
    # @raise [ArgumentError] if an attachment is not a {Pikuri::Attachment}
    # @raise [UnsupportedAttachmentError] if the transport's stated
    #   modalities refuse an attachment; nothing is appended
    # @return [nil] after a turn runs
    def run_loop(user_message: nil, attachments: [], transport: nil)
      unless attachments.all?(Pikuri::Attachment)
        raise ArgumentError, "attachments must be Pikuri::Attachments, got #{attachments.map(&:class)}"
      end

      apply_transport!(transport) if transport

      # Deliver host-scheduled injections (e.g. a UI-loaded skill) before the
      # first complete, so a freshly-scheduled block lands this turn rather
      # than only after the next tool batch — ordered ahead of the user
      # message appended below.
      drain_interloper

      text = user_message.to_s.strip.empty? ? nil : user_message
      blank = text.nil? && attachments.empty?

      attachments.each do |a|
        reason = attachment_refusal(a)
        raise UnsupportedAttachmentError.new(a, reason) if reason
      end

      # Append and emit the user turn before the extension dispatch, so any
      # <memory-context> it injects lands *after* the turn it annotates (as a
      # :user turn like every reference block, see {#append_reference_block}).
      # (+ask+ bundles append+complete atomically, leaving no seam to inject
      # between; the halves run explicitly instead.)
      unless blank
        message = { role: :user, content: text }
        message[:attachments] = attachments.map(&:to_ruby_llm) unless attachments.empty?
        track_message(@chat.add_message(message))
        @listeners.on_event(Event::UserTurn.new(content: text.to_s, attachments: attachments, mid_loop: false))
      end
      # The turn's first cancellation point: a plain non-streaming turn with no
      # +around_request+ has no other before its request goes out.
      @cancellable&.check!
      dispatch_ext_on_user_message(text.to_s, attachments) unless blank

      if @streaming
        @chat.complete(&streaming_block)
      else
        @chat.complete
      end
      nil
    rescue Control::Cancellable::Cancelled
      @listeners.on_event(Event::Cancelled.new)
      raise
    ensure
      repair_dangling_tool_calls!($!)
    end

    # Snapshot the conversation as a {History} — the round-trip partner of
    # +Agent.new(history:)+, and the only way a conversation leaves the agent;
    # storing it is the host's.
    #
    #   history = agent.export_history
    #
    # The system prompt is excluded — the resuming agent assembles its own, so
    # a resumed conversation gets today's, not the one that was current when
    # it was exported.
    #
    # Attachment bytes are read here, eagerly, so the snapshot still shows
    # what the model saw after the file has changed on disk.
    #
    # A thinking block withheld from the conversation because another model
    # produced it is restored here from the message's metadata, so the record
    # survives any number of resumes under a switched model.
    #
    # @return [History]
    def export_history
      exported = @chat.messages.reject { |m| m.role == :system }.map do |msg|
        meta = @message_meta[msg] || { id: History.mint_id, kind: 'user' }
        exported_msg = History::Message.from_ruby_llm(
          msg, id: meta[:id], kind: meta[:kind],
               summary: meta[:summary], tool_call_lines: meta[:tool_calls] || {}
        )
        meta[:thinking] ? exported_msg.with(thinking: meta[:thinking]) : exported_msg
      end
      History.new(messages: exported)
    end

    # Release agent-owned resources: fire every handler registered via
    # {Configurator#on_close} in LIFO order,
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
    # constructor can wrap it in a rescue and self-heal. The chat and the
    # listener list exist before the +Agent.new+ block runs, so the
    # {Configurator} it receives can already act on them; the block's tools
    # and system-prompt snippets are wired once it returns. The
    # Configurator's +on_close_sink:+ is +@on_close_handlers+ itself, so a
    # handler armed via +c.on_close+ is live the instant it's registered —
    # what lets the rescue close a half-built agent.
    #
    # @return [void]
    def run_configure
      @chat = build_chat(@transport)
      @listeners = ListenerList.new([])
      configurator = Configurator.new(agent: self, chat: @chat, listeners: @listeners,
                                      history: @history, on_close_sink: @on_close_handlers)

      @block&.call(configurator)

      @tools = configurator.tools.dup
      @sub_agent_tools = configurator.sub_agent_tools.dup
      @extensions = configurator.extensions.dup
      # Assemble now that every extension's +configure+ has run (their
      # snippets read populated state).
      @system_prompt = assemble_system_prompt
      @chat.with_instructions(@system_prompt)
      # One context per agent, so an opting-in +execute+ never has to nil-check
      # what it was handed.
      context = Tool::ExecuteContext.new(cancellable: @cancellable || Control::Cancellable::NEVER)
      refusal = ->(attachment) { attachment_refusal(attachment) }
      @tools.each { |t| @chat.with_tools(t.to_ruby_llm_tool(context: context, refusal: refusal)) }

      # Wire @chat for the event stream and controls via ruby_llm's three
      # registered callbacks. (The per-chunk streaming callback is separate
      # — {#streaming_block} — since ruby_llm takes it as a block to
      # +Chat#complete+, not a registered hook.) With the +@listeners.on_event+
      # calls in {#run_loop}/{#dispatch_ext_on_user_message}, this is the
      # complete callback→event map.
      # Identity-keyed, so nothing can drift out of alignment with
      # +@chat.messages+ the way a parallel array would: a message pikuri
      # never saw is simply absent here, and {#export_history} mints it an id
      # rather than silently pairing it with someone else's.
      @message_meta = {}.compare_by_identity
      # The call ruby_llm is running right now, so +after_tool_result+ — which
      # receives the result *alone* — can name it, and so +after_message+ can
      # put the summary on the +:tool+ message. A single slot, i.e. the
      # ordering assumption, is valid only while +tool_concurrency+ stays off,
      # which {Pikuri::Tool}'s +== Sharing+ asks for on separate grounds. Turn
      # it on and the fix is ruby_llm's +tool_call.ruby_llm+ instrumenter
      # event, whose payload carries +tool_call+ and +result+ together —
      # reachable through the +instrumenter+ slot {RequestInstrumenter} already
      # chains.
      @pending_tool_call = nil

      @chat.after_message do |msg|
        # A +:tool+ message is the one the summary computed just above belongs to.
        summary = @pending_tool_call[:summary] if msg.role == :tool && @pending_tool_call
        track_message(msg, summary: summary)
        emit_after_message(msg)
        drain_interloper if tool_batch_complete?(msg)
      end
      @chat.before_tool_call do |tc|
        tool = pikuri_tool_for(tc.name)
        display_name = tool ? tool.display_name : Tool.display_name_for(tc.name)
        argument = tool ? tool.describe_call(tc.arguments) : Tool.describe_arguments(tc.arguments)
        # Everything that leaves the agent names a call by the server's id,
        # the one {History} stores (+D_history_wire_call_ids+).
        call_id = tc.provider_call_id
        @pending_tool_call = { tool_call_id: call_id, name: tc.name, summary: nil }
        record_tool_call_lines(call_id, display_name: display_name, argument: argument)
        @listeners.on_event(Event::ToolCall.new(
                          tool_call_id: call_id, name: tc.name, arguments: tc.arguments,
                          display_name: display_name, argument: argument
                        ))
        @cancellable&.check!
      end
      @chat.after_tool_result do |result|
        pending = @pending_tool_call || {}
        summary = summarize_tool_result(result)
        pending[:summary] = summary
        @listeners.on_event(Event::ToolResult.new(
                          tool_call_id: pending[:tool_call_id], name: pending[:name],
                          content: tool_result_content(result), summary: summary
                        ))
      end

      @listeners.on_event(restore_history(@history)) if @history
    end

    # Put a saved conversation into the chat — freshly built, or emptied by
    # {#replace_compacted_history}. Restored:
    # messages, tool calls and their results, thinking, attachments,
    # per-message usage. **Not** state living outside the conversation — a
    # workspace's read-before-edit marks, promoted skills, a task list, what an
    # MCP server held: a resumed conversation whose transcript says a file was
    # read is still asked to read it again before editing, which is right,
    # since the file may have changed while the conversation sat on disk.
    # Nothing replays the recorded calls; see +design/decisions.md+
    # +D_history_load_repairs+.
    #
    # Two repairs happen on the way in, each because a stored conversation
    # can describe something a provider will not accept or a model would
    # misread:
    #
    # - A tool call whose result never arrived gets a synthesized one
    #   ({History#repair_interrupted_tool_calls}).
    # - A turn produced by a *different* model loses its whole thinking block
    #   — a foreign one lands in a slot the receiving model reads as its own
    #   scratchpad. Withheld from the conversation only; {#export_history}
    #   still carries it. {#apply_transport!} repeats this for a switch that
    #   happens later. See +design/decisions.md+ +D_thinking_block_replay+.
    #
    # @param history [History]
    # @return [Event::HistoryLoaded] for the caller to emit once the agent is
    #   bound — the conversation is in place before any extension sees it.
    def restore_history(history)
      current_model = @chat.model&.id
      repaired = history.repair_interrupted_tool_calls
      repaired.messages.each do |m|
        keep = keep_thinking?(m.thinking, m.model_id, current_model)
        track_message(@chat.add_message(m.to_ruby_llm(keep_thinking: keep)),
                      kind: m.kind, id: m.id, thinking: (m.thinking unless keep),
                      summary: m.summary, tool_calls: restored_tool_call_lines(m))
      end

      last = repaired.messages.reverse.find { |m| m.role == 'assistant' && m.tokens }
      Event::HistoryLoaded.new(
        messages: repaired.messages.size,
        tokens: last && Event::Tokens.new(**last.tokens.to_h, model_id: last.model_id)
      )
    end

    # Swap the conversation for +history+, a compacted rendering of it, and
    # emit {Event::HistoryCompacted}. The contract, and why nothing else is
    # reset: {Configurator#replace_compacted_history}.
    #
    # @param history [History]
    # @return [void]
    # @raise [ArgumentError] if +history+ is not a {History}, drops the
    #   conversation's last message, or holds a tool result with no call
    # @raise [RuntimeError] inside the +Agent.new+ block, or while a tool
    #   batch is open
    def replace_compacted_history(history)
      raise ArgumentError, "expected a Pikuri::Agent::History, got #{history.class}" unless history.is_a?(History)
      # Set right after the block returns: inside it there is no conversation
      # to compact yet, and resuming one is +history:+'s job.
      raise 'replace_compacted_history called before Agent.new returned' unless @message_meta

      open = unanswered_tool_calls
      unless open.empty?
        # ruby_llm still holds the batch's calls and appends their results
        # after whatever the chat holds by then.
        raise 'cannot replace the history while a tool batch is open: ' \
              "#{open.map { |c| "#{c.name}(#{c.provider_call_id})" }.join(', ')}"
      end
      refuse_bad_compaction(history)

      before = @chat.messages.count { |m| m.role != :system }
      @chat.messages.select! { |m| m.role == :system }
      @message_meta.clear
      @pending_tool_call = nil
      loaded = restore_history(history)
      @listeners.on_event(Event::HistoryCompacted.new(messages_before: before, messages_after: loaded.messages))
      nil
    end

    # The two cuts a compactor can get wrong that no provider reports
    # clearly.
    #
    # Dropping the last message strands whatever ruby_llm does next: from a
    # listener at the end of a turn, a history ending on a user message draws
    # a request nobody asked for.
    #
    # A tool result whose call was cut away is a 400 on OpenAI and Anthropic,
    # and on llama.cpp a template that improvises.
    #
    # @param history [History]
    # @return [void]
    # @raise [ArgumentError] on either
    def refuse_bad_compaction(history)
      last = @chat.messages.reverse.find { |m| m.role != :system }
      last_id = last && @message_meta.dig(last, :id)
      if last_id && history.messages.last&.id != last_id
        raise ArgumentError, "a compacted history must end with the conversation's last message #{last_id}, " \
                             "got #{history.messages.last&.id.inspect}"
      end

      calls = []
      history.messages.each do |m|
        unless m.role == 'tool'
          calls = m.tool_calls.map(&:id)
          next
        end
        next if calls.include?(m.tool_call_id)

        raise ArgumentError, "tool result #{m.id} answers #{m.tool_call_id.inspect}, " \
                             'a call the assistant turn before it did not make'
      end
    end

    # Build the full prompt: base plus every extension's
    # {Extension#system_prompt_snippets}, in registration order, joined by
    # blank lines. Blank/nil sections drop (an extension contributing
    # nothing leaves no stray separator). Runs once, at construction.
    #
    # That one call site is a *price* rather than a missing feature: a stable prefix is free after turn one
    # (llama.cpp slot prefix-reuse, Anthropic's prompt cache), where amending
    # one invalidates every cached token after the change point and
    # re-prefills. Hence there is no amend-the-prompt seam — mid-conversation
    # blocks go through {#append_reference_block}, which appends and
    # invalidates nothing. See `design/decisions.md` `D_reference_text_as_user_turn`.
    #
    # @return [String]
    def assemble_system_prompt
      sections = @extensions.flat_map(&:system_prompt_snippets)
      [@system_prompt_base, *sections]
        .reject { |s| s.nil? || s.to_s.strip.empty? }
        .join("\n\n")
    end

    # The {ChatTransport#modalities} key an attachment's MIME family needs, in
    # llama.cpp's vocabulary. A family not listed here (a PDF) is never refused.
    MODALITY_BY_MEDIA_TYPE = { 'image' => :vision, 'audio' => :audio, 'video' => :video }.freeze
    private_constant :MODALITY_BY_MEDIA_TYPE

    # Why the model can't take +attachment+, per the transport's stated
    # modalities.
    #
    # @param attachment [Pikuri::Attachment]
    # @return [String, nil] the reason, e.g. "model X takes no vision input";
    #   +nil+ when it may go out, including whenever acceptance is unstated
    def attachment_refusal(attachment)
      modality = MODALITY_BY_MEDIA_TYPE[attachment.mime.to_s.split('/').first]
      return nil unless modality && @transport.modalities&.[](modality) == false

      "model #{@transport.model} takes no #{modality} input"
    end

    # Adopt +transport+ for this turn on: a switch when it names another model
    # or connection, a fact update when only +context_window+ / +modalities+
    # differ. Called only from the top of {#run_loop} (see its "Switching
    # models" section for the thread-confinement reason). Mirrors
    # {#initialize}'s +nil+-model fill before comparing, so a transport
    # deferring to the default model doesn't switch spuriously.
    #
    # A fact update touches nothing but +@transport+ and emits nothing: the
    # chat, its connection and the history's thinking all belong to the same
    # model as before, and the host that made the update already knows it.
    #
    # A switch rebuilds the connection the way {#build_chat} built the first
    # one — a fresh +RubyLLM::Context+ via +Chat#with_context+, then
    # +Chat#with_model+, both of which keep history and callbacks — and emits
    # {Event::ModelSwitched}. The context is rebuilt on every switch, not only
    # a cross-server one, so nothing of the old transport's connection can
    # linger: its base URL and key, its +faraday_adapter+, the base URL the
    # {RequestInstrumenter} reports. The new transport's +params+ replace the
    # old one's, so a switch cannot leave a thinking-off kwarg on a connection
    # that never asked for one.
    #
    # Because the history is kept, every turn in it is now potentially from
    # another model, so {#strip_foreign_thinking!} runs before the event —
    # {#restore_history}'s repair only covers a conversation that arrives stale.
    #
    # Why switch in place rather than have the host rebuild the agent around
    # {#export_history}: +design/decisions.md+ +D_model_switch_in_place+.
    #
    # @param transport [ChatTransport] the model to switch to
    # @return [void]
    def apply_transport!(transport)
      filled = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      old = @transport
      @transport = filled
      return if filled.with(context_window: old.context_window, modalities: old.modalities) == old

      @chat.with_context(build_context(filled))
      @chat.with_model(filled.model, provider: filled.provider, assume_model_exists: filled.assume_model_exists)
      @chat.with_provider_options(filled.params)
      strip_foreign_thinking!
      @listeners.on_event(Event::ModelSwitched.new(from: old, to: filled))
    end

    # Build the chat for +transport+ — always through a dedicated
    # +RubyLLM::Context+, never +RubyLLM.chat+, so every chat this agent builds
    # carries the +around_request+ hook and any +faraday_adapter+. A no-override
    # transport gets a plain dup of the global config, which resolves the model
    # exactly as +RubyLLM.chat+ would.
    #
    # A transport's +params+ ride the *chat* rather than the context, because
    # ruby_llm deep-merges them into the completion payload — see
    # {ChatTransport}'s +== Extra request parameters+.
    #
    # @param transport [ChatTransport]
    # @return [RubyLLM::Chat]
    def build_chat(transport)
      build_context(transport).chat(**transport.chat_kwargs).with_provider_options(transport.params)
    end

    # A +RubyLLM::Context+ carrying +transport+'s connection overrides on the
    # provider's config slots (+#{provider}_api_base+ / +_api_key+).
    # +RubyLLM.context+ dups the global config, so an absent override inherits
    # the global value and a no-override transport yields a plain dup — which
    # is how a switch back to a global-config model drops a prior override.
    # +ChatTransport+
    # guarantees a non-+nil+ +provider+ whenever an override is set.
    #
    # A transport's +faraday_adapter+ (if any) is installed here too: the
    # adapter rides *this* context's config, not the process-global
    # +RubyLLM.config+, so it stays per-agent — the seam
    # {Pikuri::Testing.fake_transport} uses to run the real ruby_llm loop
    # against a scripted HTTP backend.
    #
    # So does the {RequestInstrumenter}, on the same config's +instrumenter+
    # slot, when the agent has an +around_request+ hook: global config
    # untouched, and handed the base URL the connection will actually dial —
    # which is why it is read *after* the override assignments.
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
        # ruby_llm defaults :openai to OpenAI's Responses API (+/v1/responses+);
        # llama.cpp and the other OpenAI-compatible servers pikuri targets speak
        # Chat Completions, which OpenAI itself still serves too.
        c.openai_protocol = :chat_completions
        # llama.cpp with +--reasoning-format none+ leaves reasoning inline as
        # +<think>…</think>+; a server sending +reasoning_content+ is untouched.
        c.split_think_tags = true
        if @around_request
          RequestInstrumenter.install(c, hook: @around_request, api_base: dialed_api_base(slug, c),
                                         cancellable: @cancellable)
        end
      end
    end

    # The base URL the connection dials, read off the context config the chat
    # is about to use rather than re-derived, so it can't drift from the
    # connection.
    #
    # @param slug [Symbol, nil] the transport's provider.
    # @param config [RubyLLM::Configuration] this context's config, connection
    #   overrides already applied.
    # @return [String, nil] the base URL, or +nil+ when the provider names no
    #   +_api_base+ slot (a fixed-base provider like Anthropic) or has none
    #   configured.
    def dialed_api_base(slug, config)
      return nil if slug.nil?

      reader = "#{slug}_api_base"
      config.respond_to?(reader) ? config.public_send(reader) : nil
    end

    # Fire {Extension#on_user_message} on every extension, appending any
    # returned text via {#append_reference_block} right after the user turn it
    # annotates (the caller appends the +:user+ message first).
    #
    # Called unconditionally — the {Extension} no-op default returns +nil+
    # (injects nothing), so opting out means leaving the default, not omitting
    # the method.
    #
    # @param content [String] the incoming user message's text; +""+ when it
    #   carries only attachments
    # @param attachments [Array<Pikuri::Attachment>] what went out with it
    # @return [void]
    def dispatch_ext_on_user_message(content, attachments)
      @extensions.each do |ext|
        message = ext.on_user_message(content, attachments)
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
    # (Anthropic's +system+ param, Bedrock's +system+ blocks) merge it into
    # the standing system prompt, so the block is presented as though it had
    # always been there and stays in force. Neither failure is visible from
    # anything pikuri can observe: the message is in the payload, the listener
    # stream renders it, the history holds it. See +design/decisions.md+
    # +D_reference_text_as_user_turn+.
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
      # Tagged +reference+ so a restored conversation can tell pikuri's own
      # injection from something the human typed — both land as +:user+.
      track_message(@chat.add_message(role: :user, content: "<#{REFERENCE_TAG}>\n#{body}\n#{close}"),
                    kind: 'reference')
      @listeners.on_event(Event::SystemInjected.new(content: content))
      nil
    end

    # Remember pikuri's own identity for a message just added to the chat, so
    # {#export_history} can hand out a stable id, say whether a +:user+ message
    # was typed or injected, and put back a thinking block the conversation is
    # not replaying. None of it ever reaches a provider.
    #
    # Keyed on the message *object*, so a caller that rebuilds one must move
    # its entry across — see {#strip_foreign_thinking!}.
    #
    # @param msg [RubyLLM::Message] as returned by +Chat#add_message+.
    # @param kind [String] one of {History::KINDS}.
    # @param id [String, nil] an existing id to preserve (restoring a saved
    #   conversation); +nil+ mints a fresh one.
    # @param thinking [History::Thinking, nil] a block withheld from +msg+
    #   because another model produced it, kept so the export stays faithful.
    # @param summary [String, nil] a +:tool+ message's display line (see
    #   {Pikuri::Tool::Result}); nothing can recompute one after the fact, so
    #   the export carries it.
    # @param tool_calls [Hash{String=>Hash}, nil] per-call display strings for
    #   an assistant turn, +{call_id => {display_name:, argument:}}+.
    # @return [RubyLLM::Message] +msg+, so call sites can wrap in place.
    def track_message(msg, kind: 'user', id: nil, thinking: nil, summary: nil, tool_calls: nil)
      unless msg.role == :system
        @message_meta[msg] = { id: id || History.mint_id, kind: kind, thinking: thinking,
                               summary: summary, tool_calls: tool_calls }
      end
      msg
    end

    # @param msg [History::Message] a message being restored.
    # @return [Hash{String=>Hash}, nil] its calls' persisted display strings,
    #   in {#track_message}'s shape, so a re-export round-trips them; +nil+
    #   when the message asked for no tools.
    def restored_tool_call_lines(msg)
      return nil if msg.tool_calls.empty?

      msg.tool_calls.to_h { |c| [c.id, { display_name: c.display_name, argument: c.argument }] }
    end

    # The {Pikuri::Tool} behind a registered tool name, or +nil+ for one that
    # never was a +Pikuri::Tool+ (an MCP tool) or a name ruby_llm has no tool
    # for (its unavailable-tool error).
    #
    # Read off ruby_llm's own +Chat#tools+ table rather than {#tools}: the
    # +agent+ and +mcp_connect+ tools register through
    # {Configurator#add_raw_tool}, which deliberately keeps them out of
    # that list, and an index over it would miss their overrides.
    #
    # @param name [String] the tool name ruby_llm is calling.
    # @return [Pikuri::Tool, nil]
    def pikuri_tool_for(name)
      wrapper = @chat.tools[name.to_sym]
      wrapper.respond_to?(:pikuri_tool) ? wrapper.pikuri_tool : nil
    end

    # Record one call's display strings on the assistant message that asked for
    # it, so {#export_history} can persist them — a later wiring may no longer
    # have the tool (a removed extension, a renamed MCP server), and then
    # nothing could recompute the line.
    #
    # @param call_id [String] the provider's tool-call id.
    # @param display_name [String] see {Pikuri::Tool#display_name}.
    # @param argument [String] see {Pikuri::Tool#describe_call}.
    # @return [void]
    def record_tool_call_lines(call_id, display_name:, argument:)
      opener = @chat.messages.reverse.find do |m|
        m.role == :assistant && m.tool_calls&.each_value&.any? { |c| c.provider_call_id == call_id }
      end
      meta = opener && @message_meta[opener]
      return unless meta

      (meta[:tool_calls] ||= {})[call_id] = { display_name: display_name, argument: argument }
      nil
    end

    # A {Pikuri::Tool} answers its own summary; everything else is derived. The
    # +else+ is not a pikuri tool falling back — it is the three payloads that
    # never went through {Pikuri::Tool#run}: an MCP tool's String, ruby_llm's
    # unavailable-tool +Hash+, and the +[note, *attachments]+ Array the wrapper
    # unwrapped an attachment {Pikuri::Tool::Result} into
    # ({Pikuri::Tool#to_ruby_llm_tool}).
    #
    # @param result [Pikuri::Tool::Result, String, Array<String,
    #   RubyLLM::Attachment>, Hash] what ruby_llm handed +after_tool_result+.
    # @return [String] the one-line result summary for the listener stream.
    def summarize_tool_result(result)
      result.is_a?(Tool::Result) ? result.summary : Tool.describe_content(result)
    end

    # {Event::ToolResult#content} for +result+: an attachment observation
    # arrives as its text note, so a listener never holds the bytes.
    #
    # @param result [Pikuri::Tool::Result, String, Array<String,
    #   RubyLLM::Attachment>, Hash] what ruby_llm handed +after_tool_result+.
    # @return [String, Hash] the observation text; ruby_llm's unavailable-tool
    #   +Hash+ passes through.
    def tool_result_content(result)
      case result
      when Tool::Result then result.content
      when Array then result.grep(String).join("\n\n")
      else result
      end
    end

    # Whether a turn's thinking may be replayed to +current+ — true only where
    # this model demonstrably produced it.
    #
    # Unknown provenance counts as foreign: a +model_id+ nobody recorded is
    # indistinguishable from another model's, and attributing one model's
    # reasoning to another is the failure this guards against.
    #
    # The two ids come from different places — +current+ is what pikuri
    # *requested*, +model_id+ what the server *reported* — so a backend that
    # does not echo the requested id back makes every turn look foreign. That
    # only ever over-drops (a model loses its own reasoning; none is ever
    # attributed to another), which is why the weaker test is tolerated; the
    # fakes in +Pikuri::Testing+ are themselves such a backend. Measured
    # echoing verbatim on llama.cpp — see +design/decisions.md+
    # +D_thinking_block_replay+.
    #
    # @param thinking [History::Thinking, RubyLLM::Thinking, nil]
    # @param model_id [String, nil] who produced the turn.
    # @param current [String, nil] the agent's model now.
    # @return [Boolean]
    def keep_thinking?(thinking, model_id, current)
      thinking.nil? || (!model_id.nil? && model_id == current)
    end

    # Withhold every thinking block the current model did not produce from the
    # live conversation, parking it in +@message_meta+ so {#export_history}
    # still writes it.
    #
    # {#restore_history} covers a conversation that arrives stale; this covers
    # one that goes stale under a running agent, which +Chat#with_model+ leaves
    # untouched. +RubyLLM::Message+ has no thinking writer, so a stripped turn
    # is a rebuilt object and its metadata is re-keyed onto the replacement.
    #
    # @return [void]
    def strip_foreign_thinking!
      current = @chat.model&.id
      @chat.messages.map! do |msg|
        next msg if keep_thinking?(msg.thinking, msg.model, current)

        meta = @message_meta.delete(msg) || { id: History.mint_id, kind: 'user' }
        stripped = RubyLLM::Message.new(
          role: msg.role, content: msg.content, tool_calls: msg.tool_calls,
          tool_call_id: msg.tool_call_id, model: msg.model, attachments: msg.attachments,
          tokens: msg.tokens, raw: msg.raw, thinking: nil
        )
        @message_meta[stripped] = meta.merge(
          thinking: History::Thinking.new(text: msg.thinking.text, signature: msg.thinking.signature)
        )
        stripped
      end
    end

    # Answer every call the last assistant turn left unanswered, emitting each
    # synthesized observation as an {Event::ToolResult} so a host can show what
    # it appended. Rationale in {#run_loop}'s +== Repairing an unwound tool
    # batch+.
    #
    # Order carries the first-vs-rest split ({CANCELLED_RESULT}): +tool_calls+
    # is insertion-ordered and ruby_llm runs it with +each_value+, so the first
    # gap is the culprit — true only while +tool_concurrency+ stays off, which
    # {Pikuri::Tool}'s +== Sharing+ asks for on separate grounds.
    #
    # Not {History#repair_interrupted_tool_calls}: damage here is always the
    # tail, and that walk is over +History::Message+, whose +role+ is a +String+
    # where ruby_llm's is a +Symbol+.
    #
    # @param cause [Exception, nil] what the turn is unwinding with; +nil+ on
    #   the success path, where nothing dangles.
    # @return [void]
    # @raise [RuntimeError] if calls dangle with no +cause+ — pikuri lost a
    #   batch on a turn that succeeded. Safe to raise from an +ensure+ here
    #   precisely because there is no in-flight exception to clobber.
    def repair_dangling_tool_calls!(cause)
      dangling = unanswered_tool_calls
      return if dangling.empty?

      if cause.nil?
        raise 'unanswered tool calls on a turn that did not unwind: ' \
              "#{dangling.map { |c| "#{c.name}(#{c.provider_call_id})" }.join(', ')}"
      end

      culprit, skipped = unanswered_results(cause)
      dangling.each_with_index do |call, i|
        content = i.zero? ? culprit : skipped
        # +call.id+ is ruby_llm's own; it maps the answer back to the server's
        # id on the wire. The event names the server's, like every other one.
        track_message(@chat.add_message(role: :tool, content: content, tool_call_id: call.id),
                      summary: INTERRUPTED_SUMMARY)
        @listeners.on_event(Event::ToolResult.new(tool_call_id: call.provider_call_id, name: call.name,
                                             content: content, summary: INTERRUPTED_SUMMARY))
      end
      LOGGER.warn { "answered #{dangling.size} dangling tool call(s) after #{cause.class}" }
      nil
    end

    # @param cause [Exception]
    # @return [Array(String, String)] what the call that raised (or was about
    #   to) is told, then what the calls behind it that never started are told.
    #   See {CANCELLED_RESULT}.
    def unanswered_results(cause)
      case cause
      when Control::Cancellable::Cancelled then [CANCELLED_RESULT, CANCELLED_SKIPPED_RESULT]
      # Deliberately unsanitized: the message can carry untrusted bytes (a
      # filename off a scraped page), which {Tool#run}'s own +"Error: ..."+
      # already puts in the conversation — and a model cannot react to a
      # failure it is not told about.
      else ["Error: #{cause.class}: #{cause.message}", FAILED_SKIPPED_RESULT]
      end
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
      msg.role == :tool && unanswered_tool_calls.empty?
    end

    # @return [Array<RubyLLM::ToolCall>] the calls of the last assistant
    #   turn that asked for tools which no +:tool+ message answers yet, in
    #   the order ruby_llm runs them; empty when no batch is open.
    def unanswered_tool_calls
      messages = @chat.messages
      opener_index = messages.rindex { |m| m.role == :assistant && m.tool_calls&.any? }
      return [] if opener_index.nil?

      answered = messages[(opener_index + 1)..].filter_map { |m| m.tool_call_id if m.role == :tool }
      messages[opener_index].tool_calls.each_value.reject { |c| answered.include?(c.id) }
    end

    # Normalize an +after_message+ payload into zero, one, or two {Event}s
    # (+Thinking+ and/or +Assistant+) plus one {Event::Tokens}. Empty
    # thinking/content are filtered here so listeners never see vacuous
    # events; non-assistant roles are skipped.
    #
    # @param msg [RubyLLM::Message]
    # @return [void]
    def emit_after_message(msg)
      return unless msg.role == :assistant

      text = msg.thinking&.text
      @listeners.on_event(Event::Thinking.new(content: text)) if text && !text.empty?

      content = msg.content
      @listeners.on_event(Event::Assistant.new(content: content)) if content.is_a?(String) && !content.empty?

      @listeners.on_event(Event::Tokens.new(
                        input: msg.tokens.input,
                        output: msg.tokens.output,
                        cached: msg.tokens.cache_read,
                        cache_creation: msg.tokens.cache_write,
                        thinking: msg.tokens.thinking,
                        model_id: msg.model
                      ))
    end

    # Normalize a streaming +RubyLLM::Chunk+ into delta events
    # ({Event::ThinkingDelta}/{Event::AssistantDelta}). Empty fragments are
    # filtered; tool-call deltas skipped (see {#streaming_block}).
    #
    # @param chunk [RubyLLM::Chunk]
    # @return [void]
    def emit_chunk(chunk)
      thinking = chunk.thinking&.text
      @listeners.on_event(Event::ThinkingDelta.new(content: thinking)) if thinking && !thinking.empty?
      content = chunk.content
      @listeners.on_event(Event::AssistantDelta.new(content: content)) if content.is_a?(String) && !content.empty?
    end

    # Drain the interloper queue, landing each item per its
    # {Control::Interloper::Item#kind}:
    #
    # - +:user+ — append +role: :user+ verbatim, emit {Event::UserTurn}
    #   (+mid_loop: true+), then run the {Extension#on_user_message} dispatch
    #   (so mid-loop injections are prefetched + recorded like initial turns).
    #   The dispatch runs *after* the append so an injected +<memory-context>+
    #   lands right behind the turn it annotates. An attachment the stated
    #   {ChatTransport#modalities} refuse is withheld with a {Pikuri::Attachment#withheld_note} in the
    #   text, never raised: this runs inside the turn, which a raise would end.
    #   The +UserTurn+ carries what was sent, notes included; the extension
    #   dispatch gets the user's own text (+""+ on an attachment-only item)
    #   and the attachments that went out.
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
          drain_user_item(item)
        when :system
          append_reference_block(item.content)
        else
          raise "unknown interloper item kind: #{item.kind.inspect}"
        end
      end
    end

    # Land one +:user+ {Control::Interloper::Item}; see {#drain_interloper}.
    #
    # @param item [Control::Interloper::Item]
    # @return [void]
    def drain_user_item(item)
      refused, sent = item.attachments.map { |a| [a, attachment_refusal(a)] }.partition(&:last)
      sent = sent.map(&:first)
      text = [item.content, *refused.map { |a, reason| a.withheld_note(reason) }]
             .reject { |t| t.to_s.strip.empty? }.join("\n\n")
      message = { role: :user, content: text.empty? ? nil : text }
      message[:attachments] = sent.map(&:to_ruby_llm) unless sent.empty?
      track_message(@chat.add_message(message))
      @listeners.on_event(Event::UserTurn.new(content: text, attachments: sent, mid_loop: true))
      dispatch_ext_on_user_message(item.content, sent)
    end
  end
end
