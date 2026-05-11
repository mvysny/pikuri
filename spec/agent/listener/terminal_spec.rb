# frozen_string_literal: true

require 'agent'
require 'stringio'

RSpec.describe Agent::Listener::Terminal do
  let(:listener) { described_class.new }

  before do
    # TTY::Markdown.parse calls ioctl on $stdout to detect terminal
    # width, which StringIO does not support — swap it for a
    # passthrough while the spec runs.
    @original_md_parse = TTY::Markdown.method(:parse)
    TTY::Markdown.define_singleton_method(:parse) { |text, **| text }
  end

  after do
    original = @original_md_parse
    TTY::Markdown.define_singleton_method(:parse) { |*a, **k| original.call(*a, **k) }
  end

  it 'prints Thinking content as dim text' do
    out = capture_stdout { listener.on_message(Agent::Message::Thinking.new(content: 'pondered')) }
    assert_includes out, 'pondered'
  end

  it 'prints Assistant content as Markdown' do
    out = capture_stdout { listener.on_message(Agent::Message::Assistant.new(content: '**hi**')) }
    assert_includes out, 'hi'
  end

  it 'prints ToolCall with name and arguments' do
    out = capture_stdout do
      listener.on_message(Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }))
    end
    assert_includes out, 'echo'
    assert_includes out, 'text='
  end

  it 'prints ToolResult with its content' do
    out = capture_stdout { listener.on_message(Agent::Message::ToolResult.new(content: '42')) }
    assert_includes out, '42'
  end

  it 'is silent for User messages (terminal user already typed it)' do
    out = capture_stdout { listener.on_message(Agent::Message::User.new(content: 'hello?')) }
    assert_equal '', out
  end

  describe '#to_s' do
    it 'renders as "Terminal"' do
      assert_equal 'Terminal', described_class.new.to_s
    end
  end

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end
end
