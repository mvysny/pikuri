# frozen_string_literal: true

require 'chat_log'
require 'chat_response'
require 'tool'

RSpec.describe ChatLog do
  describe 'construction and iteration' do
    it 'starts empty' do
      log = ChatLog.new
      assert_equal 0, log.size
      assert_equal [], log.to_a
    end

    it 'preserves append order across role-specific helpers' do
      log = ChatLog.new
      log.system('be helpful')
      log.user('hello')
      log.assistant(content: 'hi there')
      assert_equal %i[system user assistant], log.map(&:role)
    end

    it 'is Enumerable' do
      log = ChatLog.new
      log.user('a')
      log.user('b')
      assert_equal %w[a b], log.map(&:content)
    end
  end

  describe '#add' do
    it 'rejects values that are not Messages' do
      log = ChatLog.new
      assert_raises(ArgumentError) { log.add('a string') }
    end
  end

  describe '#tool requires a tool_call_id' do
    it 'appends a :tool message with the given id' do
      log = ChatLog.new.tool('72°F', tool_call_id: 'call_abc')
      msg = log.first
      assert_equal :tool, msg.role
      assert_equal '72°F', msg.content
      assert_equal 'call_abc', msg.tool_call_id
    end
  end

  describe '#assistant with tool_calls' do
    let(:weather_tool) do
      Tool.new(
        name: 'get_weather',
        description: 'd',
        parameters: Tool::Parameters.build { |p| p.required_string :location, 'l' },
        execute: ->(location:) { location }
      )
    end

    it 'accepts a non-empty tool_calls array with empty content' do
      tc = ChatResponse::ToolCall.new(
        tool: weather_tool, arguments: { 'location' => 'Tokyo' }, id: 'call_1'
      )
      log = ChatLog.new.assistant(content: '', tool_calls: [tc])
      assert_equal [tc], log.first.tool_calls
    end
  end
end

RSpec.describe ChatLog::Message do
  describe 'role validation' do
    it 'rejects an unrecognized role' do
      err = assert_raises(ArgumentError) { described_class.new(role: :function, content: 'x') }
      assert_includes err.message, 'role must be one of'
    end
  end

  describe ':system and :user' do
    it 'requires a String content' do
      assert_raises(ArgumentError) { described_class.new(role: :system, content: nil) }
      assert_raises(ArgumentError) { described_class.new(role: :user, content: 42) }
    end

    it 'rejects tool_calls' do
      err = assert_raises(ArgumentError) do
        described_class.new(role: :system, content: 'x', tool_calls: [:anything])
      end
      assert_includes err.message, 'must not have tool_calls'
    end

    it 'rejects tool_call_id' do
      err = assert_raises(ArgumentError) do
        described_class.new(role: :user, content: 'x', tool_call_id: 'call_x')
      end
      assert_includes err.message, 'must not have tool_call_id'
    end
  end

  describe ':assistant' do
    it 'rejects an entirely empty turn (no content, no tool_calls)' do
      err = assert_raises(ArgumentError) { described_class.new(role: :assistant) }
      assert_includes err.message, 'non-empty content or non-empty tool_calls'
    end

    it 'rejects empty-string content with no tool_calls' do
      assert_raises(ArgumentError) { described_class.new(role: :assistant, content: '') }
    end

    it 'accepts content-only' do
      msg = described_class.new(role: :assistant, content: 'hi')
      assert_equal 'hi', msg.content
      assert_nil msg.tool_calls
    end

    it 'rejects tool_call_id' do
      err = assert_raises(ArgumentError) do
        described_class.new(role: :assistant, content: 'hi', tool_call_id: 'x')
      end
      assert_includes err.message, 'must not have tool_call_id'
    end
  end

  describe ':tool' do
    it 'requires content and tool_call_id' do
      assert_raises(ArgumentError) { described_class.new(role: :tool, content: 'x') }
      assert_raises(ArgumentError) { described_class.new(role: :tool, tool_call_id: 'call_1') }
    end

    it 'rejects an empty tool_call_id' do
      assert_raises(ArgumentError) { described_class.new(role: :tool, content: 'x', tool_call_id: '') }
    end

    it 'rejects tool_calls' do
      err = assert_raises(ArgumentError) do
        described_class.new(role: :tool, content: 'x', tool_call_id: 'c', tool_calls: [:anything])
      end
      assert_includes err.message, 'must not have tool_calls'
    end
  end
end
