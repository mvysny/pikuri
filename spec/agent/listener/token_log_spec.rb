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

    it 'logs one info line per emission: ctx is the latest snapshot, deltas accumulate' do
      # input is a per-turn delta (the uncached portion of THIS turn's
      # prompt). ctx is a snapshot — input + cached + cache_creation —
      # and the session: ctx= is just the latest one, never summed.
      # All deltas (input/output/cached/cache_creation/thinking) DO
      # sum into the session totals.
      listener.on_tokens(tokens(input: 1024, cached: 9216, output: 1024))
      listener.on_tokens(tokens(input: 2048, cached: 10_240, output: 2048))

      lines = buf.string.lines
      assert_equal 2, lines.size
      # Turn 1: ctx = 1024 + 9216 = 10240 → 10.0k.
      assert_includes lines[0], 'msg #1: ctx=10.0k in=1.0k out=1.0k cached=9.0k'
      assert_includes lines[0], 'session: ctx=10.0k in=1.0k out=1.0k cached=9.0k'
      # Turn 2: ctx = 2048 + 10240 = 12288 → 12.0k. session sums in (3.0k), out (3.0k), cached (19.0k).
      assert_includes lines[1], 'msg #2: ctx=12.0k in=2.0k out=2.0k cached=10.0k'
      assert_includes lines[1], 'session: ctx=12.0k in=3.0k out=3.0k cached=19.0k'
    end

    it 'omits thinking, cached, and cache_creation when zero' do
      listener.on_tokens(tokens(input: 10_240, output: 1024))

      line = buf.string.lines.first
      refute_includes line, 'thinking='
      refute_includes line, 'cached='
      refute_includes line, 'cache_creation='
    end

    it 'includes thinking, cached, and cache_creation when non-zero' do
      listener.on_tokens(tokens(
                           input: 1024, output: 1024,
                           cached: 8192, cache_creation: 2048, thinking: 5120
                         ))

      line = buf.string.lines.first
      assert_includes line, 'cached=8.0k'
      assert_includes line, 'cache_creation=2.0k'
      assert_includes line, 'thinking=5.0k'
    end

    it 'treats nil token fields as zero so providers that report nothing still log a line' do
      listener.on_tokens(Agent::Tokens.new(
                           input: nil, output: nil, cached: nil, cache_creation: nil,
                           thinking: nil, model_id: nil
                         ))

      line = buf.string.lines.first
      assert_includes line, 'msg #1: ctx=0.0k in=0.0k out=0.0k | session: ctx=0.0k in=0.0k out=0.0k'
    end
  end

  describe '#context_window_size' do
    it 'is zero before any tokens have been seen' do
      assert_equal 0, described_class.new.context_window_size
    end

    it 'is the LATEST input + cached + cache_creation, the three exclusive portions of this turn\'s prompt' do
      listener = described_class.new

      # Turn 1: full prompt is 1000 uncached + 5000 cached + 200 newly-cached = 6200.
      listener.on_tokens(tokens(input: 1000, cached: 5000, cache_creation: 200))
      assert_equal 6200, listener.context_window_size

      # Turn 2: prompt grows. cache_creation 0 (already-warm cache).
      listener.on_tokens(tokens(input: 500, cached: 6500, cache_creation: 0))
      assert_equal 7000, listener.context_window_size
    end

    it 'reflects only the LATEST snapshot, not a sum and not the max' do
      listener = described_class.new

      listener.on_tokens(tokens(input: 10_000, cached: 0))
      listener.on_tokens(tokens(input: 15_000, cached: 0))
      # Smaller than the previous turn — legitimate if ruby_llm ever
      # pruned messages between turns. "Current" means latest, not peak.
      listener.on_tokens(tokens(input: 12_000, cached: 0))

      assert_equal 12_000, listener.context_window_size
    end

    it 'treats nil inputs as zero' do
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

      parent.on_tokens(tokens(input: 10_240, output: 1024))
      child.on_tokens(tokens(input: 5120, output: 512))

      parent_line = buf.string.lines.find { |l| l.include?('msg #1: ctx=10.0k') }
      child_line  = buf.string.lines.find { |l| l.include?('msg #1: ctx=5.0k') }

      assert_includes parent_line, 'session: ctx=10.0k in=10.0k out=1.0k'
      assert_includes child_line,  'session: ctx=5.0k in=5.0k out=0.5k'
    end
  end

  describe '#to_s' do
    it 'shows zero context until the first tokens arrive' do
      assert_equal 'TokenLog(ctx=0.0k)', described_class.new.to_s
    end

    it 'reflects the latest context-window snapshot after on_tokens fires' do
      listener = described_class.new
      # 1024 uncached + 11321 cached = 12345 → 12345 / 1024 ≈ 12.1k.
      listener.on_tokens(tokens(input: 1024, cached: 11_321))

      assert_equal 'TokenLog(ctx=12.1k)', listener.to_s
    end
  end
end
