# frozen_string_literal: true

RSpec.describe Pikuri::Agent do
  # Minimal stand-in for +RubyLLM::Chat+ that captures every callback
  # pikuri registers, lets the spec fire them with synthetic
  # +RubyLLM::Message+ / +RubyLLM::ToolCall+ payloads, and records
  # what +Pikuri::Agent+ configures (system prompt, tools, +ask+
  # calls, +add_message+ calls). Pins the agent-level wiring
  # without going anywhere near a real provider.
  #
  # Minimal +RubyLLM::Chat#model+ stand-in. Cap detection no longer
  # reads it (the probe keys off the transport + global config — see
  # {Pikuri::Agent::ContextWindowDetector}), but a real Chat exposes
  # +#model+, so the fake mirrors that.
  fake_model = Struct.new(:context_window, :id).new(nil, 'm')

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions, :hooks, :added_messages, :stream_block

      define_method(:initialize) do
        @tools = []
        @asks = []
        @messages = []
        @added_messages = []
        @hooks = Hash.new { |h, k| h[k] = [] }
        @model_info = captured_model
        @stream_block = nil
      end

      def model
        @model_info
      end

      def with_instructions(text)
        @instructions = text
        self
      end

      def with_tool(tool)
        @tools << tool
        self
      end

      # Records each model switch as a [model, provider, assume_exists]
      # triple so specs can assert +apply_transport!+ forwarded the full
      # transport (and used ruby_llm's +assume_exists:+ kwarg name). The
      # history (not just the latest) survives, mirroring a real Chat.
      attr_reader :model_switches

      def with_model(model_id, provider: nil, assume_exists: false)
        (@model_switches ||= []) << [model_id, provider, assume_exists]
        self
      end

      def after_message(&block);     @hooks[:after_message] << block;     self; end
      def before_tool_call(&block);  @hooks[:before_tool_call] << block;  self; end
      def after_tool_result(&block); @hooks[:after_tool_result] << block; self; end

      def add_message(attrs)
        @added_messages << attrs
      end

      def ask(message, &block)
        @asks << message
        @stream_block = block
        nil
      end

      # +#run_loop+ never calls +#ask+ — it appends the user message
      # via +#add_message+ and then drives completion via +#complete+ (the
      # two halves +RubyLLM::Chat#ask+ is sugar for), so the memory
      # dispatch can inject a +:system+ block between them. +#ask+ stays
      # as a tripwire: specs assert +asks+ remains empty.
      def complete(&block)
        @completes = (@completes || 0) + 1
        @stream_block = block
        nil
      end

      attr_reader :completes

      def fire(name, *args)
        @hooks[name].each { |cb| cb.call(*args) }
      end

      # Synthesize a chunk and feed it through the streaming block
      # the agent passed to +#ask+. Tests use this to assert the
      # per-chunk emit logic without depending on the real
      # +RubyLLM::Chunk+ class (we duck-type +.thinking+ and
      # +.content+).
      def fire_chunk(content: nil, thinking: nil)
        chunk = Struct.new(:content, :thinking).new(
          content,
          thinking ? RubyLLM::Thinking.new(text: thinking) : nil
        )
        @stream_block&.call(chunk)
      end

      def add_assistant(content, thinking: nil)
        thinking_obj = thinking ? RubyLLM::Thinking.new(text: thinking) : nil
        msg = RubyLLM::Message.new(role: :assistant, content: content, thinking: thinking_obj)
        @messages << msg
        msg
      end
    end
  end

  let(:fake_chat)  { fake_chat_class.new }
  let(:recorder)   { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:listeners)  { Pikuri::Agent::ListenerList.new([recorder]) }
  let(:step_limit) { Pikuri::Agent::Control::StepLimit.new(max: 2) }

  before do
    captured = fake_chat
    @original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**_| captured }
  end

  after do
    original = @original_chat
    RubyLLM.define_singleton_method(:chat) { |**kwargs| original.call(**kwargs) }
  end

  describe '#initialize' do
    it 'registers system prompt and tools on the underlying chat' do
      tool = Pikuri::Tool.new(
        name: 't', description: 'd',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :x, 'x' },
        execute: ->(x:) { x }
      )
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 'be terse') do |c|
        c.add_tool tool
        c.add_listener recorder
      end

      assert_equal 'be terse', fake_chat.instructions
      assert_equal 1, fake_chat.tools.size
      wired = fake_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 't', wired.name
    end

    it 'wires exactly one callback per chat-event channel — the Agent is the sole emitter' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's',
                        step_limit: step_limit,
                        cancellable: Pikuri::Agent::Control::Cancellable.new,
                        interloper: Pikuri::Agent::Control::Interloper.new) do |c|
        c.add_listener recorder
      end

      assert_equal 1, fake_chat.hooks[:after_message].size
      assert_equal 1, fake_chat.hooks[:before_tool_call].size
      assert_equal 1, fake_chat.hooks[:after_tool_result].size
    end

    it 'defaults to an empty tool list and an empty ListenerList when the block is omitted' do
      # With the Configurator-only wiring, an agent constructed
      # without a block has nothing wired by the host.
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's')

      assert_equal [], agent.tools
      # No public listeners reader (the API is sealed — see
      # ExtensionContext); the banner is the observable surface.
      assert_includes agent.to_s, 'listeners=[]'
    end

    it 'defaults id to empty (main agent)' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }

      assert_equal '', agent.id
    end

    describe 'self-healing construction + Pikuri::Finalizers' do
      # Isolate the process-global registry so these assertions see only
      # what this example registers.
      around do |example|
        saved = Pikuri::Finalizers.instance_variable_get(:@registered)
        Pikuri::Finalizers.instance_variable_set(:@registered, [])
        example.run
      ensure
        Pikuri::Finalizers.instance_variable_set(:@registered, saved)
      end

      it 'registers itself with Finalizers, and #close unregisters' do
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's') { |c| c.add_listener recorder }

        assert_includes Pikuri::Finalizers.instance_variable_get(:@registered), agent
        agent.close
        refute_includes Pikuri::Finalizers.instance_variable_get(:@registered), agent
      end

      it 'closes a half-built agent: a block that raises after arming on_close still fires it' do
        # The generalized leak guard. The block arms cleanup (as an
        # extension's #configure would) and then raises. The constructor
        # rescue must fire the armed handler, drop out of the registry,
        # and re-raise — no partial state survives.
        cleaned = false

        assert_raises(RuntimeError) do
          Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                            system_prompt: 's') do |c|
            c.on_close { cleaned = true }
            raise 'boom mid-config'
          end
        end

        assert cleaned, 'on_close handler armed before the failure must still fire'
        assert_empty Pikuri::Finalizers.instance_variable_get(:@registered)
      end
    end
  end

  describe '#close' do
    # Extension-driven lifecycle tests (MCP's on_close handler, etc.)
    # live in the sibling gems' spec/ directories — see
    # pikuri-mcp/spec/pikuri/mcp/agent_integration_spec.rb. The
    # on_close handler mechanism itself is exercised in the
    # +#close + #on_close+ describe at the bottom of this file.
    it 'is a no-op when no extensions register on_close handlers' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }
      # Must not raise.
      agent.close
      agent.close
    end
  end

  describe 'agent state surface' do
    it 'exposes an explicitly passed id' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', id: 'researcher 0') do |c|
        c.add_listener recorder
      end

      assert_equal 'researcher 0', agent.id
    end

    it 'emits a one-shot Event::ContextCap at construction so TokenLog can pick the cap up' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', context_window: 32_768) do |c|
        c.add_listener recorder
      end

      cap_events = recorder.events.select { |e| e.is_a?(Pikuri::Agent::Event::ContextCap) }
      assert_equal 1, cap_events.size
      assert_equal 32_768, cap_events.first.cap
    end

    describe 'context-window detection' do
      let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }

      def wire_token_log(c)
        c.add_listener recorder
        c.add_listener token_log
      end

      it 'pushes the explicit cap onto every TokenLog via the ContextCap event' do
        # The transport has no :openai provider, so the probe never runs;
        # the explicit context_window: is used verbatim.
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's', context_window: 32_768) { |c| wire_token_log(c) }

        assert_equal 32_768, token_log.context_window_cap
      end

      it 'exposes the resolved cap via #context_window_cap' do
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's', context_window: 8_192) { |c| wire_token_log(c) }

        assert_equal 8_192, agent.context_window_cap
      end

      it 'leaves cap nil when there is no explicit cap and the probe does not apply' do
        # Non-:openai transport → ContextWindowDetector returns nil
        # without probing, and no explicit context_window: was given.
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's') { |c| wire_token_log(c) }

        assert_nil agent.context_window_cap
        assert_nil token_log.context_window_cap
      end
    end

    describe 'switching models via run_loop(transport:)' do
      let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }

      def build_agent
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's', context_window: 8_192) do |c|
          c.add_listener recorder
          c.add_listener token_log
        end
      end

      it 'forwards the full transport to Chat#with_model on a different transport' do
        agent = build_agent
        agent.run_loop(user_message: 'hi',
                       transport: Pikuri::Agent::ChatTransport.new(
                         model: 'big', provider: :openai, assume_model_exists: true
                       ))

        assert_equal [['big', :openai, true]], fake_chat.model_switches
        assert_equal 'big', agent.model
      end

      it 'does not switch when the transport is structurally identical' do
        agent = build_agent
        agent.run_loop(user_message: 'hi', transport: Pikuri::Agent::ChatTransport.new(model: 'm'))

        assert_nil fake_chat.model_switches
        assert_equal 'm', agent.model
      end

      it 'emits ModelSwitched then a fresh ContextCap on a switch' do
        agent = build_agent
        recorder.events.clear
        agent.run_loop(user_message: 'hi',
                       transport: Pikuri::Agent::ChatTransport.new(
                         model: 'big', provider: :openai, assume_model_exists: true
                       ))

        kinds = recorder.events.map(&:class)
        switched = kinds.index(Pikuri::Agent::Event::ModelSwitched)
        cap = kinds.index(Pikuri::Agent::Event::ContextCap)
        refute_nil switched
        refute_nil cap
        assert switched < cap, 'ModelSwitched must precede the new ContextCap'

        ev = recorder.events.find { |e| e.is_a?(Pikuri::Agent::Event::ModelSwitched) }
        assert_equal 'm', ev.from.model
        assert_equal 'big', ev.to.model
      end

      it 'keeps the explicit cap sticky across a switch (no re-probe)' do
        agent = build_agent
        agent.run_loop(user_message: 'hi',
                       transport: Pikuri::Agent::ChatTransport.new(
                         model: 'big', provider: :openai, assume_model_exists: true
                       ))

        assert_equal 8_192, agent.context_window_cap
        assert_equal 8_192, token_log.context_window_cap
      end
    end
  end

  # Sub-agent / persona / Extension specs (formerly the
  # 'Configurator#allow_agent' describe) live in
  # pikuri-subagents/spec/pikuri/sub_agent/ now — the wiring left
  # pikuri-core when Pikuri::SubAgent::Extension landed.

  describe '#run_loop' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: {}) }

    it 'appends user_message as a :user message and drives completion' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }
      agent.run_loop(user_message: 'hello?')

      assert_equal [{ role: :user, content: 'hello?' }], fake_chat.added_messages
      assert_equal 1, fake_chat.completes
    end

    it 'emits an Event::UserTurn(mid_loop: false) to every listener before asking the chat' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }
      agent.run_loop(user_message: 'hello?')

      turn = recorder.events.find do |e|
        e.is_a?(Pikuri::Agent::Event::UserTurn) && e.content == 'hello?'
      end
      refute_nil turn
      refute turn.mid_loop
    end

    it 'resets the step_limit between turns so a fresh turn can spend the budget again' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's',
                                step_limit: step_limit) { |c| c.add_listener recorder }

      # Burn the budget on turn 1 by firing the chat's before_tool_call
      # callback the agent installed during construction.
      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)

      agent.run_loop(user_message: 'turn 2 starts now')

      # Two fresh tool calls land without raising — counter was reset
      # when run_loop called step_limit.reset! at the turn boundary.
      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)
    end

    it 'resets the cancellable at the turn boundary so a stale flag does not poison the next turn' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's',
                                cancellable: cancel) { |c| c.add_listener recorder }

      # Pre-set the flag (e.g. left over from a prior rescue path).
      cancel.cancel!
      assert cancel.cancelled?

      # run_loop calls reset! at the turn boundary before forwarding to
      # chat.ask, so the stale flag is cleared.
      agent.run_loop(user_message: 'turn')

      refute cancel.cancelled?
    end

    describe 'blank input rejection' do
      # Force eager construction so the ContextCap event emitted at
      # construction time doesn't get attributed to run_loop's
      # observable behaviour.
      let!(:agent) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's') { |c| c.add_listener recorder }
      end

      it 'raises ArgumentError on nil and never reaches the chat or listeners' do
        before_events = recorder.events.size

        err = assert_raises(ArgumentError) { agent.run_loop(user_message: nil) }
        assert_match(/blank/, err.message)
        assert_equal [], fake_chat.asks
        assert_equal before_events, recorder.events.size
      end

      it 'raises ArgumentError on an empty string' do
        err = assert_raises(ArgumentError) { agent.run_loop(user_message: '') }
        assert_match(/blank/, err.message)
        assert_equal [], fake_chat.asks
      end

      it 'raises ArgumentError on a whitespace-only string' do
        err = assert_raises(ArgumentError) { agent.run_loop(user_message: "  \n\t ") }
        assert_match(/blank/, err.message)
        assert_equal [], fake_chat.asks
      end
    end
  end

  describe 'event routing through the chat callbacks' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: { 'text' => 'hi' }) }

    before do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') { |c| c.add_listener recorder }
    end

    it 'forwards assistant messages as Thinking + Assistant + Tokens' do
      msg = fake_chat.add_assistant('**hi**', thinking: 'pondered')
      fake_chat.fire(:after_message, msg)

      assistant_events = recorder.events.reject { |e| e.is_a?(Pikuri::Agent::Event::ContextCap) }
      assert_equal(
        [
          Pikuri::Agent::Event::Thinking.new(content: 'pondered'),
          Pikuri::Agent::Event::Assistant.new(content: '**hi**'),
          Pikuri::Agent::Event::Tokens.new(input: nil, output: nil, cached: nil,
                                           cache_creation: nil, thinking: nil, model_id: nil)
        ],
        assistant_events
      )
    end

    it 'skips Thinking when content is empty' do
      msg = RubyLLM::Message.new(role: :assistant, content: 'hi', thinking: RubyLLM::Thinking.new(text: ''))

      fake_chat.fire(:after_message, msg)

      assert_includes recorder.events, Pikuri::Agent::Event::Assistant.new(content: 'hi')
      refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::Thinking) }
    end

    it 'skips Assistant when content is empty (pure tool-call turn) but still emits Tokens' do
      msg = RubyLLM::Message.new(role: :assistant, content: '', thinking: RubyLLM::Thinking.new(text: 'just thinking'))

      fake_chat.fire(:after_message, msg)

      assert_includes recorder.events, Pikuri::Agent::Event::Thinking.new(content: 'just thinking')
      refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::Assistant) }
      assert recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::Tokens) }
    end

    it 'skips tool-role messages entirely' do
      tool_msg = RubyLLM::Message.new(role: :tool, content: 'observation', tool_call_id: 'call_1')
      before = recorder.events.size

      fake_chat.fire(:after_message, tool_msg)

      assert_equal before, recorder.events.size
    end

    it 'forwards tool calls as ToolCall with name and arguments' do
      fake_chat.fire(:before_tool_call, tool_call)

      assert_includes recorder.events,
                      Pikuri::Agent::Event::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' })
    end

    it 'forwards tool results as ToolResult' do
      fake_chat.fire(:after_tool_result, '42')

      assert_includes recorder.events, Pikuri::Agent::Event::ToolResult.new(content: '42')
    end

    it 'does not pass a streaming block when streaming: defaults to false' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }
      agent.run_loop(user_message: 'hi')

      assert_nil fake_chat.stream_block,
                 'expected non-streaming run_loop to complete without a block'
    end

    it 'passes a streaming block to chat.complete that emits ThinkingDelta + AssistantDelta per chunk when streaming: true' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's',
                                streaming: true) { |c| c.add_listener recorder }
      agent.run_loop(user_message: 'hi')

      refute_nil fake_chat.stream_block, 'expected run_loop to pass a streaming block to chat.complete'

      fake_chat.fire_chunk(thinking: 'pon')
      fake_chat.fire_chunk(content: 'hel')
      fake_chat.fire_chunk(thinking: 'der', content: 'lo')

      deltas = recorder.events.select do |e|
        e.is_a?(Pikuri::Agent::Event::ThinkingDelta) || e.is_a?(Pikuri::Agent::Event::AssistantDelta)
      end
      assert_equal(
        [
          Pikuri::Agent::Event::ThinkingDelta.new(content: 'pon'),
          Pikuri::Agent::Event::AssistantDelta.new(content: 'hel'),
          Pikuri::Agent::Event::ThinkingDelta.new(content: 'der'),
          Pikuri::Agent::Event::AssistantDelta.new(content: 'lo')
        ],
        deltas
      )
    end

    it 'polls the cancellable on every chunk so a flag flipped mid-stream raises Cancelled' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's',
                                cancellable: cancel, streaming: true) { |c| c.add_listener recorder }
      agent.run_loop(user_message: 'hi')

      # First chunk flows normally — flag still armed.
      fake_chat.fire_chunk(thinking: 'pondering')
      assert recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::ThinkingDelta) }

      # SIGINT trap fires on the main thread, flips the flag.
      cancel.cancel!

      # Next chunk arrives — streaming block must raise before emitting,
      # so no delta is rendered for content the user already asked to drop.
      before = recorder.events.size
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        fake_chat.fire_chunk(content: 'should not render')
      end
      assert_equal before, recorder.events.size,
                   'expected the cancelled chunk to not produce any delta event'
    end

    it 'filters empty/nil thinking and content from chunks (no vacuous deltas)' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's',
                                streaming: true) { |c| c.add_listener recorder }
      agent.run_loop(user_message: 'hi')

      fake_chat.fire_chunk
      fake_chat.fire_chunk(content: '')
      fake_chat.fire_chunk(thinking: '')
      fake_chat.fire_chunk(content: nil, thinking: nil)

      refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::ThinkingDelta) }
      refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::AssistantDelta) }
    end

    it 'populates Event::Tokens fields from the underlying RubyLLM::Message' do
      msg = RubyLLM::Message.new(
        role: :assistant, content: 'reply', model_id: 'qwen3-35b',
        input_tokens: 12_453, output_tokens: 320,
        cached_tokens: 12_000, cache_creation_tokens: 256,
        thinking_tokens: 80
      )

      fake_chat.fire(:after_message, msg)

      tokens = recorder.events.find { |e| e.is_a?(Pikuri::Agent::Event::Tokens) && e.model_id == 'qwen3-35b' }
      refute_nil tokens
      assert_equal 12_453,    tokens.input
      assert_equal 320,       tokens.output
      assert_equal 12_000,    tokens.cached
      assert_equal 256,       tokens.cache_creation
      assert_equal 80,        tokens.thinking
    end
  end

  describe 'step-limit enforcement at the Agent level' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: {}) }

    it 'raises Control::StepLimit::Exceeded once the cap is exceeded' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's',
                        step_limit: step_limit) { |c| c.add_listener recorder }

      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)

      err = assert_raises(Pikuri::Agent::Control::StepLimit::Exceeded) do
        fake_chat.fire(:before_tool_call, tool_call)
      end
      assert_equal 2, err.max_steps
    end

    it 'does not enforce a budget when step_limit: is nil (default)' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') { |c| c.add_listener recorder }

      100.times { fake_chat.fire(:before_tool_call, tool_call) } # no raise
    end
  end

  describe 'interloper drain on after_tool_result' do
    let(:interloper) { Pikuri::Agent::Control::Interloper.new }

    it 'drains the queue and appends each item as a user-role message + Event::UserTurn(mid_loop: true)' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's',
                        interloper: interloper) { |c| c.add_listener recorder }
      interloper.inject_user_message('first')
      interloper.inject_user_message('second')

      fake_chat.fire(:after_tool_result, 'observation')

      assert_equal(
        [
          { role: :user, content: 'first' },
          { role: :user, content: 'second' }
        ],
        fake_chat.added_messages
      )

      injections = recorder.events.select do |e|
        e.is_a?(Pikuri::Agent::Event::UserTurn) && e.mid_loop
      end
      assert_equal 2, injections.size
      assert_equal 'first',  injections[0].content
      assert_equal 'second', injections[1].content
    end

    it 'is a no-op when interloper: is nil (default)' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') { |c| c.add_listener recorder }

      fake_chat.fire(:after_tool_result, 'observation') # must not raise

      assert_equal [], fake_chat.added_messages
    end

    it 'drains exactly once per fire — subsequent fires with an empty queue are no-ops' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's',
                        interloper: interloper) { |c| c.add_listener recorder }
      interloper.inject_user_message('only once')

      fake_chat.fire(:after_tool_result, 'a')
      fake_chat.fire(:after_tool_result, 'b')
      fake_chat.fire(:after_tool_result, 'c')

      assert_equal [{ role: :user, content: 'only once' }], fake_chat.added_messages
    end
  end

  describe 'Extension#on_user_message dispatch' do
    # An extension that records every on_user_message call and returns a
    # configurable prefetch block. Includes Extension so configure/bind are
    # no-ops and on_user_message is the only behaviour under test.
    let(:recording_extension_class) do
      Class.new do
        include Pikuri::Agent::Extension

        attr_reader :calls

        def initialize(block:)
          @block = block
          @calls = []
        end

        def on_user_message(ctx, content)
          @calls << [ctx, content]
          @block
        end
      end
    end

    it 'fires on each initial turn and appends a non-blank return as a :system message after the user turn' do
      ext = recording_extension_class.new(block: '<memory-context>recalled</memory-context>')
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_extension ext }

      agent.run_loop(user_message: 'where do I live?')

      assert_equal 1, ext.calls.size
      # The hook receives the agent's ExtensionContext (same one bind
      # got), with the live agent readable off it.
      assert_kind_of Pikuri::Agent::ExtensionContext, ext.calls[0][0]
      assert_same agent, ext.calls[0][0].agent
      assert_equal 'where do I live?', ext.calls[0][1]
      # :user message first, then the recalled :system block at the tail.
      assert_equal(
        [
          { role: :user, content: 'where do I live?' },
          { role: :system, content: '<memory-context>recalled</memory-context>' }
        ],
        fake_chat.added_messages
      )
    end

    it 'emits an Event::SystemInjected per injected block so the listener stream mirrors the log growth' do
      first  = recording_extension_class.new(block: '<memory-context>one</memory-context>')
      second = recording_extension_class.new(block: '<memory-context>two</memory-context>')
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_extension first
        c.add_extension second
      end

      agent.run_loop(user_message: 'q')

      injected = recorder.events.grep(Pikuri::Agent::Event::SystemInjected).map(&:content)
      assert_equal(
        ['<memory-context>one</memory-context>', '<memory-context>two</memory-context>'],
        injected
      )
    end

    it 'emits no Event::SystemInjected when the hook injects nothing' do
      ext = recording_extension_class.new(block: nil)
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_extension ext
      end

      agent.run_loop(user_message: 'hi')

      assert_empty recorder.events.grep(Pikuri::Agent::Event::SystemInjected)
    end

    it 'injects nothing when the hook returns nil or a blank String' do
      [nil, '', "   \n"].each do |blank|
        local_fake = fake_chat_class.new
        RubyLLM.define_singleton_method(:chat) { |**_| local_fake }
        ext = recording_extension_class.new(block: blank)
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's') { |c| c.add_extension ext }

        agent.run_loop(user_message: 'hi')

        assert_equal 1, ext.calls.size, "hook should still fire for block=#{blank.inspect}"
        # Only the user message — no :system block appended.
        assert_equal(
          [{ role: :user, content: 'hi' }], local_fake.added_messages,
          "no injection expected for block=#{blank.inspect}"
        )
      end
    end

    it 'fires on mid-loop interlopers too, appending the :system block after the :user message' do
      interloper = Pikuri::Agent::Control::Interloper.new
      ext = recording_extension_class.new(block: '<memory-context>mid</memory-context>')
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's',
                        interloper: interloper) { |c| c.add_extension ext }
      interloper.inject_user_message('interloped question')

      fake_chat.fire(:after_tool_result, 'observation')

      assert_equal 'interloped question', ext.calls[0][1]
      assert_equal(
        [
          { role: :user, content: 'interloped question' },
          { role: :system, content: '<memory-context>mid</memory-context>' }
        ],
        fake_chat.added_messages
      )
    end

    it 'injects nothing for an extension that inherits the no-op default (opted out)' do
      # Includes Extension but does not override on_user_message, so it
      # gets the module's no-op default (returns nil) — the way an
      # extension opts out of the hook.
      opted_out_class = Class.new do
        include Pikuri::Agent::Extension

        def configure(c); end
      end
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_extension opted_out_class.new }

      agent.run_loop(user_message: 'hi') # must not raise

      # Only the user message — the opted-out extension contributes no block.
      assert_equal [{ role: :user, content: 'hi' }], fake_chat.added_messages
    end

    it 'appends one :system block per extension, in registration order, after the user turn' do
      first  = recording_extension_class.new(block: '<memory-context>one</memory-context>')
      second = recording_extension_class.new(block: '<memory-context>two</memory-context>')
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_extension first
        c.add_extension second
      end

      agent.run_loop(user_message: 'q')

      assert_equal(
        [
          { role: :user, content: 'q' },
          { role: :system, content: '<memory-context>one</memory-context>' },
          { role: :system, content: '<memory-context>two</memory-context>' }
        ],
        fake_chat.added_messages
      )
    end
  end

  describe '#last_assistant_content' do
    it 'returns the most recent assistant message content' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }
      fake_chat.add_assistant('first')
      fake_chat.add_assistant('second')

      assert_equal 'second', agent.last_assistant_content
    end

    it 'returns nil when no assistant message has been produced yet' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') { |c| c.add_listener recorder }

      assert_nil agent.last_assistant_content
    end
  end

  describe '#to_s' do
    it 'renders model, tool count, and listener list as a one-liner' do
      tool = Pikuri::Tool.new(
        name: 't', description: 'd',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :x, 'x' },
        execute: ->(x:) { x }
      )
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_tool tool
        c.add_listener recorder
      end

      assert_equal 'Agent(id=, model=m, tools=1, listeners=[InMemoryEventList])',
                   agent.to_s
    end
  end

  # Agent.think is gone — the one-shot MCP boot passes that used it now
  # construct a regular tools-free Agent inside Mcp::Extension's thinker
  # closure; see pikuri-mcp/spec/pikuri/mcp/extension_spec.rb.

  describe 'step-exhaustion policy' do
    let(:synth_chat) { fake_chat_class.new }

    # Rebind the outer RubyLLM.chat stub: the first call (the parent
    # agent's) keeps returning fake_chat; subsequent calls (the nested
    # synth agent's, on the :synthesize path) return synth_chat. The
    # kwargs of every construction are logged so tests can assert how
    # many chats were stood up.
    before do
      parent = fake_chat
      synth = synth_chat
      @chat_kwargs = []
      kwargs_log = @chat_kwargs
      RubyLLM.define_singleton_method(:chat) do |**kw|
        kwargs_log << kw
        kwargs_log.size == 1 ? parent : synth
      end
    end

    # Helper: arrange for the parent chat's +complete+ to raise once, as
    # if a StepLimit deep inside its +before_tool_call+ tripped. (run_loop
    # drives completion via +#complete+, not +#ask+.)
    def arrange_step_exhaustion(max_steps)
      err = Pikuri::Agent::Control::StepLimit::Exceeded.new(max_steps)
      fake_chat.define_singleton_method(:complete) do |&_block|
        @completes = (@completes || 0) + 1
        raise err
      end
    end

    # Helper: make the synth chat's +complete+ produce an assistant
    # message, like a provider answering the synthesis prompt.
    def arrange_synth_answer(content = 'rescued answer')
      synth_chat.define_singleton_method(:complete) do |&block|
        @stream_block = block
        @messages << RubyLLM::Message.new(role: :assistant, content: content)
      end
    end

    def build_agent(step_limit:, id: '', streaming: false, cancellable: nil, &block)
      block ||= ->(c) { c.add_listener recorder }
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', step_limit: step_limit, id: id,
                        streaming: streaming, cancellable: cancellable, &block)
    end

    describe 'with the default :raise policy' do
      it 're-raises Exceeded to the host and constructs no synth' do
        agent = build_agent(step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2))
        arrange_step_exhaustion(2)

        err = assert_raises(Pikuri::Agent::Control::StepLimit::Exceeded) do
          agent.run_loop(user_message: 'write the rest of the code')
        end

        assert_equal 2, err.max_steps
        refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::FallbackNotice) },
               'no FallbackNotice expected on the :raise path'
        assert_equal 1, @chat_kwargs.size, 'only the parent chat should have been constructed'
      end

      it 'leaves the agent usable for a fresh turn afterwards ("continue" works)' do
        agent = build_agent(step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2))
        arrange_step_exhaustion(2)

        assert_raises(Pikuri::Agent::Control::StepLimit::Exceeded) do
          agent.run_loop(user_message: 'turn 1')
        end

        fake_chat.define_singleton_method(:complete) do |&_block|
          @messages << RubyLLM::Message.new(role: :assistant, content: 'kept going')
        end
        assert_nil agent.run_loop(user_message: 'continue')
        assert_equal 'kept going', agent.last_assistant_content
      end
    end

    describe 'with the :synthesize policy' do
      let(:step_limit) { Pikuri::Agent::Control::StepLimit.new(max: 2, on_exhausted: :synthesize) }

      it 'catches Exceeded, emits a FallbackNotice, and returns nil from run_loop' do
        agent = build_agent(step_limit: step_limit)
        arrange_step_exhaustion(2)
        arrange_synth_answer

        assert_nil agent.run_loop(user_message: 'compare two cities')

        notice = recorder.events.find { |e| e.is_a?(Pikuri::Agent::Event::FallbackNotice) }
        refute_nil notice, 'expected a FallbackNotice in the listener stream'
        assert_includes notice.reason, 'exhausted 2 steps'
      end

      it 'runs the synth as a nested tools-free agent: synth system prompt, build_prompt user turn, answer captured' do
        agent = build_agent(step_limit: step_limit)
        fake_chat.add_assistant('plan: do stuff')
        arrange_step_exhaustion(2)
        arrange_synth_answer

        agent.run_loop(user_message: 'why?')

        # A second chat was constructed for the synth, on the same
        # transport as the parent.
        assert_equal 2, @chat_kwargs.size
        assert_equal @chat_kwargs.first, @chat_kwargs.last

        # The nested agent set the Synthesizer system prompt and asked
        # the evidence prompt as its single user turn.
        assert_equal Pikuri::Agent::Synthesizer::SYSTEM_PROMPT.strip, synth_chat.instructions.strip
        expected_prompt = Pikuri::Agent::Synthesizer.build_prompt(
          parent_messages: fake_chat.messages, user_message: 'why?'
        )
        assert_equal [{ role: :user, content: expected_prompt }], synth_chat.added_messages

        # No tools on the synth, and the synth's answer wins
        # last_assistant_content.
        assert_equal [], synth_chat.tools
        assert_equal 'rescued answer', agent.last_assistant_content
      end

      # The derived-listener contract: each listener that defines
      # for_sub_agent is asked for its synth variant with the derived id.
      let(:forking_listener_class) do
        Class.new(Pikuri::Agent::Listener::InMemoryEventList) do
          attr_reader :fork_params

          def for_sub_agent(**params)
            (@fork_params ||= []) << params
            self.class.new
          end
        end
      end

      it "derives the synth's listener list with id 'synthesizer' for the main agent" do
        listener = forking_listener_class.new
        agent = build_agent(step_limit: step_limit) { |c| c.add_listener listener }
        arrange_step_exhaustion(2)
        arrange_synth_answer

        agent.run_loop(user_message: 'q?')

        assert_equal [{ id: 'synthesizer' }], listener.fork_params
      end

      it "derives '<parent_id>_synthesizer' when the agent itself has an id" do
        listener = forking_listener_class.new
        agent = build_agent(step_limit: step_limit, id: 'researcher 0') { |c| c.add_listener listener }
        arrange_step_exhaustion(2)
        arrange_synth_answer

        agent.run_loop(user_message: 'q?')

        assert_equal [{ id: 'researcher 0_synthesizer' }], listener.fork_params
      end

      it 'shares the parent cancellable with the synth by reference (a cancel during synthesis still works)' do
        cancel = Pikuri::Agent::Control::Cancellable.new
        agent = build_agent(step_limit: step_limit, cancellable: cancel)
        arrange_step_exhaustion(2)
        arrange_synth_answer

        agent.run_loop(user_message: 'q?')

        # The synth chat's before_tool_call wiring polls the shared flag.
        cancel.cancel!
        assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
          synth_chat.fire(:before_tool_call, RubyLLM::ToolCall.new(id: 'x', name: 'n', arguments: {}))
        end
      end

      it 'lets a cancel that landed while the budget tripped win over salvage (no synth constructed)' do
        cancel = Pikuri::Agent::Control::Cancellable.new
        agent = build_agent(step_limit: step_limit, cancellable: cancel)
        # Ctrl+C lands mid-turn, right as the budget trips: complete
        # flips the flag and raises Exceeded.
        err = Pikuri::Agent::Control::StepLimit::Exceeded.new(2)
        fake_chat.define_singleton_method(:complete) do |&_block|
          cancel.cancel!
          raise err
        end

        assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
          agent.run_loop(user_message: 'q?')
        end

        refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::FallbackNotice) },
               'cancellation must win before the FallbackNotice'
        assert_equal 1, @chat_kwargs.size, 'no synth chat should have been constructed'
      end

      it "mirrors the parent's streaming flag onto the synth" do
        agent = build_agent(step_limit: step_limit, streaming: true)
        arrange_step_exhaustion(2)
        arrange_synth_answer

        agent.run_loop(user_message: 'q?')

        refute_nil synth_chat.stream_block,
                   'expected the synth completion to receive a streaming block'
      end

      it 'clears the prior synth answer at the start of each new turn' do
        agent = build_agent(step_limit: step_limit)
        arrange_step_exhaustion(2)
        arrange_synth_answer
        agent.run_loop(user_message: 'turn 1')
        assert_equal 'rescued answer', agent.last_assistant_content

        # Make the next turn succeed: replace complete with one that just adds an assistant message.
        fake_chat.define_singleton_method(:complete) do |&_block|
          @completes = (@completes || 0) + 1
          @messages << RubyLLM::Message.new(role: :assistant, content: 'normal answer')
        end
        agent.run_loop(user_message: 'turn 2')

        assert_equal 'normal answer', agent.last_assistant_content
      end
    end
  end

  describe 'cancellation rescue' do
    # Arrange for the parent chat's +complete+ to raise +Cancelled+ once,
    # as if a Cancellable inside its +before_tool_call+ tripped mid-loop.
    # (run_loop drives completion via +#complete+, not +#ask+.)
    def arrange_cancellation
      err = Pikuri::Agent::Control::Cancellable::Cancelled.new
      fake_chat.define_singleton_method(:complete) do |&_block|
        @completes = (@completes || 0) + 1
        raise err
      end
    end

    it 'catches Cancelled, emits Event::Cancelled to listeners, and re-raises' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt: 's',
        cancellable: cancel
      ) { |c| c.add_listener recorder }
      arrange_cancellation

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        agent.run_loop(user_message: 'do a thing')
      end

      assert recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::Cancelled) },
             'expected Event::Cancelled in the listener stream'
    end

    it 'does not invoke the synthesizer fallback, even with a :synthesize step limit' do
      chat_constructions = 0
      captured = fake_chat
      RubyLLM.define_singleton_method(:chat) do |**_|
        chat_constructions += 1
        captured
      end

      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt: 's',
        step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2, on_exhausted: :synthesize),
        cancellable: cancel
      ) { |c| c.add_listener recorder }
      arrange_cancellation

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        agent.run_loop(user_message: 'stop')
      end

      refute recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::FallbackNotice) },
             'no FallbackNotice expected on cancellation'
      assert_equal 1, chat_constructions, 'no synth chat should have been constructed'
    end

    it 'lets the same agent take a fresh turn after a cancellation' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt: 's',
        cancellable: cancel
      ) { |c| c.add_listener recorder }
      arrange_cancellation

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        agent.run_loop(user_message: 'turn 1')
      end

      # Make the next turn succeed.
      fake_chat.define_singleton_method(:complete) do |&_block|
        @completes = (@completes || 0) + 1
        @messages << RubyLLM::Message.new(role: :assistant, content: 'normal answer')
      end

      # run_loop calls cancel.reset! at the turn boundary, so a stale
      # cancel from turn 1 doesn't poison turn 2.
      assert_nil agent.run_loop(user_message: 'turn 2')
      refute cancel.cancelled?
      assert_equal 'normal answer', agent.last_assistant_content
    end
  end

  # End-to-end Skill::Extension wiring tests have moved to
  # pikuri-skills/spec/pikuri/skill/agent_integration_spec.rb (the
  # extension's own unit specs live there too, alongside the catalog).
  # Same separation pattern as the MCP extension's tests in
  # pikuri-mcp/spec/pikuri/mcp/.

  # The block-based configuration surface is the sole wiring path
  # for tools / listeners / extensions / system-prompt snippets.
  # See IDEAS.md §"Extension protocol design".
  describe 'Configurator block' do
    let(:tool) do
      Pikuri::Tool.new(
        name: 'tt', description: 'd',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :x, 'x' },
        execute: ->(x:) { x }
      )
    end

    it 'lets the block add tools via c.add_tool' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_tool(tool)
      end

      assert_equal 1, fake_chat.tools.size
      assert_equal 'tt', fake_chat.tools.first.name
    end

    it 'lets the block add multiple tools at once via c.add_tools' do
      second_tool = Pikuri::Tool.new(
        name: 'uu', description: 'd',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :y, 'y' },
        execute: ->(y:) { y }
      )

      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_tools([tool, second_tool])
      end

      assert_equal %w[tt uu], fake_chat.tools.map(&:name)
    end

    it 'lets the block add listeners via c.add_listener; ContextCap reaches them' do
      block_recorder = Pikuri::Agent::Listener::InMemoryEventList.new

      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_listener(block_recorder)
      end

      # ContextCap fires at the end of #initialize so any listener
      # added in the block must see it.
      assert(block_recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::ContextCap) })
    end

    it 'lets the block add a batch of listeners via c.add_listeners (accepting a ListenerList)' do
      first  = Pikuri::Agent::Listener::InMemoryEventList.new
      second = Pikuri::Agent::Listener::InMemoryEventList.new

      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_listeners(Pikuri::Agent::ListenerList.new([first, second]))
      end

      assert(first.events.any?  { |e| e.is_a?(Pikuri::Agent::Event::ContextCap) })
      assert(second.events.any? { |e| e.is_a?(Pikuri::Agent::Event::ContextCap) })
    end

    it 'joins append_system_prompt snippets onto the base prompt with blank-line separators' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 'base') do |c|
        c.add_listener recorder
        c.append_system_prompt('first snippet')
        c.append_system_prompt('second snippet')
      end

      assert_equal "base\n\nfirst snippet\n\nsecond snippet", fake_chat.instructions
    end

    it 'runs extension.configure during the block and extension.bind once after construction' do
      events = []
      ext_class = Class.new do
        include Pikuri::Agent::Extension
        define_method(:configure) { |c| events << [:configure, c.is_a?(Pikuri::Agent::Configurator)] }
        define_method(:bind) { |ctx| events << [:bind, ctx.is_a?(Pikuri::Agent::ExtensionContext)] }
      end

      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_extension(ext_class.new)
      end

      assert_equal [[:configure, true], [:bind, true]], events
    end

    it 'hands #bind an ExtensionContext whose #agent is the live, fully wired agent' do
      seen = nil
      ext_class = Class.new do
        include Pikuri::Agent::Extension
        define_method(:bind) { |ctx| seen = ctx }
      end

      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_extension(ext_class.new)
      end

      assert_same agent, seen.agent
    end

    it "extensions that include Extension and override only #configure inherit a no-op #bind" do
      # Documents why Pikuri::Agent::Extension is a mixin with empty
      # defaults: extensions can override just the hooks they need.
      configured = false
      ext_class = Class.new do
        include Pikuri::Agent::Extension
        define_method(:configure) { |_c| configured = true }
      end

      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_extension(ext_class.new)
      end

      assert configured
    end
  end

  describe '#close + #on_close' do
    def build_agent(&block)
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', &block)
    end

    it 'fires Configurator#on_close handlers in LIFO order' do
      order = []
      agent = build_agent do |c|
        c.on_close { order << :first_registered }
        c.on_close { order << :second_registered }
      end

      agent.close

      assert_equal %i[second_registered first_registered], order
    end

    it 'fires ExtensionContext#on_close handlers (registered at bind time) in LIFO too' do
      order = []
      ext_class = Class.new do
        include Pikuri::Agent::Extension
        define_method(:bind) do |ctx|
          ctx.on_close { order << :a }
          ctx.on_close { order << :b }
        end
      end
      agent = build_agent { |c| c.add_extension(ext_class.new) }

      agent.close

      assert_equal %i[b a], order
    end

    it 'is idempotent — subsequent closes are no-ops' do
      calls = 0
      agent = build_agent { |c| c.on_close { calls += 1 } }

      agent.close
      agent.close
      agent.close

      assert_equal 1, calls
    end

    it 'rescues a raising handler and continues firing the rest' do
      order = []
      agent = build_agent do |c|
        c.on_close { order << :outer }
        c.on_close { raise 'boom' }
      end

      # Must not propagate
      agent.close

      assert_equal [:outer], order
    end

  end
end
