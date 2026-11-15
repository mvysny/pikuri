# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Configurator do
  # Bare-minimum chat stand-in: records tools registered via +with_tools+,
  # the only chat surface the Configurator touches.
  let(:fake_chat_class) do
    Class.new do
      attr_reader :tools

      def initialize
        @tools = []
      end

      def with_tools(tool)
        @tools << tool
        self
      end
    end
  end

  let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:listeners) { Pikuri::Agent::ListenerList.new([recorder]) }
  let(:fake_chat) { fake_chat_class.new }
  let(:fake_agent) { Object.new }
  let(:close_sink) { [] }

  def new_configurator(history: nil)
    Pikuri::Agent::Configurator.new(agent: fake_agent, chat: fake_chat, listeners: listeners,
                                    history: history, on_close_sink: close_sink,
                                    history_replacer: ->(_) { raise 'not under test here' })
  end

  describe '#initialize' do
    it 'exposes the agent and the history it was built for' do
      history = Pikuri::Agent::History.new(messages: [])
      c = new_configurator(history: history)

      assert_same fake_agent, c.agent
      assert_same history, c.history
    end

    it 'starts with empty collections' do
      c = new_configurator
      assert_equal [], c.tools
      assert_equal [], c.sub_agent_tools
      assert_equal [], c.extensions
    end
  end

  describe '#add_tool' do
    it 'appends in declaration order' do
      c = new_configurator
      c.add_tool(:t1)
      c.add_tool(:t2)
      assert_equal %i[t1 t2], c.tools
    end

    it 'does not bleed into sub_agent_tools' do
      c = new_configurator
      c.add_tool(:t1)
      assert_equal [], c.sub_agent_tools
    end
  end

  describe '#add_sub_agent_tool' do
    it 'appends to the sub-agent pool in declaration order' do
      c = new_configurator
      c.add_sub_agent_tool(:s1)
      c.add_sub_agent_tool(:s2)
      assert_equal %i[s1 s2], c.sub_agent_tools
    end

    it 'does not bleed into the parent tool list' do
      c = new_configurator
      c.add_sub_agent_tool(:s1)
      assert_equal [], c.tools
    end
  end

  describe '#add_listener' do
    it "appends to the agent's listener list, after the ones already there" do
      c = new_configurator
      later = Pikuri::Agent::Listener::InMemoryEventList.new
      c.add_listener(later)
      event = Pikuri::Agent::Event::Cancelled.new

      listeners.on_event(event)

      assert_equal [event], recorder.events
      assert_equal [event], later.events
    end
  end

  describe '#on_close' do
    it "appends handler blocks to the agent's live sink in declaration order" do
      c = new_configurator
      a = -> { :a }
      b = -> { :b }
      c.on_close(&a)
      c.on_close(&b)
      assert_equal [a, b], close_sink
    end

    it 'raises ArgumentError without a block' do
      c = new_configurator
      assert_raises(ArgumentError) { c.on_close }
    end
  end

  describe '#add_extension' do
    # An extension that just records what it gets. Mixing the module in is
    # the canonical way to write an extension; the Configurator calls
    # #configure unconditionally, so the module's defaults stop
    # NoMethodError for omitted hooks.
    let(:extension_class) do
      Class.new do
        include Pikuri::Agent::Extension

        attr_reader :configured_with

        def configure(c)
          @configured_with = c
        end
      end
    end

    it 'calls extension.configure(self) immediately and retains the instance' do
      c = new_configurator
      ext = extension_class.new

      c.add_extension(ext)

      assert_same c, ext.configured_with
      assert_equal [ext], c.extensions
    end

    it 'raises if the extension has no #configure (the module provides a default)' do
      c = new_configurator
      ext = Object.new # no include, no methods

      assert_raises(NoMethodError) { c.add_extension(ext) }
    end

    it 'lets a later extension read what previous ones added' do
      # Source order == execution order — useful when an extension
      # wants to behave differently based on what's already wired.
      c = new_configurator
      ext1 = Class.new do
        include Pikuri::Agent::Extension
        def configure(cfg) = cfg.add_tool(:t1)
      end.new
      observed = nil
      ext2 = Class.new do
        include Pikuri::Agent::Extension
        define_method(:configure) { |cfg| observed = cfg.tools.dup }
      end.new

      c.add_extension(ext1)
      c.add_extension(ext2)

      assert_equal [:t1], observed
    end

    it 'refuses an instance already added to another agent, before configuring it again' do
      ext = extension_class.new
      first = new_configurator
      first.add_extension(ext)
      second = new_configurator

      err = assert_raises(ArgumentError) { second.add_extension(ext) }

      assert_includes err.message, 'already added to an agent'
      assert_same first, ext.configured_with
      assert_equal [], second.extensions
    end

    it 'refuses the same instance added twice to one agent' do
      c = new_configurator
      ext = extension_class.new
      c.add_extension(ext)

      assert_raises(ArgumentError) { c.add_extension(ext) }
      assert_equal [ext], c.extensions
    end

    it 'tells equal extensions apart by identity' do
      value_class = Data.define(:name) { include Pikuri::Agent::Extension }
      c = new_configurator

      c.add_extension(value_class.new(name: 'x'))
      c.add_extension(value_class.new(name: 'x'))

      assert_equal 2, c.extensions.size
    end
  end

  describe '#emit_event' do
    it 'fans gem-defined domain events (any value) out to the listener list' do
      domain_event = Data.define(:payload).new(payload: 42)

      assert_nil new_configurator.emit_event(domain_event)
      assert_equal [domain_event], recorder.events
    end
  end

  describe '#add_raw_tool' do
    it "registers the raw tool on the agent's chat, not in #tools" do
      c = new_configurator
      raw_tool = Class.new(RubyLLM::Tool)

      assert_nil c.add_raw_tool(raw_tool)
      assert_equal [raw_tool], fake_chat.tools
      assert_equal [], c.tools
    end
  end

  describe '#sub_agent_listeners' do
    it 'derives a fresh ListenerList whose shared listeners flow into the parent instances' do
      # InMemoryEventList shares by reference (a structured sink), so an
      # event emitted on the derived list lands in the parent's recorder.
      derived = new_configurator.sub_agent_listeners(id: 'researcher 0')
      event = Pikuri::Agent::Event::Cancelled.new

      derived.on_event(event)

      refute_same listeners, derived
      assert_equal [event], recorder.events
    end
  end

  describe Pikuri::Agent::Extension do
    it 'provides no-op defaults for #configure and #on_user_message' do
      ext = Class.new { include Pikuri::Agent::Extension }.new

      assert_nil ext.configure(:any_configurator)
      assert_nil ext.on_user_message('hi', [])
      assert_equal [], ext.system_prompt_snippets
    end
  end
end
