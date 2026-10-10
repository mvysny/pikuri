# frozen_string_literal: true

RSpec.describe Pikuri::SubAgent::Extension do
  # Minimal fake chat + RubyLLM.chat stub — same shape as agent_spec.rb
  # in pikuri-core, scoped down to what the integration tests below
  # need.
  fake_model = Struct.new(:context_window, :id).new(nil, 'm')

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions

      define_method(:initialize) do
        @tools = []
        @asks = []
        @messages = []
        @model_info = captured_model
      end

      def model;                       @model_info; end
      def with_instructions(text);     @instructions = text; self; end
      def with_provider_options(_);             self; end
      def with_tools(tool);             @tools << tool; self; end
      def after_message(&);            self; end
      def before_tool_call(&);         self; end
      def after_tool_result(&);        self; end
      def ask(message);                @asks << message; nil; end
    end
  end

  let(:tiny_persona) do
    Pikuri::SubAgent::Persona.new(
      name: 'researcher',
      description: 'd',
      tool_names: %w[web_search],
      system_prompt: 's'
    )
  end

  let(:file_miner_persona) do
    Pikuri::SubAgent::Persona.new(
      name: 'file_miner',
      description: 'fs recon',
      tool_names: %w[web_search],
      system_prompt: 's'
    )
  end

  let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }

  # A concrete tool named `web_search` for the personas above to reference
  # by name. Built once so identity comparisons (sub_agent_tools) hold.
  let(:web_search_tool) { Pikuri::Tool::WebSearch.build }

  # +Context#chat+, not +RubyLLM.chat+: every chat an Agent builds rides a
  # per-transport +RubyLLM::Context+.
  before do
    @fake_chats = []
    fake_class = fake_chat_class
    captured = @fake_chats
    @original_context_chat = RubyLLM::Context.instance_method(:chat)
    RubyLLM::Context.define_method(:chat) do |**_|
      chat = fake_class.new
      captured << chat
      chat
    end
  end

  after do
    RubyLLM::Context.define_method(:chat, @original_context_chat)
  end

  describe '#initialize' do
    it 'rejects an empty personas list' do
      err = assert_raises(ArgumentError) { described_class.new(personas: []) }
      assert_match(/at least one/, err.message)
    end

    it 'rejects entries that are not Personas' do
      err = assert_raises(ArgumentError) do
        described_class.new(personas: [tiny_persona, :not_a_persona])
      end
      assert_match(/expected Pikuri::SubAgent::Persona/, err.message)
    end

    it 'raises on duplicate persona names — fail fast on a quiet config bug' do
      twin = Pikuri::SubAgent::Persona.new(
        name: 'researcher', description: 'd', tool_names: %w[web_search],
        system_prompt: 's'
      )
      err = assert_raises(ArgumentError) do
        described_class.new(personas: [tiny_persona, twin])
      end
      assert_match(/duplicate persona name "researcher"/, err.message)
    end

    it 'exposes the resolved hash keyed by persona name in declaration order' do
      ext = described_class.new(personas: [tiny_persona, file_miner_persona])
      assert_equal %w[researcher file_miner], ext.personas.keys
      assert_same tiny_persona, ext.personas['researcher']
      assert_same file_miner_persona, ext.personas['file_miner']
    end
  end

  describe '#configure' do
    it 'raises when a persona references a tool not yet added to the Configurator' do
      err = assert_raises(ArgumentError) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's') do |c|
          c.add_listener recorder
          # no c.add_tool — tiny_persona needs web_search, which is missing
          c.add_extension described_class.new(personas: [tiny_persona])
        end
      end
      assert_match(/references unregistered tool/, err.message)
      assert_match(/"web_search"/, err.message)
    end

    it 'lists every missing tool name in the error' do
      multi = Pikuri::SubAgent::Persona.new(
        name: 'multi',
        description: 'd',
        tool_names: %w[read grep glob bash],
        system_prompt: 's'
      )
      err = assert_raises(ArgumentError) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's') do |c|
          c.add_listener recorder
          c.add_extension described_class.new(personas: [multi])
        end
      end
      %w[read grep glob bash].each do |missing|
        assert_match(/"#{missing}"/, err.message)
      end
    end

    it 'satisfies a persona tool_names entry from the sub-agent-only pool' do
      # Verifies the trifecta-defense use case: web_search is wired only
      # via add_sub_agent_tool, the persona that references it still
      # passes validation, and the tool never reaches the parent's chat.
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_sub_agent_tool web_search_tool
        c.add_extension described_class.new(personas: [tiny_persona])
      end

      assert_equal [web_search_tool], agent.sub_agent_tools
      assert_empty agent.tools
      # The chat got only the `agent` delegation tool — no web_search.
      chat = @fake_chats.first
      tool_names = chat.tools.map { |t| t.respond_to?(:name) ? t.name : nil }.compact
      refute_includes tool_names, 'web_search'
    end

    it 'errors when a persona tool name is missing from both pools' do
      err = assert_raises(ArgumentError) do
        Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                          system_prompt: 's') do |c|
          c.add_listener recorder
          c.add_tool Pikuri::Tool::CALCULATOR    # parent pool, irrelevant name
          c.add_sub_agent_tool Pikuri::Tool::FETCH # sub-agent pool, irrelevant name
          c.add_extension described_class.new(personas: [tiny_persona])
        end
      end
      assert_match(/references unregistered tool/, err.message)
      assert_match(/"web_search"/, err.message)
      assert_match(/c\.add_tool or c\.add_sub_agent_tool/, err.message)
    end

    it 'appends a single <available_agents> snippet describing every persona' do
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_tool web_search_tool
        c.add_extension described_class.new(personas: [tiny_persona, file_miner_persona])
      end

      assert_match(/<available_agents>/, agent.system_prompt)
      assert_match(/`researcher` — d/, agent.system_prompt)
      assert_match(/`file_miner` — fs recon/, agent.system_prompt)
    end
  end

  describe '#bind' do
    it 'registers exactly one `agent` tool on the underlying chat' do
      Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                        system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_tool web_search_tool
        c.add_extension described_class.new(personas: [tiny_persona])
      end

      chat = @fake_chats.first
      agent_tools = chat.tools.select { |t| t.respond_to?(:name) && t.name == 'agent' }
      assert_equal 1, agent_tools.size
    end

    it "does NOT add the SubAgentTool to the parent agent's @tools — it's a per-agent dynamic tool" do
      # Same convention MCP follows: dynamic per-agent tools go through
      # ctx.add_raw_tool (i.e. directly onto @chat), not into @tools.
      agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                                system_prompt: 's') do |c|
        c.add_listener recorder
        c.add_tool web_search_tool
        c.add_extension described_class.new(personas: [tiny_persona])
      end

      tools = agent.instance_variable_get(:@tools)
      refute(tools.any? { |t| t.is_a?(Pikuri::SubAgent::SubAgentTool) })
    end

    it "forwards the parent's resolved context_window_cap to the sub-agent via its transport" do
      agent = Pikuri::Agent.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm', context_window: 12_345),
        system_prompt: 's'
      ) do |c|
        c.add_listener recorder
        c.add_tool web_search_tool
        c.add_extension described_class.new(personas: [tiny_persona])
      end

      # Find the SubAgentTool the extension installed and run it through
      # a stubbed Pikuri::Agent.new to capture the kwarg.
      original_new = Pikuri::Agent.method(:new)
      received_kwargs = nil
      Pikuri::Agent.define_singleton_method(:new) do |**kwargs, &block|
        received_kwargs = kwargs
        original_new.call(**kwargs, &block).tap do |a|
          a.define_singleton_method(:run_loop) { |**_| nil }
          a.define_singleton_method(:last_assistant_content) { 'sub reply' }
        end
      end

      begin
        chat = @fake_chats.first
        agent_tool_class = chat.tools.find { |t| t.respond_to?(:name) && t.name == 'agent' }
        # The chat receives the RubyLLM::Tool synthetic subclass; we need
        # the Pikuri::SubAgent::SubAgentTool that produced it. Easiest
        # path: dig the SubAgentTool out of the extension instance.
        ext = agent.extensions.find { |e| e.is_a?(described_class) }
        refute_nil ext
        # The SubAgentTool is closed over by bind; we re-create one
        # (against the agent's ExtensionContext, the shape bind
        # received) and invoke its execute closure to assert the
        # propagation policy.
        ctx = agent.instance_variable_get(:@extension_context)
        sub_tool = Pikuri::SubAgent::SubAgentTool.new(ctx, personas: ext.personas)
        sub_tool.run('name' => 'researcher', 'task' => 'do the thing')
        # The cap rides the sub-agent's transport now, not a ctor kwarg.
        refute received_kwargs.key?(:context_window)
        assert_equal 12_345, received_kwargs[:transport].context_window
      ensure
        Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original_new.call(**kw, &blk) }
      end
    end
  end
end
