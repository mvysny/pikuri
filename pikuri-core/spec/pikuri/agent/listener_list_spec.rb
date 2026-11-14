# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ListenerList do
  let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }

  describe '#on_event' do
    it 'fans every event out to every listener, in registration order' do
      other = Pikuri::Agent::Listener::InMemoryEventList.new
      list = described_class.new([recorder, other])

      event = Pikuri::Agent::Event::UserTurn.new(content: 'hi')
      list.on_event(event)

      assert_equal [event], recorder.events
      assert_equal [event], other.events
    end

    it 'fans through a nested list, which is itself a listener' do
      inner = described_class.new([recorder])
      outer = described_class.new([inner])

      event = Pikuri::Agent::Event::UserTurn.new(content: 'hi')
      outer.on_event(event)

      assert_kind_of Pikuri::Agent::Listener::Base, inner
      assert_equal [event], recorder.events
    end

    it 'works with no listeners — no raise, no observable effect' do
      list = described_class.new([])
      list.on_event(Pikuri::Agent::Event::Assistant.new(content: 'unobserved'))
    end
  end

  describe '#for_sub_agent' do
    it 'forwards to each listener that defines for_sub_agent and keeps the rest by reference' do
      terminal  = Pikuri::Agent::Listener::Terminal.new
      token_log = Pikuri::Agent::Listener::TokenLog.new
      list = described_class.new([terminal, recorder, token_log])

      derived = list.for_sub_agent(id: 'sub_agent 0')

      derived_listeners = derived.instance_variable_get(:@listeners)
      derived_terminal  = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::Terminal) }
      derived_recorder  = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::InMemoryEventList) }
      derived_token_log = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }

      # Listeners with for_sub_agent: fresh instances.
      refute_same terminal,  derived_terminal
      refute_same token_log, derived_token_log

      # Listener without for_sub_agent: passed by reference so structured
      # capture continues to flow into the parent's instance.
      assert_same recorder, derived_recorder
    end

    it "applies each listener's own sub-agent semantics (Terminal padding, TokenLog id+zero)" do
      list = described_class.new([
                                   Pikuri::Agent::Listener::Terminal.new,
                                   Pikuri::Agent::Listener::TokenLog.new
                                 ])

      derived = list.for_sub_agent(id: 'sub_agent 0')

      derived_listeners = derived.instance_variable_get(:@listeners)
      derived_terminal  = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::Terminal) }
      derived_token_log = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }

      assert_equal Pikuri::Agent::Listener::Terminal::SUB_AGENT_PADDING, derived_terminal.padding
      assert_equal 'sub_agent 0', derived_token_log.id
      assert_equal 0, derived_token_log.context_window_size
    end

    it 'leaves the original list untouched' do
      original_token_log = Pikuri::Agent::Listener::TokenLog.new
      original_terminal  = Pikuri::Agent::Listener::Terminal.new
      list = described_class.new([original_terminal, original_token_log])

      list.for_sub_agent(id: 'sub_agent 0')

      still_there = list.instance_variable_get(:@listeners)
      assert_same original_terminal,  still_there.first
      assert_same original_token_log, still_there.last
      assert_equal 0, original_terminal.padding
    end

    it 'works with no params — listeners fall back to their own defaults' do
      list = described_class.new([Pikuri::Agent::Listener::TokenLog.new, recorder])

      derived = list.for_sub_agent

      # TokenLog defaults its id to ''; recorder (no hook) shared by reference.
      derived_listeners = derived.instance_variable_get(:@listeners)
      derived_token_log = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }
      assert_equal '', derived_token_log.id
      assert_same recorder, derived_listeners.last
    end

    it 'recurses into a nested list' do
      token_log = Pikuri::Agent::Listener::TokenLog.new
      outer = described_class.new([described_class.new([token_log])])

      derived_inner = outer.for_sub_agent(id: 'sub_agent 0').instance_variable_get(:@listeners).first
      derived_token_log = derived_inner.instance_variable_get(:@listeners).first

      assert_kind_of described_class, derived_inner
      assert_equal 'sub_agent 0', derived_token_log.id
    end

    it 'is a copy-only no-op when no listener defines for_sub_agent' do
      list = described_class.new([recorder])

      derived = list.for_sub_agent

      refute_same list, derived
      assert_same recorder, derived.instance_variable_get(:@listeners).first
    end

    it 'compacts nil returns out of the derived list — a listener can opt out of sub-agent propagation' do
      # Stand-in listener whose for_sub_agent returns nil — the opt-out
      # convention available to any future listener that should not
      # propagate to children.
      optout_class = Class.new(Pikuri::Agent::Listener::Base) do
        def for_sub_agent(**) = nil
        def to_s = 'Optout'
      end

      list = described_class.new([recorder, optout_class.new])

      derived = list.for_sub_agent(id: 'sub_agent 0')

      assert_equal [recorder], derived.instance_variable_get(:@listeners)
    end
  end

  describe '#to_s' do
    it 'renders the bracket-and-comma listener label' do
      list = described_class.new([
                                   Pikuri::Agent::Listener::Terminal.new,
                                   Pikuri::Agent::Listener::TokenLog.new
                                 ])

      assert_equal '[Terminal, TokenLog(ctx=0.0k)]', list.to_s
    end
  end
end
