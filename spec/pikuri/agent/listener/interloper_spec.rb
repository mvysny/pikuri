# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Listener::Interloper do
  let(:fake_chat_class) do
    Class.new do
      attr_reader :after_tool_result_callbacks, :added_messages

      def initialize
        @after_tool_result_callbacks = []
        @added_messages = []
      end

      def after_tool_result(&b)
        @after_tool_result_callbacks << b
      end

      def add_message(attrs)
        @added_messages << attrs
      end

      def fire_after_tool_result
        @after_tool_result_callbacks.each { |cb| cb.call(nil) }
      end
    end
  end

  let(:fake_chat) { fake_chat_class.new }

  describe '#initialize' do
    it 'starts empty — peek is empty, pending? is false' do
      interloper = described_class.new
      assert_equal [], interloper.peek
      refute interloper.pending?
    end
  end

  describe '#attach' do
    it 'wires a single after_tool_result callback' do
      described_class.new.attach(fake_chat)
      assert_equal 1, fake_chat.after_tool_result_callbacks.size
    end
  end

  describe '#inject_user_message' do
    it 'rejects nil content' do
      assert_raises(ArgumentError) { described_class.new.inject_user_message(nil) }
    end

    it 'rejects empty content' do
      assert_raises(ArgumentError) { described_class.new.inject_user_message('') }
    end

    it 'rejects whitespace-only content' do
      assert_raises(ArgumentError) { described_class.new.inject_user_message("   \t\n") }
    end

    it 'pushes onto the queue, observable via #peek and #pending?' do
      interloper = described_class.new
      interloper.inject_user_message('hi')

      assert_equal ['hi'], interloper.peek
      assert interloper.pending?
    end

    it 'preserves FIFO order across multiple injections' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')
      interloper.inject_user_message('three')

      assert_equal %w[one two three], interloper.peek
    end

    it 'returns nil' do
      assert_nil described_class.new.inject_user_message('x')
    end
  end

  describe '#peek' do
    it 'returns a copy — mutating the result does not mutate the queue' do
      interloper = described_class.new
      interloper.inject_user_message('a')

      snapshot = interloper.peek
      snapshot << 'b'

      assert_equal ['a'], interloper.peek
    end
  end

  describe 'delivery on after_tool_result' do
    let(:listener_list) { Pikuri::Agent::Listener::InMemoryMessageList.new }
    let(:interloper) do
      i = described_class.new
      i.listener_list = listener_list
      i.attach(fake_chat)
      i
    end

    it 'is a no-op when the queue is empty' do
      interloper # build it

      fake_chat.fire_after_tool_result

      assert_empty fake_chat.added_messages
    end

    it 'appends each queued item to the chat as a user-role message, in order' do
      interloper.inject_user_message('first')
      interloper.inject_user_message('second')

      fake_chat.fire_after_tool_result

      assert_equal(
        [
          { role: :user, content: 'first' },
          { role: :user, content: 'second' }
        ],
        fake_chat.added_messages
      )
    end

    it 'emits Message::User(mid_loop_run: true) into the listener stream per item' do
      interloper.inject_user_message('hey')
      interloper.inject_user_message('also that')

      fake_chat.fire_after_tool_result

      injection_events = listener_list.events.select do |e|
        e.is_a?(Pikuri::Agent::Message::User) && e.mid_loop_run
      end
      assert_equal 2, injection_events.size
      assert_equal 'hey',      injection_events[0].content
      assert_equal 'also that', injection_events[1].content
    end

    it 'clears the queue after a successful drain' do
      interloper.inject_user_message('x')
      fake_chat.fire_after_tool_result

      refute interloper.pending?
      assert_equal [], interloper.peek
    end

    it 'survives a fire with no listener_list set (host opted out of stream emission)' do
      bare = described_class.new
      bare.attach(fake_chat)
      bare.inject_user_message('x')

      # Must not raise even though @listener_list is nil.
      fake_chat.fire_after_tool_result

      assert_equal [{ role: :user, content: 'x' }], fake_chat.added_messages
    end

    it 'drains exactly once across multiple after_tool_result fires in the same batch' do
      # Simulates the ruby_llm pattern of multiple tool calls per assistant turn:
      # after_tool_result fires once per tool call. The first fire drains the
      # queue; subsequent fires in the same batch must be no-ops.
      interloper.inject_user_message('only once')

      fake_chat.fire_after_tool_result
      fake_chat.fire_after_tool_result
      fake_chat.fire_after_tool_result

      assert_equal [{ role: :user, content: 'only once' }], fake_chat.added_messages
    end

    it 'items injected between fires are delivered on the subsequent fire' do
      interloper.inject_user_message('a')
      fake_chat.fire_after_tool_result

      interloper.inject_user_message('b')
      fake_chat.fire_after_tool_result

      assert_equal(
        [
          { role: :user, content: 'a' },
          { role: :user, content: 'b' }
        ],
        fake_chat.added_messages
      )
    end
  end

  describe 'cross-thread inject_user_message' do
    it 'a push from another thread is observed at the next after_tool_result' do
      interloper = described_class.new
      interloper.attach(fake_chat)

      Thread.new { interloper.inject_user_message('from another thread') }.join

      fake_chat.fire_after_tool_result

      assert_equal [{ role: :user, content: 'from another thread' }], fake_chat.added_messages
    end
  end

  describe '#for_sub_agent' do
    it 'returns nil so ListenerList#for_sub_agent drops it from the sub-agent' do
      assert_nil described_class.new.for_sub_agent
      assert_nil described_class.new.for_sub_agent(max_steps: 5, name: 'sub_agent 0')
    end
  end

  describe '#to_s' do
    it 'renders the bare class name when idle' do
      assert_equal 'Interloper', described_class.new.to_s
    end

    it 'renders the pending count when items are queued' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')
      assert_equal 'Interloper(2 pending)', interloper.to_s
    end
  end

  describe '#on_message' do
    it 'is a no-op for every Message variant (queue is drained only by after_tool_result)' do
      interloper = described_class.new
      interloper.inject_user_message('still here')

      [
        Pikuri::Agent::Message::User.new(content: 'turn'),
        Pikuri::Agent::Message::User.new(content: 'inject', mid_loop_run: true),
        Pikuri::Agent::Message::Assistant.new(content: 'ok'),
        Pikuri::Agent::Message::Thinking.new(content: 'hmm'),
        Pikuri::Agent::Message::ToolCall.new(name: 'echo', arguments: {}),
        Pikuri::Agent::Message::ToolResult.new(content: 'done'),
        Pikuri::Agent::Message::Cancelled.new
      ].each { |m| interloper.on_message(m) }

      # Queue untouched.
      assert_equal ['still here'], interloper.peek
    end
  end
end
