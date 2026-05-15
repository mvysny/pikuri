# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Agent::Listener::TokenLog do
  # Capture-buffer pattern: swap +Pikuri.log_io+ for a +StringIO+, run
  # the listener, then read what was logged. Restore the original IO
  # in +after+.
  let(:buf) { StringIO.new }

  before do
    @original_io = Pikuri.log_io
    Pikuri.log_io = buf
    # The logger level is captured at +logger_for+ time, but since
    # +PIKURI_LOG+ isn't set in CI, it defaults to INFO — exactly the
    # level +TokenLog+ writes at. No level fiddling needed.
  end

  after { Pikuri.log_io = @original_io }

  # Build an Event::Tokens with the given fields, defaulting the
  # uninteresting ones to zero so each test only states what matters.
  def tokens(input: 0, output: 0, cached: 0, cache_creation: 0, thinking: 0, model_id: nil)
    Pikuri::Agent::Event::Tokens.new(
      input: input, output: output, cached: cached, cache_creation: cache_creation,
      thinking: thinking, model_id: model_id
    )
  end

  describe 'Event::Tokens dispatch' do
    let(:listener) { described_class.new }

    it 'logs one info line per emission with ctx, Δ from previous ctx, and per-turn ↑/↓' do
      # Turn 1: ctx = 1024 + 9216 + 1024 = 11264 → 11.0k. No prior ctx,
      # so Δ is from the implicit baseline of zero — Δ equals ctx.
      listener.on_event(tokens(input: 1024, cached: 9216, output: 1024))
      # Turn 2: ctx = 2048 + 10240 + 2048 = 14336 → 14.0k. Δ = +3.0k.
      listener.on_event(tokens(input: 2048, cached: 10_240, output: 2048))

      lines = buf.string.lines
      assert_equal 2, lines.size
      assert_includes lines[0], 'msg #1: ctx=11.0k  Δ+11.0k  ↑1.0k  ↓1.0k'
      assert_includes lines[1], 'msg #2: ctx=14.0k  Δ+3.0k  ↑2.0k  ↓2.0k'
    end

    it 'renders a negative Δ when ctx shrinks (legitimate if ruby_llm prunes between turns)' do
      listener.on_event(tokens(input: 10_240))
      listener.on_event(tokens(input: 8192))

      line = buf.string.lines[1]
      assert_includes line, 'msg #2: ctx=8.0k  Δ-2.0k  ↑8.0k  ↓0.0k'
    end

    it 'treats nil token fields as zero so providers that report nothing still log a line' do
      listener.on_event(Pikuri::Agent::Event::Tokens.new(
                          input: nil, output: nil, cached: nil, cache_creation: nil,
                          thinking: nil, model_id: nil
                        ))

      line = buf.string.lines.first
      assert_includes line, 'msg #1: ctx=0.0k  Δ+0.0k  ↑0.0k  ↓0.0k'
    end

    it 'includes cache_creation in ctx (one of the three prompt portions alongside output)' do
      listener.on_event(tokens(input: 1024, cached: 8192, cache_creation: 2048, output: 1024))

      # ctx = 1024 + 8192 + 2048 + 1024 = 12288 → 12.0k.
      line = buf.string.lines.first
      assert_includes line, 'msg #1: ctx=12.0k'
    end
  end

  describe '#context_window_size' do
    it 'is zero before any tokens have been seen' do
      assert_equal 0, described_class.new.context_window_size
    end

    it "is the LATEST input + cached + cache_creation + output — this turn's prompt plus its reply" do
      listener = described_class.new

      # Turn 1: prompt 1000 uncached + 5000 cached + 200 newly-cached = 6200,
      # plus 300 of reply = 6500 consumed through this turn.
      listener.on_event(tokens(input: 1000, cached: 5000, cache_creation: 200, output: 300))
      assert_equal 6500, listener.context_window_size

      # Turn 2: prompt grows. cache_creation 0 (already-warm cache).
      listener.on_event(tokens(input: 500, cached: 6500, cache_creation: 0, output: 400))
      assert_equal 7400, listener.context_window_size
    end

    it 'reflects only the LATEST snapshot, not a sum and not the max' do
      listener = described_class.new

      listener.on_event(tokens(input: 10_000, cached: 0))
      listener.on_event(tokens(input: 15_000, cached: 0))
      listener.on_event(tokens(input: 12_000, cached: 0))

      assert_equal 12_000, listener.context_window_size
    end

    it 'treats nil inputs as zero' do
      listener = described_class.new
      listener.on_event(Pikuri::Agent::Event::Tokens.new(
                          input: nil, output: nil, cached: nil, cache_creation: nil,
                          thinking: nil, model_id: nil
                        ))

      assert_equal 0, listener.context_window_size
    end
  end

  describe 'Event::ContextCap dispatch' do
    it 'picks the cap off a ContextCap event and stores it' do
      listener = described_class.new
      assert_nil listener.context_window_cap

      listener.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 32_768))

      assert_equal 32_768, listener.context_window_cap
    end

    it 'accepts nil so an agent without a detected cap still emits a one-shot event' do
      listener = described_class.new
      listener.context_window_cap = 16_000

      listener.on_event(Pikuri::Agent::Event::ContextCap.new(cap: nil))

      assert_nil listener.context_window_cap
    end

    it 'with a cap set, renders ctx as <used>/<cap> in the log line' do
      listener = described_class.new
      listener.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 32_768))

      listener.on_event(tokens(input: 1024, cached: 9216, output: 1024))

      # used = 1024 + 9216 + 1024 = 11264 → 11.0k; cap = 32768 → 32.0k.
      line = buf.string.lines.first
      assert_includes line, 'ctx=11.0k/32.0k'
      assert_includes line, 'Δ+11.0k'
    end

    it 'with no cap event, renders ctx as <used> only (no slash form)' do
      listener = described_class.new
      listener.on_event(tokens(input: 10_240))

      line = buf.string.lines.first
      assert_includes line, 'ctx=10.0k '
      refute_includes line, 'ctx=10.0k/'
    end
  end

  describe 'irrelevant event variants' do
    it 'is a no-op for every non-Tokens, non-ContextCap variant' do
      listener = described_class.new

      [
        Pikuri::Agent::Event::UserTurn.new(content: 'hi'),
        Pikuri::Agent::Event::Assistant.new(content: 'reply'),
        Pikuri::Agent::Event::ToolCall.new(name: 't', arguments: {}),
        Pikuri::Agent::Event::ToolResult.new(content: 'r'),
        Pikuri::Agent::Event::Thinking.new(content: 'pondering'),
        Pikuri::Agent::Event::FallbackNotice.new(reason: 'why'),
        Pikuri::Agent::Event::Cancelled.new
      ].each { |e| listener.on_event(e) }

      assert_equal '', buf.string
      assert_equal 0, listener.context_window_size
    end
  end

  describe 'isolation between instances' do
    it 'each TokenLog tracks its own ctx (sub-agent does not inherit parent ctx)' do
      parent = described_class.new
      child  = described_class.new

      parent.on_event(tokens(input: 10_240, output: 1024))
      child.on_event(tokens(input: 5120, output: 512))

      parent_line = buf.string.lines.find { |l| l.include?('msg #1: ctx=11.0k') }
      child_line  = buf.string.lines.find { |l| l.include?('msg #1: ctx=5.5k') }

      assert_includes parent_line, 'Δ+11.0k  ↑10.0k  ↓1.0k'
      assert_includes child_line,  'Δ+5.5k  ↑5.0k  ↓0.5k'
    end
  end

  describe '#for_sub_agent' do
    it 'returns a fresh TokenLog with a zeroed snapshot and nil cap' do
      original = described_class.new
      original.context_window_cap = 32_768
      original.on_event(tokens(input: 10_240))
      refute_equal 0, original.context_window_size

      derived = original.for_sub_agent

      refute_same original, derived
      assert_equal 0, derived.context_window_size
      assert_nil derived.context_window_cap
    end

    it 'ignores unrelated params forwarded by ListenerList#for_sub_agent' do
      derived = described_class.new.for_sub_agent(anything_else: :nope)
      assert_equal 0, derived.context_window_size
    end

    it 'leaves the parent TokenLog snapshot intact' do
      original = described_class.new
      original.on_event(tokens(input: 10_240))

      original.for_sub_agent

      assert_equal 10_240, original.context_window_size
    end

    it 'carries the forwarded name: kwarg onto the derived instance' do
      derived = described_class.new.for_sub_agent(name: '0_1')

      assert_equal '0_1', derived.name
    end

    it "defaults the derived instance's name to '' when no name is forwarded" do
      derived = described_class.new(name: 'parent').for_sub_agent

      # The sub-agent isn't named by inheritance — it gets a fresh, empty
      # name unless the caller threads one through. Matches the contract
      # in Pikuri::Tool::SubAgent, which always passes a generated name.
      assert_equal '', derived.name
    end
  end

  describe 'name prefix' do
    it 'prefixes log lines with [name] when name is non-empty' do
      listener = described_class.new(name: '0')

      listener.on_event(tokens(input: 1024, cached: 9216, output: 1024))

      line = buf.string.lines.first
      assert_includes line, '[0] msg #1: ctx=11.0k'
    end

    it 'omits the prefix when name is empty (main agent)' do
      listener = described_class.new

      listener.on_event(tokens(input: 1024))

      line = buf.string.lines.first
      refute_match(/\A\[/, line.lstrip)
      assert_includes line, 'msg #1:'
    end
  end

  describe '#to_s' do
    it 'shows zero context until the first tokens arrive' do
      assert_equal 'TokenLog(ctx=0.0k)', described_class.new.to_s
    end

    it 'reflects the latest context-window snapshot after on_event fires' do
      listener = described_class.new
      # 1024 uncached + 11321 cached = 12345 → 12345 / 1024 ≈ 12.1k.
      listener.on_event(tokens(input: 1024, cached: 11_321))

      assert_equal 'TokenLog(ctx=12.1k)', listener.to_s
    end

    it 'shows ctx as <used>/<cap> when a context_window_cap has been received' do
      listener = described_class.new
      listener.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 32_768))
      listener.on_event(tokens(input: 1024, cached: 11_321))

      assert_equal 'TokenLog(ctx=12.1k/32.0k)', listener.to_s
    end
  end
end
