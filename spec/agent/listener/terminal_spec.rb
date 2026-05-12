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

  it 'flattens whitespace in ToolResult content to a single line' do
    content = "line one\n  line two\n\n\tline three"
    out = capture_stdout { listener.on_message(Agent::Message::ToolResult.new(content: content)) }
    assert_includes out, 'line one line two line three'
    refute_includes out, "\n  line two"
  end

  it 'truncates long ToolResult content and reports the original byte count' do
    long_content = 'x' * 5_000
    out = capture_stdout { listener.on_message(Agent::Message::ToolResult.new(content: long_content)) }
    assert_includes out, '…'
    assert_includes out, '5000 bytes total'
    refute_includes out, 'x' * 5_000
  end

  it 'leaves short ToolResult content untouched (no truncation marker)' do
    out = capture_stdout { listener.on_message(Agent::Message::ToolResult.new(content: 'hello')) }
    assert_includes out, 'hello'
    refute_includes out, '…'
    refute_includes out, 'bytes total'
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

  describe 'Markdown render failure' do
    let(:log_io) { StringIO.new }

    around do |example|
      original_io = Pikuri.log_io
      Pikuri.log_io = log_io
      begin
        example.run
      ensure
        Pikuri.log_io = original_io
      end
    end

    # Outer +before+ stubs parse to a passthrough; this nested +before+
    # runs after it and replaces the stub with one that raises the same
    # kind of error tty-markdown / strings surface on ANSI-in-table
    # edge cases. The outer +after+ restores the original method either
    # way.
    before do
      TTY::Markdown.define_singleton_method(:parse) { |_text, **| raise IndexError, 'boom' }
    end

    it 'falls back to the raw content and warns through the Terminal logger' do
      out = capture_stdout { listener.on_message(Agent::Message::Assistant.new(content: '**hi**')) }
      assert_includes out, '**hi**'
      assert_includes log_io.string, 'WARN -- Terminal'
      assert_includes log_io.string, 'IndexError'
      assert_includes log_io.string, 'boom'
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
