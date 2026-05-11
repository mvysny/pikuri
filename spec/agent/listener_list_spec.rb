# frozen_string_literal: true

require 'agent'

RSpec.describe Agent::ListenerList do
  # Minimal stand-in for +RubyLLM::Chat+ that records what listeners
  # register on it, so we can assert the list fanned +attach+ out.
  let(:fake_chat_class) do
    Class.new do
      attr_reader :hooks

      def initialize
        @hooks = Hash.new { |h, k| h[k] = [] }
      end

      def after_message(&b);     @hooks[:after_message] << b;     self; end
      def before_tool_call(&b);  @hooks[:before_tool_call] << b;  self; end
      def after_tool_result(&b); @hooks[:after_tool_result] << b; self; end
    end
  end

  let(:fake_chat) { fake_chat_class.new }
  let(:recorder)  { Agent::Listener::InMemoryList.new }

  describe '#attach' do
    it 'fans attach out to every listener' do
      list = described_class.new([recorder, Agent::Listener::StepLimit.new(max: 3)])
      list.attach(fake_chat)

      # MessageListener subclass registers 3 hooks; StepLimit adds 1
      # before_tool_call.
      assert_equal 1, fake_chat.hooks[:after_message].size
      assert_equal 2, fake_chat.hooks[:before_tool_call].size
      assert_equal 1, fake_chat.hooks[:after_tool_result].size
    end
  end

  describe '#on_message' do
    it 'fans on_message out to every listener' do
      other = Agent::Listener::InMemoryList.new
      list = described_class.new([recorder, other])

      msg = Agent::Message::User.new(content: 'hi')
      list.on_message(msg)

      assert_equal [msg], recorder.events
      assert_equal [msg], other.events
    end
  end

  describe '#with_max_steps' do
    let(:terminal)   { Agent::Listener::Terminal.new }
    let(:existing)   { Agent::Listener::StepLimit.new(max: 99) }

    it 'replaces an existing StepLimit with a fresh one capped at the new value' do
      list = described_class.new([terminal, recorder, existing])

      derived = list.with_max_steps(5)

      # The derived list renders the swap visibly.
      assert_equal '[Terminal, InMemoryList, StepLimit(max=5)]', derived.to_s

      # Original is untouched.
      assert_equal '[Terminal, InMemoryList, StepLimit(max=99)]', list.to_s
    end

    it 'appends a fresh StepLimit when none was in the list' do
      list = described_class.new([terminal, recorder])

      derived = list.with_max_steps(7)

      assert_equal '[Terminal, InMemoryList, StepLimit(max=7)]', derived.to_s
    end

    it 'strips every StepLimit when max_steps is nil' do
      list = described_class.new([terminal, recorder, existing])

      derived = list.with_max_steps(nil)

      assert_equal '[Terminal, InMemoryList]', derived.to_s
    end

    it 'preserves the non-StepLimit listener identities (output continues to flow)' do
      list = described_class.new([recorder, existing])

      derived = list.with_max_steps(4)
      derived.on_message(Agent::Message::User.new(content: 'forked'))

      # The same InMemoryList instance is referenced from the derived list.
      assert_equal [Agent::Message::User.new(content: 'forked')], recorder.events
    end

    it 'requires max_steps — no silent default' do
      list = described_class.new([recorder, existing])

      assert_raises(ArgumentError) { list.with_max_steps }
    end

    it 'gives the derived list a fresh StepLimit instance even when the cap is unchanged' do
      list = described_class.new([recorder, Agent::Listener::StepLimit.new(max: 4)])

      derived = list.with_max_steps(4)

      # The derived list's StepLimit is wired into a new chat without
      # sharing the parent's mutable counter — exercise via attach +
      # repeated before_tool_call from below the parent's cap, which
      # must not raise on the derived chat.
      parent_chat  = fake_chat_class.new
      derived_chat = fake_chat_class.new
      list.attach(parent_chat)
      derived.attach(derived_chat)

      tc = RubyLLM::ToolCall.new(id: 'c', name: 't', arguments: {})

      # Burn 3 tool calls on the parent — under its cap.
      3.times { parent_chat.hooks[:before_tool_call].each { |cb| cb.call(tc) } }

      # The derived chat has not seen any tool calls yet. Three of
      # them must land without raising; if the StepLimit instance
      # were shared, the 4th would already have tripped.
      3.times { derived_chat.hooks[:before_tool_call].each { |cb| cb.call(tc) } }
    end
  end

  describe '#with_zero_tokens' do
    let(:terminal) { Agent::Listener::Terminal.new }

    it 'replaces every TokenLog with a fresh instance' do
      original_log = Agent::Listener::TokenLog.new
      list = described_class.new([terminal, original_log])

      derived = list.with_zero_tokens

      derived_log = derived.instance_variable_get(:@listeners).find do |l|
        l.is_a?(Agent::Listener::TokenLog)
      end
      refute_nil derived_log
      refute_same original_log, derived_log
    end

    it 'preserves non-TokenLog listener identities so output keeps flowing' do
      list = described_class.new([recorder, Agent::Listener::TokenLog.new])

      derived = list.with_zero_tokens
      derived.on_message(Agent::Message::User.new(content: 'forked'))

      assert_equal [Agent::Message::User.new(content: 'forked')], recorder.events
    end

    it 'leaves the original list untouched' do
      original_log = Agent::Listener::TokenLog.new
      list = described_class.new([terminal, original_log])

      list.with_zero_tokens

      # Same instance still in the original list.
      still_there = list.instance_variable_get(:@listeners).find { |l| l.is_a?(Agent::Listener::TokenLog) }
      assert_same original_log, still_there
    end

    it 'is a copy-only no-op when no TokenLog is present' do
      list = described_class.new([terminal, recorder])

      derived = list.with_zero_tokens

      assert_equal '[Terminal, InMemoryList]', derived.to_s
      refute_same list, derived
    end
  end

  describe '#context_window_cap=' do
    let(:terminal) { Agent::Listener::Terminal.new }

    it 'sets the cap on every TokenLog in the list' do
      log_a = Agent::Listener::TokenLog.new
      log_b = Agent::Listener::TokenLog.new
      list = described_class.new([terminal, log_a, recorder, log_b])

      list.context_window_cap = 32_768

      assert_equal 32_768, log_a.context_window_cap
      assert_equal 32_768, log_b.context_window_cap
    end

    it 'leaves non-TokenLog listeners alone — no respond_to? mismatch' do
      log = Agent::Listener::TokenLog.new
      list = described_class.new([terminal, recorder, log])

      # Should not raise on Terminal/InMemoryList; only TokenLog gets the cap.
      list.context_window_cap = 4_096

      assert_equal 4_096, log.context_window_cap
      refute_respond_to terminal, :context_window_cap
      refute_respond_to recorder, :context_window_cap
    end

    it 'accepts nil so callers without a resolved cap can still wire it through' do
      log = Agent::Listener::TokenLog.new
      log.context_window_cap = 16_000
      list = described_class.new([log])

      list.context_window_cap = nil

      assert_nil log.context_window_cap
    end
  end

  describe '#to_s' do
    it 'renders the bracket-and-comma listener label' do
      list = described_class.new([
                                   Agent::Listener::Terminal.new,
                                   Agent::Listener::StepLimit.new(max: 20)
                                 ])

      assert_equal '[Terminal, StepLimit(max=20)]', list.to_s
    end
  end
end
