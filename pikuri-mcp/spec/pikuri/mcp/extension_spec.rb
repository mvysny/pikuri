# frozen_string_literal: true

RSpec.describe Pikuri::Mcp::Extension do
  # Tracker stand-in for Mcp::Servers — same shape used by the
  # agent_spec.rb #close tests. Implements only the surface the
  # extension touches.
  let(:tracker_servers_class) do
    Class.new do
      attr_reader :close_calls, :build_calls
      attr_accessor :empty_value, :snippet

      def initialize(empty: true, snippet: '')
        @empty_value = empty
        @snippet = snippet
        @close_calls = 0
        @build_calls = []
      end

      def empty?
        @empty_value
      end

      def system_prompt_snippet
        @snippet
      end

      def close
        @close_calls += 1
      end

      def build_mcp_connect_tool(agent)
        @build_calls << agent
        # The real Connect class — we don't need to fake it here,
        # the test verifies the call shape, not the returned tool.
        Struct.new(:to_ruby_llm_tool).new(:fake_rl_tool)
      end
    end
  end

  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      step_limit: nil,
      cancellable: nil,
      interloper: nil
    )
  end

  let(:non_empty_registry) do
    Pikuri::Mcp::Registry.new(entries: [
      Pikuri::Mcp::Registry::StdioEntry.new(id: 'x', command: ['no-op'])
    ])
  end

  # Stub Mcp::Servers.new to return our tracker instead of spawning
  # a real subprocess; restore on teardown.
  def with_stubbed_servers(tracker)
    original_new = Pikuri::Mcp::Servers.method(:new)
    Pikuri::Mcp::Servers.define_singleton_method(:new) { |_registry, **_kw| tracker }
    yield
  ensure
    Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_new.call(r, **kw) }
  end

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(registry: Pikuri::Mcp::Registry::EMPTY)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure' do
    it 'is a no-op when the registry is empty (no Servers built, no on_close, no snippet)' do
      ext = described_class.new(registry: Pikuri::Mcp::Registry::EMPTY)
      ext.configure(configurator)

      assert_nil ext.servers
      assert_equal [], configurator.system_prompt_additions
      assert_equal [], configurator.on_close_handlers
    end

    it 'builds Mcp::Servers, registers an on_close handler, and appends the snippet (non-empty registry, live servers)' do
      tracker = tracker_servers_class.new(empty: false, snippet: "\n\n<available_mcps>...</available_mcps>")
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)

      with_stubbed_servers(tracker) { ext.configure(configurator) }

      assert_same tracker, ext.servers
      assert_equal 1, configurator.system_prompt_additions.size
      snippet = configurator.system_prompt_additions.first
      refute snippet.start_with?("\n"), 'snippet must be lstripped — Configurator owns the separator'
      assert_equal 1, configurator.on_close_handlers.size

      # on_close handler calls servers.close
      configurator.on_close_handlers.first.call
      assert_equal 1, tracker.close_calls
    end

    it 'still registers on_close when the registry produces an empty Servers (no live ids)' do
      # Servers with no live ids must still close cleanly — the
      # gem may have started the runtime even if every server
      # failed to register (e.g. all rejected by Verifier).
      tracker = tracker_servers_class.new(empty: true, snippet: '')
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)

      with_stubbed_servers(tracker) { ext.configure(configurator) }

      assert_same tracker, ext.servers
      assert_equal [], configurator.system_prompt_additions # empty → no snippet
      assert_equal 1, configurator.on_close_handlers.size
    end
  end

  describe '#bind' do
    let(:dummy_agent_class) do
      Class.new do
        attr_reader :added_tools

        def initialize
          @added_tools = []
        end

        def tools
          [] # never has Mcp::Servers::Connect for these specs
        end

        def internal_add_tool(rl_tool)
          @added_tools << rl_tool
        end
      end
    end

    it 'is a no-op when the registry was empty at configure time' do
      agent = dummy_agent_class.new
      ext = described_class.new(registry: Pikuri::Mcp::Registry::EMPTY)
      ext.configure(configurator)

      ext.bind(agent)

      assert_equal [], agent.added_tools
    end

    it 'skips connect tool when servers are empty (no live ids)' do
      tracker = tracker_servers_class.new(empty: true)
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)
      with_stubbed_servers(tracker) { ext.configure(configurator) }

      agent = dummy_agent_class.new
      ext.bind(agent)

      assert_equal [], agent.added_tools, 'no connect tool when servers are empty'
      assert_equal [], tracker.build_calls
    end

    it 'registers a per-agent connect tool when servers are live' do
      tracker = tracker_servers_class.new(empty: false)
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)
      with_stubbed_servers(tracker) { ext.configure(configurator) }

      agent = dummy_agent_class.new
      ext.bind(agent)

      assert_equal [agent], tracker.build_calls, 'connect tool was built keyed to this agent'
      assert_equal [:fake_rl_tool], agent.added_tools, 'connect tool registered via internal_add_tool'
    end
  end

  # Coverage moved here from agent_spec.rb's "synthesize_descriptions:
  # kwarg plumbing" describe — these kwargs are now properties of
  # Mcp::Extension, not Agent. Verifies the synthesizer / verifier are
  # wired (or skipped) based on the extension's own flags, and that
  # the thinker closure invokes Agent.think with the Configurator's
  # transport + cancellable.
  describe 'synthesizer/verifier wiring' do
    let(:capturing_servers_class) do
      Class.new do
        @last_synthesizer = nil
        @last_verifier = nil
        class << self; attr_accessor :last_synthesizer, :last_verifier; end

        def initialize(_registry, synthesizer: nil, verifier: nil)
          self.class.last_synthesizer = synthesizer
          self.class.last_verifier = verifier
        end

        def empty?; true; end
        def system_prompt_snippet; ''; end
        def close; end
      end
    end

    it 'passes synthesizer: nil + verifier: nil to Mcp::Servers when both flags are false' do
      stub = capturing_servers_class
      original_new = Pikuri::Mcp::Servers.method(:new)
      Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| stub.new(r, **kw) }
      begin
        ext = described_class.new(registry: non_empty_registry,
                                  synthesize_descriptions: false,
                                  verify_mcp_servers: false)
        ext.configure(configurator)

        assert_nil stub.last_synthesizer
        assert_nil stub.last_verifier
      ensure
        Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_new.call(r, **kw) }
      end
    end

    it 'builds a Mcp::Synthesizer whose thinker calls Agent.think with the configurator transport + cancellable' do
      stub = capturing_servers_class
      original_new = Pikuri::Mcp::Servers.method(:new)
      Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| stub.new(r, **kw) }
      # Sidestep the real on-disk cache so this spec doesn't see
      # stored entries (would skip the thinker invocation).
      original_cache_new = Pikuri::Mcp::Cache.method(:new)
      Pikuri::Mcp::Cache.define_singleton_method(:new) { |**_| Pikuri::Mcp::Cache::NULL }

      cancellable = Pikuri::Agent::Control::Cancellable.new
      captured_call = nil
      original_think = Pikuri::Agent.method(:think)
      Pikuri::Agent.define_singleton_method(:think) do |**kw|
        captured_call = kw
        'synth result'
      end
      begin
        c = Pikuri::Agent::Configurator.new(
          transport: Pikuri::Agent::ChatTransport.new(model: 'qwen-x'),
          system_prompt_base: 'base',
          id: '',
          streaming: false,
          step_limit: nil,
          cancellable: cancellable,
          interloper: nil
        )
        ext = described_class.new(registry: non_empty_registry,
                                  synthesize_descriptions: true,
                                  verify_mcp_servers: false)
        ext.configure(c)

        synthesizer = stub.last_synthesizer
        refute_nil synthesizer
        assert_kind_of Pikuri::Mcp::Synthesizer, synthesizer

        # Drive the synthesizer with minimal stand-ins so the
        # captured thinker fires Agent.think (stubbed above).
        entry = Pikuri::Mcp::Registry::StdioEntry.new(id: 'probe', command: ['noop'])
        tool = Struct.new(:name, :description, :input_schema).new('t', 'd', {})
        client = Struct.new(:server_info).new({ 'serverInfo' => {} })
        result = synthesizer.call(entry: entry, client: client, tools: [tool])

        assert_equal 'synth result', result
        assert_match(/Server id: probe/, captured_call[:prompt])
        assert_equal 'qwen-x', captured_call[:transport].model
        assert_same cancellable, captured_call[:cancellable]
      ensure
        Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_new.call(r, **kw) }
        Pikuri::Mcp::Cache.define_singleton_method(:new) { |**kw| original_cache_new.call(**kw) }
        Pikuri::Agent.define_singleton_method(:think) { |**kw| original_think.call(**kw) }
      end
    end
  end
end
