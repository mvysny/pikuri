# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Agent::Listener::Terminal do
  let(:listener) { described_class.new }

  it 'prints Thinking content as dim text' do
    out = capture_stdout { listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondered')) }
    assert_includes out, 'pondered'
  end

  it 'prints Assistant content raw (Markdown as-is)' do
    out = capture_stdout { listener.on_event(Pikuri::Agent::Event::Assistant.new(content: '**hi**')) }
    assert_includes out, '**hi**'
  end

  it 'prints ToolCall as the display name and the primary argument' do
    out = capture_stdout { listener.on_event(tool_call(display_name: 'Write', argument: 'lib/foo.rb')) }
    assert_includes out, 'Write(lib/foo.rb)'
  end

  it 'prints a no-argument ToolCall bare, without empty parens' do
    out = capture_stdout { listener.on_event(tool_call(display_name: 'EnterPlanMode', argument: '')) }
    assert_includes out, 'EnterPlanMode'
    refute_includes out, '()'
  end

  it 'prints the ToolResult summary, not the observation' do
    out = capture_stdout do
      listener.on_event(tool_result(content: "a\nb\nc" * 100, summary: 'Returned 23 search results'))
    end
    assert_includes out, 'Returned 23 search results'
    refute_includes out, 'a\nb'
  end

  it 'flattens a multi-line display string to a single line' do
    out = capture_stdout { listener.on_event(tool_call(display_name: 'Write', argument: "a\n  b")) }
    assert_includes out, 'Write(a b)'
  end

  it 'defangs control bytes in display strings, which no longer pass through inspect' do
    out = capture_stdout { listener.on_event(tool_call(display_name: 'Write', argument: "ev\e[31mil")) }
    refute_includes out, "\e[31m"
  end

  it 'caps a long argument to the row' do
    out = capture_stdout { listener.on_event(tool_call(display_name: 'Bash', argument: 'x' * 5_000)) }
    assert_includes out, '…'
    refute_includes out, 'x' * 5_000
  end

  it 'caps a long summary' do
    out = capture_stdout { listener.on_event(tool_result(content: 'boom', summary: "Error: #{'x' * 5_000}")) }
    assert_includes out, '…'
    refute_includes out, 'x' * 5_000
  end

  it 'prints SystemInjected content with a marker so injected memory/context is visible' do
    out = capture_stdout do
      listener.on_event(Pikuri::Agent::Event::SystemInjected.new(content: 'recalled: lives in Brno'))
    end
    assert_includes out, '⊕'
    assert_includes out, 'recalled: lives in Brno'
  end

  it 'is silent for UserTurn events (terminal user already typed it)' do
    out = capture_stdout { listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hello?')) }
    assert_equal '', out
  end

  it 'is silent for Tokens events (TokenLog handles those)' do
    tokens = Pikuri::Agent::Event::Tokens.new(input: 10, output: 5, cached: nil,
                                              cache_creation: nil, thinking: nil, model_id: nil)
    out = capture_stdout { listener.on_event(tokens) }
    assert_equal '', out
  end

  it 'is silent for ContextCap events' do
    out = capture_stdout { listener.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 32_768)) }
    assert_equal '', out
  end

  it 'prints FallbackNotice in yellow with the reason' do
    out = capture_stdout do
      listener.on_event(Pikuri::Agent::Event::FallbackNotice.new(reason: 'budget exhausted'))
    end
    assert_includes out, 'budget exhausted'
  end

  it 'prints Cancelled notice in red' do
    out = capture_stdout { listener.on_event(Pikuri::Agent::Event::Cancelled.new) }
    assert_includes out, 'cancelled'
  end

  it 'prints a context-cleared separator on Reset' do
    out = capture_stdout { listener.on_event(Pikuri::Agent::Event::Reset.new) }
    assert_includes out, 'context cleared'
  end

  it 'renders an unrecognized (gem domain) event generically via its to_s' do
    # Stand-in for a gem domain event like Pikuri::Code::PlanModeChanged:
    # core knows nothing of the type, so it prints the event's own to_s.
    domain_event = Class.new do
      def to_s = 'plan mode: on (read-only)'
    end.new
    out = capture_stdout { listener.on_event(domain_event) }
    assert_includes out, 'plan mode: on (read-only)'
  end

  describe 'gem domain events' do
    # Stand-in for a gem's own transient event (Pikuri::Lsp::ServerProgress):
    # core knows nothing of the type and renders only its to_s.
    progress = Data.define(:text, :done) do
      include Pikuri::Agent::Event::Transient

      def to_s = text
    end

    # $stdout is a StringIO under capture_stdout, so a tty has to be asked for.
    fake_tty = Class.new(StringIO) do
      def tty? = true

      def winsize = [24, 40]
    end

    it 'defangs the text, because a to_s may carry a server\'s own words' do
      hostile = Class.new do
        def to_s = "Indexing \e[31mred\e[0m"
      end.new

      out = capture_stdout { listener.on_event(hostile) }

      refute_includes out, "\e[31m"
      assert_includes out, 'Indexing'
    end

    it 'flattens a multi-line to_s, so one event stays one line' do
      noisy = Class.new do
        def to_s = "first\n  second"
      end.new

      out = capture_stdout { listener.on_event(noisy) }

      assert_includes out, 'first second'
    end

    describe 'a transient event' do
      it 'shows only the final state when stdout is not a terminal' do
        out = capture_stdout do
          listener.on_event(progress.new(text: 'Indexing 10%', done: false))
          listener.on_event(progress.new(text: 'Indexing 90%', done: false))
          listener.on_event(progress.new(text: 'Indexing done', done: true))
        end

        refute_includes out, 'Indexing 10%'
        refute_includes out, 'Indexing 90%'
        assert_includes out, 'Indexing done'
        assert_equal 1, out.lines.length
      end

      it 'rewrites one line in place on a terminal, and retires it when done' do
        captured = fake_tty.new
        original = $stdout
        $stdout = captured
        begin
          listener.on_event(progress.new(text: 'Indexing 10%', done: false))
          listener.on_event(progress.new(text: 'Indexing 90%', done: false))
          # StringIO#string hands back the live buffer, so snapshot it.
          mid = captured.string.dup
          listener.on_event(progress.new(text: 'Indexing done', done: true))
        ensure
          $stdout = original
        end

        assert_includes mid, 'Indexing 10%'
        assert_includes mid, 'Indexing 90%'
        assert_equal 1, mid.scan("\r\e[K").length, 'the second update erases the first'
        refute_includes mid, "\n", 'a bar that ended its line could not be rewritten'
        assert_equal 2, captured.string.scan("\r\e[K").length, 'the final state takes the line down'
        refute_includes captured.string, 'Indexing done'
      end

      it 'cuts the line to the window, so a wrapped bar cannot outlive its erase' do
        captured = fake_tty.new
        original = $stdout
        $stdout = captured
        begin
          listener.on_event(progress.new(text: 'x' * 200, done: false))
        ensure
          $stdout = original
        end

        assert captured.string.length < 200, captured.string.length
        assert_includes captured.string, '…'
      end

      it 'clears the bar before ordinary output lands, rather than printing into it' do
        captured = fake_tty.new
        original = $stdout
        $stdout = captured
        begin
          listener.on_event(progress.new(text: 'Indexing 10%', done: false))
          listener.on_event(tool_result(content: '42', summary: 'Returned 2 bytes'))
        ensure
          $stdout = original
        end

        assert_match(/\r\e\[K.*Returned 2 bytes/m, captured.string)
      end
    end
  end

  describe '#to_s' do
    it 'renders as "Terminal"' do
      assert_equal 'Terminal', described_class.new.to_s
    end

    it 'renders the padding suffix when padding is non-zero' do
      assert_equal 'Terminal(padding=2)', described_class.new(padding: 2).to_s
    end

    it 'renders a streaming marker when streaming: true' do
      assert_equal 'Terminal(streaming)', described_class.new(streaming: true).to_s
    end

    it 'renders both knobs when both are set' do
      assert_equal 'Terminal(padding=2, streaming)',
                   described_class.new(padding: 2, streaming: true).to_s
    end
  end

  describe 'padding' do
    let(:padded) { described_class.new(padding: 2) }

    it 'prepends N spaces to every rendered line of Assistant content' do
      content = "line one\nline two"
      out = capture_stdout { padded.on_event(Pikuri::Agent::Event::Assistant.new(content: content)) }
      assert_equal "  line one\n  line two\n", out
    end

    it 'prepends N spaces to ToolCall, ToolResult, Thinking, and FallbackNotice' do
      out = capture_stdout do
        padded.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondered'))
        padded.on_event(tool_call)
        padded.on_event(tool_result)
        padded.on_event(Pikuri::Agent::Event::FallbackNotice.new(reason: 'budget exhausted'))
      end
      out.each_line do |line|
        assert line.start_with?('  '), "expected line to start with 2 spaces, got: #{line.inspect}"
      end
    end

    it 'does not add a trailing padded blank line when input ends with newline' do
      # each_line splits "hi\n" into ["hi\n"], not ["hi\n", ""], so the
      # joined output is "  hi\n" — no stray "  \n" tacked on.
      out = capture_stdout { padded.on_event(Pikuri::Agent::Event::Assistant.new(content: "hi\n")) }
      assert_equal "  hi\n", out
    end

    it 'is a no-op when padding is 0 (default)' do
      content = "line one\nline two"
      out = capture_stdout { listener.on_event(Pikuri::Agent::Event::Assistant.new(content: content)) }
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
      derived = described_class.new.for_sub_agent(id: 'sub_agent 0', anything_else: :nope)
      assert_equal described_class::SUB_AGENT_PADDING, derived.padding
    end

    it 'returns a different instance (so the parent Terminal is not mutated)' do
      original = described_class.new
      derived  = original.for_sub_agent
      refute_same original, derived
      assert_equal 0, original.padding
    end

    it 'inherits the streaming flag so the agent tree renders consistently' do
      streaming_derived     = described_class.new(streaming: true).for_sub_agent
      non_streaming_derived = described_class.new(streaming: false).for_sub_agent
      assert streaming_derived.streaming
      refute non_streaming_derived.streaming
    end
  end

  describe 'streaming mode' do
    let(:streaming_listener) { described_class.new(streaming: true) }

    it 'prints ThinkingDelta fragments live with no trailing newline' do
      out = capture_stdout do
        streaming_listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'hel'))
        streaming_listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'lo'))
      end
      assert_includes out, 'hel'
      assert_includes out, 'lo'
      # Two fragments, both grey-colored, neither closing the line —
      # the assembled output must NOT contain a newline between them.
      refute_match(/hel.*\n.*lo/m, out)
    end

    it 'prints AssistantDelta fragments raw with no trailing newline' do
      out = capture_stdout do
        streaming_listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: '**hi**'))
      end
      assert_includes out, '**hi**'
      refute out.end_with?("\n"), 'streaming fragment should not append a newline'
    end

    it 'is silent for ThinkingDelta / AssistantDelta in non-streaming mode (default)' do
      out = capture_stdout do
        listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'hel'))
        listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'lo'))
      end
      assert_equal '', out
    end

    it 'prints exactly one terminator newline (no content) on the Thinking bookend in streaming mode' do
      out = capture_stdout do
        streaming_listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'reasoning text'))
      end
      refute_includes out, 'reasoning text', 'streaming Thinking bookend must NOT re-render the content'
      assert_equal "\n", out
    end

    it 'prints exactly one terminator newline (no content) on the Assistant bookend in streaming mode' do
      out = capture_stdout do
        streaming_listener.on_event(Pikuri::Agent::Event::Assistant.new(content: '**hi**'))
      end
      refute_includes out, '**hi**', 'streaming Assistant bookend must NOT re-render the content'
      assert_equal "\n", out
    end

    it 'pads the start of every line of a streamed fragment when padding is non-zero' do
      padded_stream = described_class.new(padding: 2, streaming: true)
      out = capture_stdout do
        # First fragment starts at line-start → padded; mid-fragment newline
        # is followed by more content → padded again; trailing chars on the
        # current line are NOT re-padded.
        padded_stream.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: "foo\nbar"))
        padded_stream.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'baz'))
      end
      assert_equal "  foo\n  barbaz", out
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

  def tool_call(display_name: 'Echo', argument: 'hi', name: 'echo', arguments: { 'text' => 'hi' })
    Pikuri::Agent::Event::ToolCall.new(tool_call_id: 'c1', name: name, arguments: arguments,
                                       display_name: display_name, argument: argument)
  end

  def tool_result(content: '42', summary: 'Returned 2 bytes', name: 'echo')
    Pikuri::Agent::Event::ToolResult.new(tool_call_id: 'c1', name: name, content: content, summary: summary)
  end
end
