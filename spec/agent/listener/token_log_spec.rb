# frozen_string_literal: true

require 'agent'
require 'stringio'

RSpec.describe Agent::Listener::TokenLog do
  # Capture-buffer pattern: swap +Pikuri.log_io+ for a +StringIO+, run
  # the listener, then read what was logged. Restore the original IO
  # in +after+. Same trick the +Engines+ logging specs use.
  let(:buf) { StringIO.new }

  before do
    @original_io = Pikuri.log_io
    Pikuri.log_io = buf
    # The logger level is captured at +logger_for+ time, but since
    # +PIKURI_LOG+ isn't set in CI, it defaults to INFO — exactly the
    # level +TokenLog+ writes at. No level fiddling needed.
  end

  after { Pikuri.log_io = @original_io }

  # Build a Tokens value with the given fields, defaulting the
  # uninteresting ones to zero so each test only states what matters.
  def tokens(input: 0, output: 0, cached: 0, cache_creation: 0, thinking: 0, model_id: nil)
    Agent::Tokens.new(
      input: input, output: output, cached: cached, cache_creation: cache_creation,
      thinking: thinking, model_id: model_id
    )
  end

  describe '#on_tokens' do
    let(:listener) { described_class.new }

    it 'logs one info line per emission, summing per-turn deltas but never the context size' do
      # input is already cumulative per turn (the whole prompt sent
      # this round), so the session: portion deliberately omits it.
      # output IS a per-turn delta, so it sums.
      listener.on_tokens(tokens(input: 10_240, output: 1024))
      listener.on_tokens(tokens(input: 20_480, output: 2048))

      lines = buf.string.lines
      assert_equal 2, lines.size
      assert_includes lines[0], 'msg #1: ctx=10.0k out=1.0k | session: out=1.0k'
      assert_includes lines[1], 'msg #2: ctx=20.0k out=2.0k | session: out=3.0k'
      lines.each do |l|
        refute_match(/session:[^|\n]*(ctx|in)=/, l,
                     'session: must not carry the cumulative-input snapshot — summing it would double-count')
      end
    end

    it 'omits thinking and cached from the line when they are zero' do
      listener.on_tokens(tokens(input: 10_240, output: 1024))

      line = buf.string.lines.first
      refute_includes line, 'thinking='
      refute_includes line, 'cached='
    end

    it 'includes thinking and cached fields when non-zero' do
      listener.on_tokens(tokens(input: 10_240, output: 1024, thinking: 5120, cached: 8192))

      line = buf.string.lines.first
      assert_includes line, 'thinking=5.0k'
      assert_includes line, 'cached=8.0k'
    end

    it 'treats nil token fields as zero so providers that report nothing still log a line' do
      listener.on_tokens(Agent::Tokens.new(
                           input: nil, output: nil, cached: nil, cache_creation: nil,
                           thinking: nil, model_id: nil
                         ))

      line = buf.string.lines.first
      assert_includes line, 'msg #1: ctx=0.0k out=0.0k | session: out=0.0k'
    end
  end

  describe '#context_window_size' do
    it 'is zero before any tokens have been seen' do
      assert_equal 0, described_class.new.context_window_size
    end

    it 'reflects the LATEST input value, not a sum and not the max' do
      listener = described_class.new

      listener.on_tokens(tokens(input: 10_000))
      listener.on_tokens(tokens(input: 15_000))
      # Latest could legitimately be smaller than the previous max
      # if ruby_llm ever pruned messages between turns.
      listener.on_tokens(tokens(input: 12_000))

      assert_equal 12_000, listener.context_window_size
    end

    it 'treats nil input as zero' do
      listener = described_class.new
      listener.on_tokens(Agent::Tokens.new(
                           input: nil, output: 10, cached: nil, cache_creation: nil,
                           thinking: nil, model_id: nil
                         ))

      assert_equal 0, listener.context_window_size
    end
  end

  describe '#on_message' do
    it 'does nothing — Message variants are not the token channel' do
      listener = described_class.new

      listener.on_message(Agent::Message::User.new(content: 'hi'))
      listener.on_message(Agent::Message::Assistant.new(content: 'reply'))
      listener.on_message(Agent::Message::ToolCall.new(name: 't', arguments: {}))
      listener.on_message(Agent::Message::ToolResult.new(content: 'r'))
      listener.on_message(Agent::Message::Thinking.new(content: 'pondering'))
      listener.on_message(Agent::Message::FallbackNotice.new(reason: 'why'))

      assert_equal '', buf.string
    end
  end

  describe 'isolation between instances' do
    it 'each TokenLog has its own session totals (sub-agent does not inherit parent counts)' do
      parent = described_class.new
      child  = described_class.new

      # Child's totals being separate from the parent's would show up
      # as 'session: out=0.5k', not '1.5k' if state leaked across.
      parent.on_tokens(tokens(input: 10_240, output: 1024))
      child.on_tokens(tokens(input: 5120, output: 512))

      parent_line = buf.string.lines.find { |l| l.include?('ctx=10.0k') }
      child_line  = buf.string.lines.find { |l| l.include?('ctx=5.0k') }

      assert_includes parent_line, 'session: out=1.0k'
      assert_includes child_line,  'session: out=0.5k'
    end
  end

  describe '#to_s' do
    it 'shows zero context until the first tokens arrive' do
      assert_equal 'TokenLog(ctx=0.0k)', described_class.new.to_s
    end

    it 'reflects the latest context-window snapshot after on_tokens fires' do
      listener = described_class.new
      listener.on_tokens(tokens(input: 12_345))

      # 12_345 / 1024 ≈ 12.0556 → 12.1k
      assert_equal 'TokenLog(ctx=12.1k)', listener.to_s
    end
  end
end
