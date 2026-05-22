# frozen_string_literal: true

require 'pikuri-core'

# End-to-end specs that pin how +Pikuri::Mcp::Extension+ wires into
# a real +Pikuri::Agent+ via the +Agent.new+ block. The extension's
# own behaviour is tested directly in +spec/pikuri/mcp/
# extension_spec.rb+; these tests verify the integration — Agent
# lifecycle (close) tears down the shared Mcp::Servers, sub-agents
# don't close shared servers, etc.
#
# Self-contained: this spec ships its own minimal fake +RubyLLM::Chat+
# stand-in + a tracker_mcp_servers stub. Integration tests exercise
# only the surface +Agent#initialize+ + +Agent#close+ touch.
RSpec.describe 'Pikuri::Mcp::Extension agent integration' do
  let(:fake_model) { Struct.new(:context_window).new(nil) }

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools

      define_method(:initialize) do
        @tools = []
        @model_info = captured_model
      end

      def model; @model_info; end
      def with_instructions(_text); self; end
      def with_tool(tool); @tools << tool; self; end
      def after_message(&_block); self; end
      def before_tool_call(&_block); self; end
      def after_tool_result(&_block); self; end
      def add_message(_attrs); end
      def ask(_message, &_block); nil; end
    end
  end

  let(:fake_chat) { fake_chat_class.new }
  let(:recorder)  { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:listeners) { Pikuri::Agent::ListenerList.new([recorder]) }

  before do
    captured = fake_chat
    @original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**_| captured }
  end

  after do
    original = @original_chat
    RubyLLM.define_singleton_method(:chat) { |**kwargs| original.call(**kwargs) }
  end

  # Minimal Mcp::Servers stand-in for lifecycle tests. Real Mcp::
  # Servers would spawn subprocesses on construction; this stub
  # implements only the surface Mcp::Extension#configure + the
  # on_close handler touch.
  let(:tracker_mcp_servers_class) do
    Class.new do
      attr_reader :close_calls

      def initialize
        @close_calls = 0
      end

      def empty?
        true # skip auto-McpConnect-tool registration in Mcp::Extension#bind
      end

      def system_prompt_snippet
        ''
      end

      def close
        @close_calls += 1
      end
    end
  end

  # Helper: wire MCP via the new block API + return a [agent,
  # tracker] pair so close-related assertions can verify
  # close_calls on the shared tracker.
  def with_mcp_agent(listeners:)
    tracker = tracker_mcp_servers_class.new
    original_new = Pikuri::Mcp::Servers.method(:new)
    Pikuri::Mcp::Servers.define_singleton_method(:new) { |_registry, **_| tracker }
    registry = Pikuri::Mcp::Registry.new(entries: [
      Pikuri::Mcp::Registry::StdioEntry.new(id: 'x', command: ['no-op'])
    ])
    agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                              system_prompt: 's') do |c|
      c.add_listeners(listeners)
      c.add_extension(Pikuri::Mcp::Extension.new(registry: registry))
    end
    yield agent, tracker
  ensure
    Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_new.call(r, **kw) }
  end

  describe 'Agent#close + Mcp::Extension on_close handler' do
    it 'closes the Mcp::Servers wired in via Mcp::Extension on close' do
      with_mcp_agent(listeners: listeners) do |agent, tracker|
        assert_equal 0, tracker.close_calls
        agent.close
        assert_equal 1, tracker.close_calls
      end
    end

    it 'does NOT close shared Mcp::Servers when sub-agent inherits via the extension list' do
      # Sub-agents receive parent's extensions list via the
      # Configurator's +inherit_extensions+ helper. The Mcp::Extension's
      # on_close handler was registered on the parent's Configurator
      # (configure runs once on the parent), so the sub-agent's close
      # fires no MCP cleanup — only parent.close tears the shared
      # runtime down.
      with_mcp_agent(listeners: listeners) do |parent, tracker|
        # Simulate a sub-agent constructed via Tool::SubAgent.execute —
        # gets parent's extensions, no extension of its own.
        sub = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
          c.add_listeners(listeners)
          c.inherit_extensions(parent.extensions)
        end

        sub.close
        assert_equal 0, tracker.close_calls, 'sub-agent close must not close shared servers'
        parent.close
        assert_equal 1, tracker.close_calls, 'parent close fires the configure-time on_close handler'
      end
    end

    it 'is idempotent — repeat calls do not re-invoke Mcp::Servers#close' do
      with_mcp_agent(listeners: listeners) do |agent, tracker|
        agent.close
        agent.close
        agent.close
        assert_equal 1, tracker.close_calls
      end
    end
  end
end
