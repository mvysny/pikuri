# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ExtensionContext do
  # Bare-minimum chat stand-in: records tools registered via
  # +with_tool+, which is the only chat surface the context touches.
  let(:fake_chat_class) do
    Class.new do
      attr_reader :tools

      def initialize
        @tools = []
      end

      def with_tool(tool)
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
  let(:ctx) do
    described_class.new(agent: fake_agent, chat: fake_chat,
                        listeners: listeners, on_close_sink: close_sink)
  end

  describe '#agent' do
    it 'exposes the agent it was constructed with' do
      assert_same fake_agent, ctx.agent
    end
  end

  describe '#emit_event' do
    it 'fans the event out to the listener list' do
      event = Pikuri::Agent::Event::Assistant.new(content: 'domain event stand-in')

      ctx.emit_event(event)

      assert_equal [event], recorder.events
    end

    it 'accepts gem-defined domain events (any value, not just core Event variants)' do
      domain_event = Data.define(:payload).new(payload: 42)

      ctx.emit_event(domain_event)

      assert_equal [domain_event], recorder.events
    end

    it 'returns nil' do
      assert_nil ctx.emit_event(Pikuri::Agent::Event::Cancelled.new)
    end
  end

  describe '#add_raw_tool' do
    it "registers the raw tool on the agent's chat and returns nil" do
      raw_tool = Class.new(RubyLLM::Tool)

      assert_nil ctx.add_raw_tool(raw_tool)
      assert_equal [raw_tool], fake_chat.tools
    end
  end

  describe '#sub_agent_listeners' do
    it 'derives a fresh ListenerList via for_sub_agent, forwarding params' do
      derived = ctx.sub_agent_listeners(id: 'researcher 0')

      assert_kind_of Pikuri::Agent::ListenerList, derived
      refute_same listeners, derived
    end

    it 'keeps reference-shared listeners flowing into the parent instances' do
      # InMemoryEventList shares by reference (a structured sink), so
      # an event emitted on the derived list lands in the parent's
      # recorder — the documented aliasing semantics.
      derived = ctx.sub_agent_listeners(id: 'researcher 0')
      event = Pikuri::Agent::Event::Cancelled.new

      derived.emit(event)

      assert_equal [event], recorder.events
    end
  end

  describe '#on_close' do
    it "appends the handler to the agent's live sink and returns nil" do
      handler_ran = false

      assert_nil(ctx.on_close { handler_ran = true })
      assert_equal 1, close_sink.size

      close_sink.first.call
      assert handler_ran
    end

    it 'raises ArgumentError without a block' do
      assert_raises(ArgumentError) { ctx.on_close }
    end
  end
end
