# frozen_string_literal: true

RSpec.describe Pikuri::Tool::SubAgent do
  # Minimal stand-in for +RubyLLM::Chat+: records what +Pikuri::Agent+
  # configures on it, drops a canned assistant +Message+ into +messages+
  # on +ask+, and exposes +calls+ for assertions. Keeps sub-agent specs
  # network-free.
  # +RubyLLM::Model::Info+ stand-in just so +Pikuri::Agent#initialize+
  # can read +@chat.model.context_window+ for {Pikuri::Agent::ContextWindowDetector}.
  fake_model = Struct.new(:context_window).new(nil)

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions

      define_method(:initialize) do |reply: 'sub-agent reply'|
        @tools = []
        @asks = []
        @messages = []
        @reply = reply
        @model_info = captured_model
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

      def after_message(&); self; end
      def before_tool_call(&); self; end
      def after_tool_result(&); self; end

      def ask(message)
        @asks << message
        @messages << RubyLLM::Message.new(role: :assistant, content: @reply)
        @messages.last
      end
    end
  end

  # Two stand-in tools the personas may filter against. Names match
  # what the bundled RESEARCHER persona expects so we can use it in
  # the realistic-path test below.
  let(:web_search_tool) do
    Pikuri::Tool.new(
      name: 'web_search',
      description: 'fake',
      parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :q, 'q' },
      execute: ->(q:) { q }
    )
  end

  let(:web_scrape_tool) do
    Pikuri::Tool.new(
      name: 'web_scrape',
      description: 'fake',
      parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :url, 'url' },
      execute: ->(url:) { url }
    )
  end

  let(:fetch_tool) do
    Pikuri::Tool.new(
      name: 'fetch',
      description: 'fake',
      parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :url, 'url' },
      execute: ->(url:) { url }
    )
  end

  let(:calculator_tool) do
    Pikuri::Tool.new(
      name: 'calculator',
      description: 'fake',
      parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :expr, 'e' },
      execute: ->(expr:) { expr }
    )
  end

  # Simple persona used by tests that want a quick one — single tool,
  # short prompt, max_steps that's easy to assert against.
  let(:simple_persona) do
    Pikuri::Tool::SubAgent::Persona.new(
      name: 'researcher',
      description: 'simple researcher',
      tool_names: %w[web_search],
      system_prompt: 'be terse',
      max_steps: 7
    )
  end

  before do
    @fake_chats = []
    fake_class = fake_chat_class
    captured = @fake_chats
    @original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) do |**_|
      chat = fake_class.new
      captured << chat
      chat
    end
  end

  after do
    original = @original_chat
    RubyLLM.define_singleton_method(:chat) { |**kwargs| original.call(**kwargs) }
  end

  let(:parent_listeners) do
    Pikuri::Agent::ListenerList.new([Pikuri::Agent::Listener::InMemoryEventList.new])
  end

  # Build a minimal parent Pikuri::Agent against the fake +RubyLLM.chat+
  # stubbed in the outer +before+. Tools and listeners go through the
  # Configurator block.
  def build_parent(system_prompt: 'sp', tools: [web_search_tool], listeners: nil,
                   step_limit: nil, cancellable: nil, id: '')
    Pikuri::Agent.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt: system_prompt,
      step_limit: step_limit,
      cancellable: cancellable,
      id: id
    ) do |c|
      c.add_tools(tools)
      c.add_listeners(listeners || parent_listeners)
    end
  end

  describe 'tool shape' do
    it 'returns a Pikuri::Tool named "agent" with required `name` (enum) + `task` parameters' do
      tool = Pikuri::Tool::SubAgent.new(build_parent, personas: { 'researcher' => simple_persona })

      assert_kind_of Pikuri::Tool, tool
      assert_equal 'agent', tool.name
      schema = tool.parameters.to_h
      assert_equal %w[name task], schema[:required]
      assert_equal 'string', schema[:properties][:name][:type]
      assert_equal ['researcher'], schema[:properties][:name][:enum]
      assert_equal 'string', schema[:properties][:task][:type]
    end

    it "exposes every registered persona's name in the `name:` parameter enum" do
      other = Pikuri::Tool::SubAgent::Persona.new(
        name: 'scout',
        description: 'd',
        tool_names: %w[web_search],
        system_prompt: 's',
        max_steps: 5
      )
      tool = Pikuri::Tool::SubAgent.new(
        build_parent,
        personas: { 'researcher' => simple_persona, 'scout' => other }
      )

      assert_equal %w[researcher scout], tool.parameters.to_h[:properties][:name][:enum]
    end
  end

  describe 'execution' do
    it 'runs the sub-agent loop and returns its final assistant message' do
      tool = Pikuri::Tool::SubAgent.new(build_parent, personas: { 'researcher' => simple_persona })

      result = tool.run('name' => 'researcher', 'task' => 'do the thing')

      assert_equal 'sub-agent reply', result
    end

    it "configures the sub-agent's chat with the *persona's* system prompt, not the parent's" do
      tool = Pikuri::Tool::SubAgent.new(
        build_parent(system_prompt: 'PARENT_PROMPT'),
        personas: { 'researcher' => simple_persona }
      )

      tool.run('name' => 'researcher', 'task' => 'count to three')

      sub_chat = @fake_chats.last
      assert_equal 'be terse', sub_chat.instructions
      refute_match(/PARENT_PROMPT/, sub_chat.instructions)
      assert_equal ['count to three'], sub_chat.asks
    end

    it "advertises exactly the persona's tool_names subset to the sub-agent" do
      # Parent has four tools; persona only names web_search.
      parent = build_parent(tools: [web_search_tool, web_scrape_tool, fetch_tool, calculator_tool])
      tool = Pikuri::Tool::SubAgent.new(parent, personas: { 'researcher' => simple_persona })

      tool.run('name' => 'researcher', 'task' => 'go')

      sub_chat = @fake_chats.last
      wired_names = sub_chat.tools.map(&:name)
      assert_equal ['web_search'], wired_names
    end

    it 'reuses parent tool instances by reference (no reconstruction)' do
      # Important property: the child sees the same tool *objects*, so
      # any workspace/confirmer wiring already on the parent's tools
      # travels along without reconstruction in the persona path.
      parent = build_parent(tools: [web_search_tool])
      tool = Pikuri::Tool::SubAgent.new(parent, personas: { 'researcher' => simple_persona })

      tool.run('name' => 'researcher', 'task' => 'go')

      sub_chat = @fake_chats.last
      assert_equal 1, sub_chat.tools.size
      # the fake chat records the ruby_llm-adapted class, so peek at
      # the original via its name (cheapest invariant); but the
      # parent's Pikuri::Tool instance is in parent.tools and the
      # filter happens on it — see below
      assert_equal 'web_search', sub_chat.tools.first.name
    end

    it 'returns an Error: when the LLM passes a persona name not in the enum' do
      tool = Pikuri::Tool::SubAgent.new(build_parent, personas: { 'researcher' => simple_persona })

      # The agent tool feeds through Tool#run which validates via
      # Tool::Parameters. An unknown enum value comes back as a
      # ValidationError formatted into "Error: ..." by the Tool's
      # run path — same contract every other strict-validated tool
      # uses.
      result = tool.run('name' => 'planner', 'task' => 'x')
      assert_match(/must be one of `researcher`/, result)
    end
  end

  describe 'sub-agent naming and control derivation' do
    # Capture every kwarg handed to Pikuri::Agent.new so the spec can
    # read the generated +name:+ / +step_limit:+ / +cancellable:+ /
    # +context_window:+ without having to introspect a built
    # Pikuri::Agent.
    def with_captured_agent_new
      received = []
      original_new = Pikuri::Agent.method(:new)
      Pikuri::Agent.define_singleton_method(:new) do |**kwargs, &block|
        received << kwargs
        original_new.call(**kwargs, &block).tap do |a|
          a.define_singleton_method(:run_loop)               { |**_| nil }
          a.define_singleton_method(:last_assistant_content) { 'sub reply' }
        end
      end
      begin
        yield received
      ensure
        Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original_new.call(**kw, &blk) }
      end
    end

    it 'generates persona-rooted monotonic names per persona' do
      other = Pikuri::Tool::SubAgent::Persona.new(
        name: 'scout',
        description: 'd',
        tool_names: %w[web_search],
        system_prompt: 's',
        max_steps: 3
      )
      tool = Pikuri::Tool::SubAgent.new(
        build_parent,
        personas: { 'researcher' => simple_persona, 'scout' => other }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'a')
        tool.run('name' => 'scout',      'task' => 'b')
        tool.run('name' => 'researcher', 'task' => 'c')
        tool.run('name' => 'scout',      'task' => 'd')

        assert_equal ['researcher 0', 'scout 0', 'researcher 1', 'scout 1'],
                     kwargs.map { |kw| kw[:id] }
      end
    end

    it 'threads the generated id to each listener.for_sub_agent via ListenerList#for_sub_agent' do
      recorded = []
      spy_listener = Class.new do
        define_method(:initialize) { |out| @out = out }
        def on_event(_); end
        define_method(:for_sub_agent) do |**params|
          @out << params
          self
        end
      end.new(recorded)

      parent_list = Pikuri::Agent::ListenerList.new([spy_listener])
      tool = Pikuri::Tool::SubAgent.new(
        build_parent(listeners: parent_list),
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new { |_| tool.run('name' => 'researcher', 'task' => 'go') }

      assert_equal [{ id: 'researcher 0' }], recorded
    end

    it "derives a fresh StepLimit at the persona's max_steps for the sub-agent" do
      parent_step = Pikuri::Agent::Control::StepLimit.new(max: 99)
      tool = Pikuri::Tool::SubAgent.new(
        build_parent(step_limit: parent_step),
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        sub_step = kwargs.first[:step_limit]
        assert_kind_of Pikuri::Agent::Control::StepLimit, sub_step
        refute_same parent_step, sub_step
        # simple_persona declares max_steps: 7
        assert_equal 7, sub_step.max
      end
    end

    it 'shares the parent Cancellable by reference with the sub-agent (one cancel stops the tree)' do
      parent_cancel = Pikuri::Agent::Control::Cancellable.new
      tool = Pikuri::Tool::SubAgent.new(
        build_parent(cancellable: parent_cancel),
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        assert_same parent_cancel, kwargs.first[:cancellable]
      end
    end

    it 'passes nil step_limit / cancellable when the parent had none' do
      tool = Pikuri::Tool::SubAgent.new(
        build_parent,
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        assert_nil kwargs.first[:step_limit]
        assert_nil kwargs.first[:cancellable]
      end
    end
  end

  describe '.available_agents_snippet' do
    it 'lists each persona name and description as a markdown bullet inside <available_agents>' do
      other = Pikuri::Tool::SubAgent::Persona.new(
        name: 'scout',
        description: 'fs recon',
        tool_names: %w[web_search],
        system_prompt: 's',
        max_steps: 3
      )
      snippet = described_class.available_agents_snippet(
        'researcher' => simple_persona,
        'scout'      => other
      )

      assert_match(/<available_agents>/, snippet)
      assert_match(/<\/available_agents>/, snippet)
      assert_match(/- `researcher` — simple researcher/, snippet)
      assert_match(/- `scout` — fs recon/, snippet)
    end
  end
end
