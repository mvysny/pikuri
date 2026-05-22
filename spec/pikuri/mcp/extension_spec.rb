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
      name: '',
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
          @mcp_servers = nil
        end

        attr_reader :mcp_servers

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

      assert_nil agent.mcp_servers
      assert_equal [], agent.added_tools
    end

    it 'sets agent.mcp_servers (transition back-fill) but skips connect tool when servers are empty' do
      tracker = tracker_servers_class.new(empty: true)
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)
      with_stubbed_servers(tracker) { ext.configure(configurator) }

      agent = dummy_agent_class.new
      ext.bind(agent)

      assert_same tracker, agent.mcp_servers
      assert_equal [], agent.added_tools, 'no connect tool when servers are empty'
      assert_equal [], tracker.build_calls
    end

    it 'sets agent.mcp_servers AND registers a per-agent connect tool when servers are live' do
      tracker = tracker_servers_class.new(empty: false)
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)
      with_stubbed_servers(tracker) { ext.configure(configurator) }

      agent = dummy_agent_class.new
      ext.bind(agent)

      assert_same tracker, agent.mcp_servers
      assert_equal [agent], tracker.build_calls, 'connect tool was built keyed to this agent'
      assert_equal [:fake_rl_tool], agent.added_tools, 'connect tool registered via internal_add_tool'
    end
  end
end
