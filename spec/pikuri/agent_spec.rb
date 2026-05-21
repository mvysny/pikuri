# frozen_string_literal: true

RSpec.describe Pikuri::Agent do
  # Minimal stand-in for +RubyLLM::Chat+ that captures every callback
  # pikuri registers, lets the spec fire them with synthetic
  # +RubyLLM::Message+ / +RubyLLM::ToolCall+ payloads, and records
  # what +Pikuri::Agent+ configures (system prompt, tools, +ask+
  # calls, +add_message+ calls). Pins the agent-level wiring
  # without going anywhere near a real provider.
  #
  # +RubyLLM::Model::Info+ stand-in just so
  # +Pikuri::Agent#initialize+ can read
  # +@chat.model.context_window+ for {Pikuri::Agent::ContextWindowDetector}.
  fake_model = Struct.new(:context_window).new(nil)

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
                        system_prompt: 'be terse', tools: [tool], listeners: listeners)

      assert_equal 'be terse', fake_chat.instructions
      assert_equal 1, fake_chat.tools.size
      wired = fake_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 't', wired.name
    end

    it 'wires exactly one callback per chat-event channel — the Agent is the sole emitter' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', tools: [], listeners: listeners,
                        step_limit: step_limit,
                        cancellable: Pikuri::Agent::Control::Cancellable.new,
                        interloper: Pikuri::Agent::Control::Interloper.new)

      assert_equal 1, fake_chat.hooks[:after_message].size
      assert_equal 1, fake_chat.hooks[:before_tool_call].size
      assert_equal 1, fake_chat.hooks[:after_tool_result].size
    end

    it 'requires listeners: — no silent default' do
      assert_raises(ArgumentError) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's', tools: [])
      end
    end

    it 'requires tools: — no silent default' do
      assert_raises(ArgumentError) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's', listeners: listeners)
      end
    end

    it 'defaults name to empty (main agent)' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)

      assert_equal '', agent.name
    end
  end

  # Minimal McpServers stand-in for ownership-semantics tests. Real
  # McpServers instances would spawn subprocesses on construction,
  # which we don't want for unit-level lifecycle tests. This stub
  # implements only the surface +Agent#initialize+ touches.
  let(:tracker_mcp_servers_class) do
    Class.new do
      attr_reader :close_calls
      def initialize
        @close_calls = 0
      end

      def empty?
        true # skip auto-McpConnect-tool registration in Agent#initialize
      end

      def system_prompt_snippet
        ''
      end

      def close
        @close_calls += 1
      end
    end
  end

  describe '#close' do
    it 'closes the McpServers it constructed from mcp_registry:' do
      tracker = tracker_mcp_servers_class.new
      original_new = Pikuri::McpServers.method(:new)
      Pikuri::McpServers.define_singleton_method(:new) { |_registry| tracker }
      begin
        registry = Pikuri::McpRegistry.new(entries: [
          Pikuri::McpRegistry::Entry.new(id: 'x', command: ['no-op'])
        ])
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's', tools: [], listeners: listeners,
                                  mcp_registry: registry)

        assert_same tracker, agent.mcp_servers
        assert_equal 0, tracker.close_calls
        agent.close
        assert_equal 1, tracker.close_calls
      ensure
        Pikuri::McpServers.define_singleton_method(:new) { |r| original_new.call(r) }
      end
    end

    it 'does NOT close a McpServers passed via mcp_servers: (sub-agent path)' do
      tracker = tracker_mcp_servers_class.new
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                mcp_servers: tracker)

      assert_same tracker, agent.mcp_servers
      agent.close
      assert_equal 0, tracker.close_calls
    end

    it 'is idempotent — repeat calls do not re-invoke McpServers#close' do
      tracker = tracker_mcp_servers_class.new
      original_new = Pikuri::McpServers.method(:new)
      Pikuri::McpServers.define_singleton_method(:new) { |_registry| tracker }
      begin
        registry = Pikuri::McpRegistry.new(entries: [
          Pikuri::McpRegistry::Entry.new(id: 'x', command: ['no-op'])
        ])
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's', tools: [], listeners: listeners,
                                  mcp_registry: registry)
        agent.close
        agent.close
        agent.close
        assert_equal 1, tracker.close_calls
      ensure
        Pikuri::McpServers.define_singleton_method(:new) { |r| original_new.call(r) }
      end
    end

    it 'is a no-op when no MCP runtime is wired' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)
      assert_nil agent.mcp_servers
      # Must not raise.
      agent.close
      agent.close
    end
  end

  describe '.open' do
    it 'yields the agent to the block and returns the block result' do
      result = Pikuri::Agent.open(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's', tools: [], listeners: listeners) do |agent|
        assert_kind_of Pikuri::Agent, agent
        :block_return_value
      end
      assert_equal :block_return_value, result
    end

    it 'calls #close after the block returns' do
      tracker = tracker_mcp_servers_class.new
      original_new = Pikuri::McpServers.method(:new)
      Pikuri::McpServers.define_singleton_method(:new) { |_registry| tracker }
      begin
        registry = Pikuri::McpRegistry.new(entries: [
          Pikuri::McpRegistry::Entry.new(id: 'x', command: ['no-op'])
        ])
        Pikuri::Agent.open(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                           system_prompt: 's', tools: [], listeners: listeners,
                           mcp_registry: registry) do |_agent|
          assert_equal 0, tracker.close_calls
        end
        assert_equal 1, tracker.close_calls
      ensure
        Pikuri::McpServers.define_singleton_method(:new) { |r| original_new.call(r) }
      end
    end

    it 'calls #close even when the block raises (resource cleanup on exception)' do
      tracker = tracker_mcp_servers_class.new
      original_new = Pikuri::McpServers.method(:new)
      Pikuri::McpServers.define_singleton_method(:new) { |_registry| tracker }
      begin
        registry = Pikuri::McpRegistry.new(entries: [
          Pikuri::McpRegistry::Entry.new(id: 'x', command: ['no-op'])
        ])
        err = assert_raises(RuntimeError) do
          Pikuri::Agent.open(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                             system_prompt: 's', tools: [], listeners: listeners,
                             mcp_registry: registry) do |_agent|
            raise 'boom from inside the block'
          end
        end
        assert_equal 'boom from inside the block', err.message
        assert_equal 1, tracker.close_calls
      ensure
        Pikuri::McpServers.define_singleton_method(:new) { |r| original_new.call(r) }
      end
    end

    it 'exposes an explicitly passed name' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners, name: '0_1')

      assert_equal '0_1', agent.name
    end

    it 'emits a one-shot Event::ContextCap at construction so TokenLog can pick the cap up' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', tools: [], listeners: listeners,
                        context_window: 32_768)

      cap_events = recorder.events.select { |e| e.is_a?(Pikuri::Agent::Event::ContextCap) }
      assert_equal 1, cap_events.size
      assert_equal 32_768, cap_events.first.cap
    end

    describe 'context-window detection' do
      let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }
      let(:list_with_tokens) { Pikuri::Agent::ListenerList.new([recorder, token_log]) }

      it 'pushes the detected cap onto every TokenLog via the ContextCap event' do
        # No ruby_llm reported value (fake .model.context_window is nil),
        # no probe URL — explicit override wins.
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's', tools: [],
                          listeners: list_with_tokens, context_window: 32_768)

        assert_equal 32_768, token_log.context_window_cap
      end

      it 'falls back to ruby_llm reported value when no override is given' do
        # Rebind the fake_chat's model to one that reports a window.
        fake_chat.instance_variable_set(:@model_info, Struct.new(:context_window).new(200_000))

        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's', tools: [], listeners: list_with_tokens)

        assert_equal 200_000, token_log.context_window_cap
      end

      it 'exposes the resolved cap via #context_window_cap' do
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's', tools: [],
                                  listeners: list_with_tokens, context_window: 8_192)

        assert_equal 8_192, agent.context_window_cap
      end

      it 'leaves cap nil when nothing produces a value (no override, no registry, no probe URL)' do
        agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                  system_prompt: 's', tools: [], listeners: list_with_tokens)

        assert_nil agent.context_window_cap
        assert_nil token_log.context_window_cap
      end
    end
  end

  describe '#allow_sub_agent' do
    it "forwards the parent's resolved context_window_cap as the sub-agent tool's override" do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                context_window: 12_345)
      agent.allow_sub_agent(max_steps: 3)

      # Stub Pikuri::Agent.new globally just for this test: record the
      # +context_window+ kwarg the sub-agent factory passes.
      original_new = Pikuri::Agent.method(:new)
      received_kwargs = nil
      Pikuri::Agent.define_singleton_method(:new) do |**kwargs|
        received_kwargs = kwargs
        original_new.call(**kwargs).tap do |a|
          a.define_singleton_method(:run_loop) { |**_| nil }
          a.define_singleton_method(:last_assistant_content) { 'sub reply' }
        end
      end

      begin
        sub_tool = agent.instance_variable_get(:@tools).last
        sub_tool.run('task' => 'do the thing')
        assert_equal 12_345, received_kwargs[:context_window]
      ensure
        Pikuri::Agent.define_singleton_method(:new) { |**kw| original_new.call(**kw) }
      end
    end

    it 'raises when called twice on the same agent' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)
      agent.allow_sub_agent

      err = assert_raises(RuntimeError) { agent.allow_sub_agent }
      assert_match(/already registered/, err.message)

      # @tools still has exactly one SubAgent — the failed second call
      # didn't half-register anything.
      tools = agent.instance_variable_get(:@tools)
      assert_equal 1, tools.count { |t| t.is_a?(Pikuri::Tool::SubAgent) }
    end
  end

  describe '#run_loop' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: {}) }

    it 'forwards user_message to chat.ask' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)
      agent.run_loop(user_message: 'hello?')

      assert_equal ['hello?'], fake_chat.asks
    end

    it 'emits an Event::UserTurn(mid_loop: false) to every listener before asking the chat' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)
      agent.run_loop(user_message: 'hello?')

      turn = recorder.events.find do |e|
        e.is_a?(Pikuri::Agent::Event::UserTurn) && e.content == 'hello?'
      end
      refute_nil turn
      refute turn.mid_loop
    end

    it 'resets the step_limit between turns so a fresh turn can spend the budget again' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                step_limit: step_limit)

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
                                system_prompt: 's', tools: [], listeners: listeners,
                                cancellable: cancel)

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
                          system_prompt: 's', tools: [], listeners: listeners)
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

  describe 'event routing through wire_chat' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: { 'text' => 'hi' }) }

    before do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', tools: [], listeners: listeners)
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
                                system_prompt: 's', tools: [], listeners: listeners)
      agent.run_loop(user_message: 'hi')

      assert_nil fake_chat.stream_block,
                 'expected non-streaming run_loop to call chat.ask without a block'
    end

    it 'passes a streaming block to chat.ask that emits ThinkingDelta + AssistantDelta per chunk when streaming: true' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                streaming: true)
      agent.run_loop(user_message: 'hi')

      refute_nil fake_chat.stream_block, 'expected run_loop to pass a streaming block to chat.ask'

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
                                system_prompt: 's', tools: [], listeners: listeners,
                                cancellable: cancel, streaming: true)
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
                                system_prompt: 's', tools: [], listeners: listeners,
                                streaming: true)
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
                        system_prompt: 's', tools: [], listeners: listeners,
                        step_limit: step_limit)

      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)

      err = assert_raises(Pikuri::Agent::Control::StepLimit::Exceeded) do
        fake_chat.fire(:before_tool_call, tool_call)
      end
      assert_equal 2, err.max_steps
    end

    it 'does not enforce a budget when step_limit: is nil (default)' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', tools: [], listeners: listeners)

      100.times { fake_chat.fire(:before_tool_call, tool_call) } # no raise
    end
  end

  describe 'interloper drain on after_tool_result' do
    let(:interloper) { Pikuri::Agent::Control::Interloper.new }

    it 'drains the queue and appends each item as a user-role message + Event::UserTurn(mid_loop: true)' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', tools: [], listeners: listeners,
                        interloper: interloper)
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
                        system_prompt: 's', tools: [], listeners: listeners)

      fake_chat.fire(:after_tool_result, 'observation') # must not raise

      assert_equal [], fake_chat.added_messages
    end

    it 'drains exactly once per fire — subsequent fires with an empty queue are no-ops' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's', tools: [], listeners: listeners,
                        interloper: interloper)
      interloper.inject_user_message('only once')

      fake_chat.fire(:after_tool_result, 'a')
      fake_chat.fire(:after_tool_result, 'b')
      fake_chat.fire(:after_tool_result, 'c')

      assert_equal [{ role: :user, content: 'only once' }], fake_chat.added_messages
    end
  end

  describe '#last_assistant_content' do
    it 'returns the most recent assistant message content' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)
      fake_chat.add_assistant('first')
      fake_chat.add_assistant('second')

      assert_equal 'second', agent.last_assistant_content
    end

    it 'returns nil when no assistant message has been produced yet' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners)

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
                                system_prompt: 's', tools: [tool], listeners: listeners)

      assert_equal 'Agent(model=m, tools=1, listeners=[InMemoryEventList])',
                   agent.to_s
    end
  end

  describe 'step-exhaustion rescue' do
    # Stub +Pikuri::Agent::Synthesizer.run+ so the rescue branch can be
    # tested without standing up a second fake chat. Captured kwargs let
    # the spec assert on exactly what +Pikuri::Agent+ handed to the synth.
    before do
      @synth_calls = []
      captured = @synth_calls
      @original_run = Pikuri::Agent::Synthesizer.method(:run)
      Pikuri::Agent::Synthesizer.define_singleton_method(:run) do |**kwargs|
        captured << kwargs
        'rescued answer'
      end
    end

    after do
      original = @original_run
      Pikuri::Agent::Synthesizer.define_singleton_method(:run) { |**kw| original.call(**kw) }
    end

    # Helper: arrange for the parent chat's +ask+ to raise once, as if
    # a StepLimit deep inside its +before_tool_call+ tripped.
    def arrange_step_exhaustion(max_steps)
      err = Pikuri::Agent::Control::StepLimit::Exceeded.new(max_steps)
      fake_chat.define_singleton_method(:ask) do |msg|
        @asks << msg
        raise err
      end
    end

    it 'catches Exceeded, emits a FallbackNotice, and returns nil from run_loop' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2))
      arrange_step_exhaustion(2)

      assert_nil agent.run_loop(user_message: 'compare two cities')

      notice = recorder.events.find { |e| e.is_a?(Pikuri::Agent::Event::FallbackNotice) }
      refute_nil notice, 'expected a FallbackNotice in the listener stream'
      assert_includes notice.reason, 'exhausted 2 steps'
    end

    it 'invokes Synthesizer.run with the parent chat history, a sub-agent-derived listener list, a defensive step_limit, and the original cancellable' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      parent_listeners = Pikuri::Agent::ListenerList.new([recorder])
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: parent_listeners,
                                step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2),
                                cancellable: cancel)
      fake_chat.add_assistant('plan: do stuff')
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'why?')

      assert_equal 1, @synth_calls.size
      call = @synth_calls.first
      refute_nil call[:chat], 'expected a fresh synth chat to be passed'
      assert_equal fake_chat.messages, call[:parent_messages]
      assert_equal 'why?', call[:user_message]

      # The handed-off list is a derived one, not the parent's instance —
      # ListenerList#for_sub_agent returns a new object so the synth
      # chat doesn't share the parent's mutation surface.
      refute_same parent_listeners, call[:listeners]
      assert_kind_of Pikuri::Agent::ListenerList, call[:listeners]

      # Defensive step_limit on the synth (max=1, since synth has no tools).
      assert_kind_of Pikuri::Agent::Control::StepLimit, call[:step_limit]
      assert_equal 1, call[:step_limit].max

      # Cancellable shared by reference so a user cancel during
      # synthesis still works.
      assert_same cancel, call[:cancellable]
    end

    it "tags the synth's listener name as '<parent>_synthesizer' (or 'synthesizer' for the main agent)" do
      parent_log = Pikuri::Agent::Listener::TokenLog.new
      parent_listeners = Pikuri::Agent::ListenerList.new([parent_log])
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: parent_listeners,
                                step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2))
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'q?')

      synth_listeners = @synth_calls.first[:listeners].instance_variable_get(:@listeners)
      synth_log = synth_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }
      refute_nil synth_log
      assert_equal 'synthesizer', synth_log.name

      # And the parent's TokenLog is untouched.
      assert_equal '', parent_log.name
    end

    it "uses '<parent_name>_synthesizer' when the agent itself has a name" do
      parent_log = Pikuri::Agent::Listener::TokenLog.new
      parent_listeners = Pikuri::Agent::ListenerList.new([parent_log])
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: parent_listeners,
                                step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2),
                                name: 'sub_agent 0_1')
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'q?')

      synth_listeners = @synth_calls.first[:listeners].instance_variable_get(:@listeners)
      synth_log = synth_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }
      assert_equal 'sub_agent 0_1_synthesizer', synth_log.name
    end

    it "prefers the synth's answer for last_assistant_content after a rescue" do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2))
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'q?')

      assert_equal 'rescued answer', agent.last_assistant_content
    end

    it 'clears the prior synth answer at the start of each new turn' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's', tools: [], listeners: listeners,
                                step_limit: Pikuri::Agent::Control::StepLimit.new(max: 2))
      arrange_step_exhaustion(2)
      agent.run_loop(user_message: 'turn 1')
      assert_equal 'rescued answer', agent.last_assistant_content

      # Make the next turn succeed: replace ask with one that just adds an assistant message.
      fake_chat.define_singleton_method(:ask) do |msg|
        @asks << msg
        @messages << RubyLLM::Message.new(role: :assistant, content: 'normal answer')
      end
      agent.run_loop(user_message: 'turn 2')

      assert_equal 'normal answer', agent.last_assistant_content
    end
  end

  describe 'cancellation rescue' do
    # Arrange for the parent chat's +ask+ to raise +Cancelled+ once, as
    # if a Cancellable inside its +before_tool_call+ tripped mid-loop.
    def arrange_cancellation
      err = Pikuri::Agent::Control::Cancellable::Cancelled.new
      fake_chat.define_singleton_method(:ask) do |msg|
        @asks << msg
        raise err
      end
    end

    it 'catches Cancelled, emits Event::Cancelled to listeners, and re-raises' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt: 's', tools: [], listeners: listeners,
        cancellable: cancel
      )
      arrange_cancellation

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        agent.run_loop(user_message: 'do a thing')
      end

      assert recorder.events.any? { |e| e.is_a?(Pikuri::Agent::Event::Cancelled) },
             'expected Event::Cancelled in the listener stream'
    end

    it 'does not invoke the synthesizer fallback' do
      synth_calls = []
      original_run = Pikuri::Agent::Synthesizer.method(:run)
      Pikuri::Agent::Synthesizer.define_singleton_method(:run) do |**kwargs|
        synth_calls << kwargs
        'should not happen'
      end

      begin
        cancel = Pikuri::Agent::Control::Cancellable.new
        agent = Pikuri::Agent.new(
          transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
          system_prompt: 's', tools: [], listeners: listeners,
          cancellable: cancel
        )
        arrange_cancellation

        assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
          agent.run_loop(user_message: 'stop')
        end

        assert_empty synth_calls
      ensure
        Pikuri::Agent::Synthesizer.define_singleton_method(:run) { |**kw| original_run.call(**kw) }
      end
    end

    it 'lets the same agent take a fresh turn after a cancellation' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      agent = Pikuri::Agent.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt: 's', tools: [], listeners: listeners,
        cancellable: cancel
      )
      arrange_cancellation

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        agent.run_loop(user_message: 'turn 1')
      end

      # Make the next turn succeed.
      fake_chat.define_singleton_method(:ask) do |msg|
        @asks << msg
        @messages << RubyLLM::Message.new(role: :assistant, content: 'normal answer')
      end

      # run_loop calls cancel.reset! at the turn boundary, so a stale
      # cancel from turn 1 doesn't poison turn 2.
      assert_nil agent.run_loop(user_message: 'turn 2')
      refute cancel.cancelled?
      assert_equal 'normal answer', agent.last_assistant_content
    end
  end

  describe 'skill_catalog wiring' do
    # Minimal stand-in for a non-empty catalog: lets the specs assert
    # Pikuri::Agent's auto-wiring without spinning up the on-disk Bundled scanner.
    fake_catalog_class = Class.new(Pikuri::Tool::SkillCatalog) do
      def initialize(skills)
        super()
        @skills = skills
      end

      def list
        @skills
      end

      def get(name)
        @skills.find { |s| s.name == name }
      end
    end

    let(:sample_skill) do
      Pikuri::Tool::SkillCatalog::Skill.new(
        name: 'sample',
        description: 'Sample skill description.',
        location: '/tmp/sample/SKILL.md',
        body: 'do the thing.'
      )
    end

    let(:non_empty_catalog) { fake_catalog_class.new([sample_skill]) }

    it 'defaults to EMPTY: no system-prompt augmentation and no skill tool registered' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 'base', tools: [], listeners: listeners)

      assert_equal 'base', agent.system_prompt
      assert_equal Pikuri::Tool::SkillCatalog::EMPTY, agent.skill_catalog
      assert agent.tools.none?(Pikuri::Tool::Skill), 'EMPTY catalog must NOT register Pikuri::Tool::Skill'
      assert fake_chat.tools.none? { |t| t.name == 'skill' },
             'EMPTY catalog must NOT register a `skill` tool on the chat'
    end

    it 'appends the catalog block to the system prompt when non-empty' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 'base', tools: [], listeners: listeners,
                                skill_catalog: non_empty_catalog)

      assert agent.system_prompt.start_with?('base'), agent.system_prompt
      assert agent.system_prompt.include?('<available_skills>'), agent.system_prompt
      assert agent.system_prompt.include?('<name>sample</name>'), agent.system_prompt
      # The augmented prompt must be the one actually pushed to the chat,
      # not just the value cached on Pikuri::Agent.
      assert_equal agent.system_prompt, fake_chat.instructions
    end

    it 'auto-registers a Pikuri::Tool::Skill bound to the catalog when non-empty' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 'base', tools: [], listeners: listeners,
                                skill_catalog: non_empty_catalog)

      skill_tool = agent.tools.find { |t| t.is_a?(Pikuri::Tool::Skill) }
      refute_nil skill_tool, 'expected non-empty catalog to auto-register a Pikuri::Tool::Skill'
      # And it must reach the chat — not just sit on the tools array.
      wired = fake_chat.tools.find { |t| t.name == 'skill' }
      refute_nil wired, 'expected the `skill` tool to be wired on the underlying chat'

      # Verify the bound catalog is the one we passed (the tool resolves
      # the sample skill we put in it).
      result = skill_tool.run('name' => 'sample')
      assert result.include?('do the thing'), result
    end

    it 'raises if a Pikuri::Tool::Skill is also passed in tools: alongside a non-empty catalog' do
      manual_skill_tool = Pikuri::Tool::Skill.new(catalog: non_empty_catalog)

      err = assert_raises(RuntimeError) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 'base', tools: [manual_skill_tool], listeners: listeners,
                          skill_catalog: non_empty_catalog)
      end
      assert_match(/auto-registers/, err.message)
    end
  end
end
