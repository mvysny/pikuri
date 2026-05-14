# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Agent::Listener::Terminal do
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
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::Thinking.new(content: 'pondered')) }
    assert_includes out, 'pondered'
  end

  it 'prints Assistant content as Markdown' do
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::Assistant.new(content: '**hi**')) }
    assert_includes out, 'hi'
  end

  it 'prints ToolCall with name and arguments' do
    out = capture_stdout do
      listener.on_message(Pikuri::Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }))
    end
    assert_includes out, 'echo'
    assert_includes out, 'text='
  end

  it 'prints ToolResult with its content' do
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::ToolResult.new(content: '42')) }
    assert_includes out, '42'
  end

  it 'flattens whitespace in ToolResult content to a single line' do
    content = "line one\n  line two\n\n\tline three"
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::ToolResult.new(content: content)) }
    assert_includes out, 'line one line two line three'
    refute_includes out, "\n  line two"
  end

  it 'truncates long ToolResult content and reports the original byte count' do
    long_content = 'x' * 5_000
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::ToolResult.new(content: long_content)) }
    assert_includes out, '…'
    assert_includes out, '5000 bytes total'
    refute_includes out, 'x' * 5_000
  end

  it 'leaves short ToolResult content untouched (no truncation marker)' do
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::ToolResult.new(content: 'hello')) }
    assert_includes out, 'hello'
    refute_includes out, '…'
    refute_includes out, 'bytes total'
  end

  it 'is silent for User messages (terminal user already typed it)' do
    out = capture_stdout { listener.on_message(Pikuri::Agent::Message::User.new(content: 'hello?')) }
    assert_equal '', out
  end

  describe '#to_s' do
    it 'renders as "Terminal"' do
      assert_equal 'Terminal', described_class.new.to_s
    end

    it 'renders the padding suffix when padding is non-zero' do
      assert_equal 'Terminal(padding=2)', described_class.new(padding: 2).to_s
    end
  end

  describe 'padding' do
    let(:padded) { described_class.new(padding: 2) }

    it 'prepends N spaces to every rendered line of Assistant content' do
      content = "line one\nline two"
      out = capture_stdout { padded.on_message(Pikuri::Agent::Message::Assistant.new(content: content)) }
      assert_equal "  line one\n  line two\n", out
    end

    it 'prepends N spaces to ToolCall, ToolResult, Thinking, and FallbackNotice' do
      out = capture_stdout do
        padded.on_message(Pikuri::Agent::Message::Thinking.new(content: 'pondered'))
        padded.on_message(Pikuri::Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }))
        padded.on_message(Pikuri::Agent::Message::ToolResult.new(content: '42'))
        padded.on_message(Pikuri::Agent::Message::FallbackNotice.new(reason: 'budget exhausted'))
      end
      out.each_line do |line|
        assert line.start_with?('  '), "expected line to start with 2 spaces, got: #{line.inspect}"
      end
    end

    it 'does not add a trailing padded blank line when input ends with newline' do
      # each_line splits "hi\n" into ["hi\n"], not ["hi\n", ""], so the
      # joined output is "  hi\n" — no stray "  \n" tacked on.
      out = capture_stdout { padded.on_message(Pikuri::Agent::Message::Assistant.new(content: "hi\n")) }
      assert_equal "  hi\n", out
    end

    it 'is a no-op when padding is 0 (default)' do
      content = "line one\nline two"
      out = capture_stdout { listener.on_message(Pikuri::Agent::Message::Assistant.new(content: content)) }
      assert_equal "line one\nline two\n", out
    end

    it 'exposes the current padding via #padding' do
      assert_equal 0, described_class.new.padding
      assert_equal 4, described_class.new(padding: 4).padding
    end
  end

  describe '#for_sub_agent' do
    it 'returns a fresh Terminal at SUB_AGENT_PADDING regardless of receiver padding' do
      derived = described_class.new(padding: 0).for_sub_agent
      assert_equal described_class::SUB_AGENT_PADDING, derived.padding

      # Absolute, not additive — a parent that's already padded (shouldn't
      # happen given recursion is blocked, but the contract is "set this
      # knob") still hands back the standard sub-agent padding.
      from_padded = described_class.new(padding: 7).for_sub_agent
      assert_equal described_class::SUB_AGENT_PADDING, from_padded.padding
    end

    it 'ignores unrelated params forwarded by ListenerList#for_sub_agent' do
      derived = described_class.new.for_sub_agent(max_steps: 5, anything_else: :nope)
      assert_equal described_class::SUB_AGENT_PADDING, derived.padding
    end

    it 'returns a different instance (so the parent Terminal is not mutated)' do
      original = described_class.new
      derived  = original.for_sub_agent
      refute_same original, derived
      assert_equal 0, original.padding
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
      out = capture_stdout { listener.on_message(Pikuri::Agent::Message::Assistant.new(content: '**hi**')) }
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
