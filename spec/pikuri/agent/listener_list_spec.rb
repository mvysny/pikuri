# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ListenerList do
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
  let(:recorder)  { Pikuri::Agent::Listener::InMemoryMessageList.new }

  describe '#attach' do
    it 'fans attach out to every listener' do
      list = described_class.new([recorder, Pikuri::Agent::Listener::StepLimit.new(max: 3)])
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
      other = Pikuri::Agent::Listener::InMemoryMessageList.new
      list = described_class.new([recorder, other])

      msg = Pikuri::Agent::Message::User.new(content: 'hi')
      list.on_message(msg)

      assert_equal [msg], recorder.events
      assert_equal [msg], other.events
    end
  end

  describe '#for_sub_agent' do
    it 'forwards to each listener that defines for_sub_agent and keeps the rest by reference' do
      terminal      = Pikuri::Agent::Listener::Terminal.new
      token_log     = Pikuri::Agent::Listener::TokenLog.new
      step_limit    = Pikuri::Agent::Listener::StepLimit.new(max: 99)
      list = described_class.new([terminal, recorder, token_log, step_limit])

      derived = list.for_sub_agent(max_steps: 5)

      derived_listeners = derived.instance_variable_get(:@listeners)
      derived_terminal  = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::Terminal) }
      derived_recorder  = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::InMemoryMessageList) }
      derived_token_log = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }
      derived_step      = derived_listeners.find { |l| l.is_a?(Pikuri::Agent::Listener::StepLimit) }

      # Listeners with for_sub_agent: fresh instances.
      refute_same terminal,   derived_terminal
      refute_same token_log,  derived_token_log
      refute_same step_limit, derived_step

      # Listener without for_sub_agent: passed by reference so structured
      # capture continues to flow into the parent's instance.
      assert_same recorder, derived_recorder
    end

    it "applies each listener's own sub-agent semantics (Terminal padding, StepLimit cap)" do
      list = described_class.new([
                                   Pikuri::Agent::Listener::Terminal.new,
                                   Pikuri::Agent::Listener::StepLimit.new(max: 99)
                                 ])

      derived = list.for_sub_agent(max_steps: 5)

      # Terminal: SUB_AGENT_PADDING; StepLimit: caller-supplied cap.
      assert_equal "[Terminal(padding=#{Pikuri::Agent::Listener::Terminal::SUB_AGENT_PADDING}), StepLimit(max=5)]",
                   derived.to_s
    end

    it 'leaves the original list untouched' do
      original_token_log = Pikuri::Agent::Listener::TokenLog.new
      original_terminal  = Pikuri::Agent::Listener::Terminal.new
      list = described_class.new([original_terminal, original_token_log])

      list.for_sub_agent(max_steps: 5)

      still_there_tl = list.instance_variable_get(:@listeners).find { |l| l.is_a?(Pikuri::Agent::Listener::TokenLog) }
      still_there_t  = list.instance_variable_get(:@listeners).find { |l| l.is_a?(Pikuri::Agent::Listener::Terminal) }
      assert_same original_token_log, still_there_tl
      assert_same original_terminal,  still_there_t
      assert_equal 0, original_terminal.padding
    end

    it 'works with no params — listeners fall back to their own defaults' do
      list = described_class.new([Pikuri::Agent::Listener::StepLimit.new(max: 4), recorder])

      derived = list.for_sub_agent

      # StepLimit inherits the parent's cap when max_steps: is absent;
      # the listener without a hook (InMemoryMessageList) is preserved.
      assert_equal '[StepLimit(max=4), InMemoryMessageList]', derived.to_s
    end

    it 'is a copy-only no-op when no listener defines for_sub_agent' do
      list = described_class.new([recorder])

      derived = list.for_sub_agent

      assert_equal '[InMemoryMessageList]', derived.to_s
      refute_same list, derived
      assert_same recorder, derived.instance_variable_get(:@listeners).first
    end
  end

  describe '#context_window_cap=' do
    let(:terminal) { Pikuri::Agent::Listener::Terminal.new }

    it 'sets the cap on every TokenLog in the list' do
      log_a = Pikuri::Agent::Listener::TokenLog.new
      log_b = Pikuri::Agent::Listener::TokenLog.new
      list = described_class.new([terminal, log_a, recorder, log_b])

      list.context_window_cap = 32_768

      assert_equal 32_768, log_a.context_window_cap
      assert_equal 32_768, log_b.context_window_cap
    end

    it 'leaves non-TokenLog listeners alone — no respond_to? mismatch' do
      log = Pikuri::Agent::Listener::TokenLog.new
      list = described_class.new([terminal, recorder, log])

      # Should not raise on Terminal/InMemoryMessageList; only TokenLog gets the cap.
      list.context_window_cap = 4_096

      assert_equal 4_096, log.context_window_cap
      refute_respond_to terminal, :context_window_cap
      refute_respond_to recorder, :context_window_cap
    end

    it 'accepts nil so callers without a resolved cap can still wire it through' do
      log = Pikuri::Agent::Listener::TokenLog.new
      log.context_window_cap = 16_000
      list = described_class.new([log])

      list.context_window_cap = nil

      assert_nil log.context_window_cap
    end
  end

  describe '#to_s' do
    it 'renders the bracket-and-comma listener label' do
      list = described_class.new([
                                   Pikuri::Agent::Listener::Terminal.new,
                                   Pikuri::Agent::Listener::StepLimit.new(max: 20)
                                 ])

      assert_equal '[Terminal, StepLimit(max=20)]', list.to_s
    end
  end
end
