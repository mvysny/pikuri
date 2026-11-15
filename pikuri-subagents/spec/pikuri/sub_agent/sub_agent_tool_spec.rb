# frozen_string_literal: true

RSpec.describe Pikuri::SubAgent::SubAgentTool do
  # Minimal stand-in for +RubyLLM::Chat+: records what +Pikuri::Agent+
  # configures on it, drops a canned assistant +Message+ into +messages+
  # on +ask+, and exposes +tools+ for assertions. Keeps sub-agent specs
  # network-free.
  #
  # +RubyLLM::Model+ stand-in just so +Pikuri::Agent+ can read
  # +@chat.model.id+.
  fake_model = Struct.new(:context_window, :id).new(nil, 'm')

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

      def with_provider_options(_)
        self
      end

      def with_tools(tool)
        @tools << tool
        self
      end

      def after_message(&); self; end
      def before_tool_call(&); self; end
      def after_tool_result(&); self; end

      def add_message(attrs)
        @messages << (attrs.is_a?(RubyLLM::Message) ? attrs : RubyLLM::Message.new(**attrs))
        @messages.last
      end

      # +Agent#run_loop+ appends the user turn via +#add_message+ then
      # drives completion via +#complete+ (the two halves of +#ask+), so
      # the canned assistant reply lands here. +#ask+ is kept for any
      # direct caller, mirroring the same behaviour.
      def complete(&)
        @messages << RubyLLM::Message.new(role: :assistant, content: @reply)
        @messages.last
      end

      def ask(message)
        @asks << message
        complete
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
  # short prompt.
  let(:simple_persona) do
    Pikuri::SubAgent::Persona.new(
      name: 'researcher',
      description: 'simple researcher',
      tool_names: %w[web_search],
      system_prompt: 'be terse'
    )
  end

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

  let(:parent_listeners) do
    Pikuri::Agent::ListenerList.new([Pikuri::Agent::Listener::InMemoryEventList.new])
  end

  # Build a minimal parent Pikuri::Agent against the fake +RubyLLM.chat+
  # stubbed in the outer +before+, and return its Configurator — what
  # SubAgentTool's ctor takes (in production, the one
  # SubAgent::Extension#configure received).
  def build_parent(system_prompt: 'sp', tools: [web_search_tool], listeners: nil,
                   cancellable: nil, id: '')
    configurator = nil
    Pikuri::Agent.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt: system_prompt,
      cancellable: cancellable,
      id: id
    ) do |c|
      configurator = c
      c.add_tools(tools)
      c.add_listeners(listeners || parent_listeners)
    end
    configurator
  end

  # Run one delegation with Pikuri::Agent.new stubbed, and hand back the tool
  # list the sub-agent was actually configured with — which is where every
  # per-child tool rebuild shows up.
  def run_with_captured_tools(tool, name:)
    captured_tools = nil
    original_new = Pikuri::Agent.method(:new)
    Pikuri::Agent.define_singleton_method(:new) do |**kwargs, &block|
      original_new.call(**kwargs) do |c|
        block&.call(c)
        captured_tools = c.tools.dup
      end.tap do |a|
        a.define_singleton_method(:run_loop) { |**_| nil }
        a.define_singleton_method(:last_assistant_content) { 'sub reply' }
      end
    end
    begin
      tool.run('name' => name, 'task' => 'go')
      captured_tools
    ensure
      Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original_new.call(**kw, &blk) }
    end
  end

  describe 'tool shape' do
    it 'returns a Pikuri::Tool named "agent" with required `name` (enum) + `task` parameters' do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      assert_kind_of Pikuri::Tool, tool
      assert_equal 'agent', tool.name
      schema = tool.parameters.to_openai
      assert_equal %w[name task], schema[:required]
      assert_equal 'string', schema[:properties][:name][:type]
      assert_equal ['researcher'], schema[:properties][:name][:enum]
      assert_equal 'string', schema[:properties][:task][:type]
    end

    it "seeds the `name` example from the first wired persona (can't drift)" do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      assert_includes tool.parameters.to_openai[:properties][:name][:description], 'e.g. "researcher"'
    end

    it 'raises if constructed with no personas — the tool would be useless' do
      assert_raises(ArgumentError) do
        described_class.new(build_parent, personas: {})
      end
    end

    it "exposes every registered persona's name in the `name:` parameter enum" do
      other = Pikuri::SubAgent::Persona.new(
        name: 'file_miner',
        description: 'd',
        tool_names: %w[web_search],
        system_prompt: 's'
      )
      tool = described_class.new(
        build_parent,
        personas: { 'researcher' => simple_persona, 'file_miner' => other }
      )

      assert_equal %w[researcher file_miner], tool.parameters.to_openai[:properties][:name][:enum]
    end
  end

  describe 'execution' do
    it 'runs the sub-agent loop and returns its final assistant message' do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      result = tool.run('name' => 'researcher', 'task' => 'do the thing').to_s

      assert_equal 'sub-agent reply', result
    end

    it 'shows the persona and its task on the call line, and the answer size on the result' do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      assert_equal 'researcher: do the thing',
                   tool.describe_call('name' => 'researcher', 'task' => 'do the thing')
      assert_equal 'Answered, 15 B', tool.run('name' => 'researcher', 'task' => 'x').summary
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
      user_turns = sub_chat.messages.select { |m| m.role == :user }.map(&:content)
      assert_equal ['count to three'], user_turns
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
      result = tool.run('name' => 'planner', 'task' => 'x').to_s
      assert_match(/must be one of `researcher`/, result)
    end
  end

  describe 'sub-agent naming and control derivation' do
    # Capture every kwarg handed to Pikuri::Agent.new so the spec can
    # read the generated +id:+ / +cancellable:+ without having to introspect a built Pikuri::Agent.
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
        name: 'file_miner',
        description: 'd',
        tool_names: %w[web_search],
        system_prompt: 's'
      )
      tool = described_class.new(
        build_parent,
        personas: { 'researcher' => simple_persona, 'file_miner' => other }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'a')
        tool.run('name' => 'file_miner', 'task' => 'b')
        tool.run('name' => 'researcher', 'task' => 'c')
        tool.run('name' => 'file_miner', 'task' => 'd')

        assert_equal ['researcher 0', 'file_miner 0', 'researcher 1', 'file_miner 1'],
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

    it 'passes nil cancellable when the parent had none' do
      tool = described_class.new(
        build_parent,
        personas: { 'researcher' => simple_persona }
      )

      with_captured_agent_new do |kwargs|
        tool.run('name' => 'researcher', 'task' => 'go')

        assert_nil kwargs.first[:cancellable]
        # The child's loop is unbounded, as the parent's is (D_no_step_limit).
        refute_includes kwargs.first.keys, :step_limit
      end
    end
  end

  describe 'the for_sub_agent tool hook' do
    # A tool that must hand the child something narrower than it holds. The
    # `narrowed` flag stands in for whatever that is — a sealed skill
    # activation, in the one shipped implementation.
    let(:narrowable_tool) do
      Class.new(Pikuri::Tool) do
        attr_reader :narrowed

        def initialize(narrowed: false)
          @narrowed = narrowed
          super(
            name: 'narrowable',
            description: 'fake',
            parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :x, 'x' },
            execute: ->(x:) { x }
          )
        end

        def for_sub_agent = self.class.new(narrowed: true)
      end.new
    end

    let(:narrowable_persona) do
      Pikuri::SubAgent::Persona.new(
        name: 'researcher',
        description: 'd',
        tool_names: %w[narrowable web_search],
        system_prompt: 's'
      )
    end

    it 'rebuilds a tool that defines it, and passes the others through unchanged' do
      parent = build_parent(tools: [narrowable_tool, web_search_tool])
      tool = described_class.new(parent, personas: { 'researcher' => narrowable_persona })

      sub_tools = run_with_captured_tools(tool, name: 'researcher')

      assert sub_tools.find { |t| t.name == 'narrowable' }.narrowed,
             'expected the child to get the narrowed copy'
      assert_same web_search_tool, sub_tools.find { |t| t.name == 'web_search' }
    end

    it 'leaves the parent holding its own instance' do
      parent = build_parent(tools: [narrowable_tool, web_search_tool])
      tool = described_class.new(parent, personas: { 'researcher' => narrowable_persona })

      run_with_captured_tools(tool, name: 'researcher')

      refute narrowable_tool.narrowed, 'the parent must not be narrowed by spawning a child'
    end
  end

  describe 'task-prompt confirmation gate' do
    # Minimal confirmer: records the request it was asked, then returns
    # whatever its +decision+ lambda produces for that request. Mirrors
    # the Pikuri::Workspace::Confirmer duck type (only #ask(request:)
    # is used here).
    let(:confirmer_class) do
      Class.new do
        attr_reader :requests

        # @param decision [#call] request -> Approved / Rejected / Redirected
        def initialize(decision:)
          @decision = decision
          @requests = []
        end

        def ask(request:, cancellable:)
          @requests << request
          @decision.call(request)
        end
      end
    end

    # Convenience builders for the decision arms.
    def approve_as_is
      ->(r) { Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: r.detail) }
    end

    def approve_edited(text)
      ->(_r) { Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: text) }
    end

    def reject
      ->(_r) { Pikuri::Workspace::Confirmer::Rejected.new }
    end

    def redirect_with(message)
      ->(_r) { Pikuri::Workspace::Confirmer::Redirected.new(message: message) }
    end

    # The confirm prompt sits between the parent's tool-call check and the
    # child's turn, so it is where a cancel most often lands in that window.
    # The child shares the token; its turn must not clear the parent's cancel.
    it 'keeps a cancel sent while the delegation awaits confirmation' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      cancel_then_approve = lambda do |r|
        cancel.cancel!
        Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: r.detail)
      end
      tool = described_class.new(
        build_parent(cancellable: cancel), personas: { 'researcher' => simple_persona },
                                           confirmer: confirmer_class.new(decision: cancel_then_approve)
      )

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        tool.run('name' => 'researcher', 'task' => 'look up X')
      end
      assert cancel.cancelled?, "the child's turn swallowed the parent's cancel"
      refute @fake_chats.last.asks.any? || @fake_chats.last.messages.any? { |m| m.role == :assistant },
             'the child must not complete'
    end

    it 'confirms the task before dispatch, marking it editable and showing it as the detail' do
      confirmer = confirmer_class.new(decision: approve_as_is)
      tool = described_class.new(
        build_parent, personas: { 'researcher' => simple_persona }, confirmer: confirmer
      )

      result = tool.run('name' => 'researcher', 'task' => 'look up X').to_s

      assert_equal 'sub-agent reply', result
      assert_equal 1, confirmer.requests.size
      assert_equal 'look up X', confirmer.requests.first.detail
      assert confirmer.requests.first.editable, 'the task must be offered editable (author seat)'
      assert_match(/researcher/, confirmer.requests.first.question)
      # @fake_chats holds the parent's chat (from build_parent) plus the
      # sub-agent's — so a spawned delegation makes it 2.
      assert_equal 2, @fake_chats.size
    end

    it 'dispatches the human-edited task, not the original, when approved with an edit' do
      confirmer = confirmer_class.new(decision: approve_edited('look up Y instead'))
      tool = described_class.new(
        build_parent, personas: { 'researcher' => simple_persona }, confirmer: confirmer
      )

      result = tool.run('name' => 'researcher', 'task' => 'look up X').to_s

      assert_equal 'sub-agent reply', result
      sub_chat = @fake_chats.last
      user_turns = sub_chat.messages.select { |m| m.role == :user }.map(&:content)
      assert_equal ['look up Y instead'], user_turns
    end

    it 'returns a decline observation and spawns no sub-agent when rejected' do
      confirmer = confirmer_class.new(decision: reject)
      tool = described_class.new(
        build_parent, personas: { 'researcher' => simple_persona }, confirmer: confirmer
      )

      result = tool.run('name' => 'researcher', 'task' => 'look up X').to_s

      assert_equal "Error: user declined delegation to researcher. Don't retry it or reach the " \
                   'same end another way; tell the user you stopped.', result
      # Only the parent's chat exists; no sub-agent was spawned.
      assert_equal 1, @fake_chats.size
    end

    it 'quotes a redirect back to the parent and spawns no sub-agent' do
      confirmer = confirmer_class.new(decision: redirect_with('use the local docs, not the web'))
      tool = described_class.new(
        build_parent, personas: { 'researcher' => simple_persona }, confirmer: confirmer
      )

      result = tool.run('name' => 'researcher', 'task' => 'look up X').to_s

      assert_equal 'The user declined delegation to researcher and said: use the local docs, not the web', result
      assert_equal 1, @fake_chats.size
    end

    it 'delegates without asking when no confirmer is wired (default)' do
      tool = described_class.new(build_parent, personas: { 'researcher' => simple_persona })

      result = tool.run('name' => 'researcher', 'task' => 'go').to_s

      assert_equal 'sub-agent reply', result
      assert_equal 2, @fake_chats.size
    end
  end

  describe '.available_agents_snippet' do
    it 'lists each persona name and description as a markdown bullet inside <available_agents>' do
      other = Pikuri::SubAgent::Persona.new(
        name: 'file_miner',
        description: 'fs recon',
        tool_names: %w[web_search],
        system_prompt: 's'
      )
      snippet = described_class.available_agents_snippet(
        'researcher' => simple_persona,
        'file_miner' => other
      )

      assert_match(/<available_agents>/, snippet)
      assert_match(/<\/available_agents>/, snippet)
      assert_match(/- `researcher` — simple researcher/, snippet)
      assert_match(/- `file_miner` — fs recon/, snippet)
    end
  end
end
