# frozen_string_literal: true

RSpec.describe Pikuri::SubAgent::SubAgentTool do
  # Minimal stand-in for +RubyLLM::Chat+: records what +Pikuri::Agent+
  # configures on it, drops a canned assistant +Message+ into +messages+
  # on +ask+, and exposes +tools+ for assertions. Keeps sub-agent specs
  # network-free.
  #
  # +RubyLLM::Model::Info+ stand-in just so +Pikuri::Agent#initialize+
  # can read +@chat.model.context_window+ for +ContextWindowDetector+.
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

  # Stand-in tools the personas may filter against.
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
    Pikuri::SubAgent::Persona.new(
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
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      assert_kind_of Pikuri::Tool, tool
      assert_equal 'agent', tool.name
      schema = tool.parameters.to_h
      assert_equal %w[name task], schema[:required]
      assert_equal 'string', schema[:properties][:name][:type]
      assert_equal ['researcher'], schema[:properties][:name][:enum]
      assert_equal 'string', schema[:properties][:task][:type]
    end

    it "exposes every registered persona's name in the `name:` parameter enum" do
      other = Pikuri::SubAgent::Persona.new(
        name: 'scout',
        description: 'd',
        tool_names: %w[web_search],
        system_prompt: 's',
        max_steps: 5
      )
      tool = described_class.new(
        build_parent,
        personas: { 'researcher' => simple_persona, 'scout' => other }
      )

      assert_equal %w[researcher scout], tool.parameters.to_h[:properties][:name][:enum]
    end
  end

  describe 'execution' do
    it 'runs the sub-agent loop and returns its final assistant message' do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      result = tool.run('name' => 'researcher', 'task' => 'do the thing')

      assert_equal 'sub-agent reply', result
    end

    it "configures the sub-agent's chat with the *persona's* system prompt, not the parent's" do
      tool = described_class.new(
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
      tool = described_class.new(parent, personas: { 'researcher' => simple_persona })

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
      tool = described_class.new(parent, personas: { 'researcher' => simple_persona })

      tool.run('name' => 'researcher', 'task' => 'go')

      sub_chat = @fake_chats.last
      assert_equal 1, sub_chat.tools.size
      assert_equal 'web_search', sub_chat.tools.first.name
    end

    it 'returns an Error: when the LLM passes a persona name not in the enum' do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

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
    # read the generated +id:+ / +step_limit:+ / +cancellable:+ /
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

    it 'generates persona-rooted monotonic ids per persona' do
      other = Pikuri::SubAgent::Persona.new(
        name: 'scout',
        description: 'd',
        tool_names: %w[web_search],
        system_prompt: 's',
        max_steps: 3
      )
      tool = described_class.new(
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
      tool = described_class.new(
        build_parent(listeners: parent_list),
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new { |_| tool.run('name' => 'researcher', 'task' => 'go') }

      assert_equal [{ id: 'researcher 0' }], recorded
    end

    it "constructs a fresh StepLimit at the persona's max_steps for the sub-agent" do
      tool = described_class.new(
        build_parent(step_limit: Pikuri::Agent::Control::StepLimit.new(max: 99)),
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        sub_step = kwargs.first[:step_limit]
        assert_kind_of Pikuri::Agent::Control::StepLimit, sub_step
        # simple_persona declares max_steps: 7
        assert_equal 7, sub_step.max
      end
    end

    it 'shares the parent Cancellable by reference with the sub-agent (one cancel stops the tree)' do
      parent_cancel = Pikuri::Agent::Control::Cancellable.new
      tool = described_class.new(
        build_parent(cancellable: parent_cancel),
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        assert_same parent_cancel, kwargs.first[:cancellable]
      end
    end

    it 'passes nil cancellable when the parent had none, fresh StepLimit regardless' do
      tool = described_class.new(
        build_parent,
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        assert_nil kwargs.first[:cancellable]
        assert_kind_of Pikuri::Agent::Control::StepLimit, kwargs.first[:step_limit]
        assert_equal 7, kwargs.first[:step_limit].max
      end
    end
  end

  describe 'per-invocation temp workspace (Persona#workspace_builder)' do
    # A minimal "with_workspace-able" tool. Records each workspace value
    # it was rebuilt against; that's enough to assert SubAgentTool
    # plumbed the builder's output to the sub-agent's tools.
    let(:workspace_aware_tool) do
      Class.new(Pikuri::Tool) do
        attr_reader :workspace

        def initialize(workspace: nil)
          @workspace = workspace
          super(
            name: 'workspace_aware',
            description: 'fake',
            parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :x, 'x' },
            execute: ->(x:) { x }
          )
        end

        def with_workspace(ws)
          # Track the chain by stashing the latest workspace on the new instance.
          self.class.new(workspace: ws)
        end
      end.new
    end

    # Persona that needs a temp workspace; its tool_names include both
    # the workspace-aware tool (to verify with_workspace is called) and
    # a stateless tool (web_search, to verify pass-through).
    let(:investigator_persona) do
      Pikuri::SubAgent::Persona.new(
        name: 'investigator',
        description: 'd',
        tool_names: %w[workspace_aware web_search],
        system_prompt: 's',
        max_steps: 5,
        workspace_builder: lambda { |temp_root|
          # Stand-in for Pikuri::Workspace::Filesystem — the test only
          # cares that *some* object reaches with_workspace, and that
          # the temp_root path exists when builder is invoked.
          Struct.new(:project_root).new(temp_root)
        }
      )
    end

    it 'mkdirs a fresh temp dir per invocation and passes it to workspace_builder' do
      received_paths = []
      persona = investigator_persona.with(
        workspace_builder: lambda { |path|
          received_paths << path
          assert File.directory?(path), "expected fresh temp dir, got #{path.inspect}"
          Struct.new(:project_root).new(path)
        }
      )
      parent = build_parent(tools: [workspace_aware_tool, web_search_tool])
      tool = described_class.new(parent, personas: { 'investigator' => persona })

      tool.run('name' => 'investigator', 'task' => 'go')
      tool.run('name' => 'investigator', 'task' => 'again')

      assert_equal 2, received_paths.size, 'builder should fire once per invocation'
      refute_equal received_paths[0], received_paths[1], 'each invocation gets its own dir'
    end

    it 'rebuilds workspace-aware tools onto the new workspace and passes others through unchanged' do
      received_tools = nil
      original_new = Pikuri::Agent.method(:new)
      Pikuri::Agent.define_singleton_method(:new) do |**kwargs, &block|
        original_new.call(**kwargs) do |c|
          block&.call(c)
          received_tools = c.tools.dup
        end.tap do |a|
          a.define_singleton_method(:run_loop) { |**_| nil }
          a.define_singleton_method(:last_assistant_content) { 'sub reply' }
        end
      end

      begin
        parent = build_parent(tools: [workspace_aware_tool, web_search_tool])
        tool = described_class.new(parent, personas: { 'investigator' => investigator_persona })

        tool.run('name' => 'investigator', 'task' => 'go')

        ws_aware = received_tools.find { |t| t.name == 'workspace_aware' }
        ws_search = received_tools.find { |t| t.name == 'web_search' }
        refute_nil ws_aware
        refute_nil ws_search
        # workspace_aware was rebuilt — different instance from parent's
        refute_same workspace_aware_tool, ws_aware
        refute_nil ws_aware.workspace
        # web_search is stateless — passed through by reference
        assert_same web_search_tool, ws_search
      ensure
        Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original_new.call(**kw, &blk) }
      end
    end

    it 'removes the temp dir when the sub-agent closes' do
      captured_path = nil
      persona = investigator_persona.with(
        workspace_builder: lambda { |path|
          captured_path = path
          Struct.new(:project_root).new(path)
        }
      )
      parent = build_parent(tools: [workspace_aware_tool, web_search_tool])
      tool = described_class.new(parent, personas: { 'investigator' => persona })

      tool.run('name' => 'investigator', 'task' => 'go')

      refute_nil captured_path
      refute File.exist?(captured_path), "expected temp dir to be removed after sub-agent close"
    end

    it 'does NOT mint a temp dir when persona.needs_temp_workspace? is false' do
      called = false
      original_mktmpdir = Dir.method(:mktmpdir)
      Dir.define_singleton_method(:mktmpdir) do |*args, &blk|
        called = true
        original_mktmpdir.call(*args, &blk)
      end
      begin
        tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })
        tool.run('name' => 'researcher', 'task' => 'go')
        refute called, 'simple_persona has no workspace_builder; mktmpdir should not fire'
      ensure
        Dir.define_singleton_method(:mktmpdir, original_mktmpdir)
      end
    end
  end

  describe '.available_agents_snippet' do
    it 'lists each persona name and description as a markdown bullet inside <available_agents>' do
      other = Pikuri::SubAgent::Persona.new(
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
