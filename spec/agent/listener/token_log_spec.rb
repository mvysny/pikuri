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

    it 'logs one info line per emission with per-msg and session counts' do
      listener.on_tokens(tokens(input: 100, output: 20))
      listener.on_tokens(tokens(input: 250, output: 30))

      lines = buf.string.lines
      assert_equal 2, lines.size
      assert_includes lines[0], 'msg #1: in=100 out=20 | session: in=100 out=20'
      assert_includes lines[1], 'msg #2: in=250 out=30 | session: in=350 out=50'
    end

    it 'omits thinking and cached from the line when they are zero' do
      listener.on_tokens(tokens(input: 100, output: 20))

      line = buf.string.lines.first
      refute_includes line, 'thinking='
      refute_includes line, 'cached='
    end

    it 'includes thinking and cached fields when non-zero' do
      listener.on_tokens(tokens(input: 100, output: 20, thinking: 50, cached: 80))

      line = buf.string.lines.first
      assert_includes line, 'thinking=50'
      assert_includes line, 'cached=80'
    end

    it 'treats nil token fields as zero so providers that report nothing still log a line' do
      listener.on_tokens(Agent::Tokens.new(
                           input: nil, output: nil, cached: nil, cache_creation: nil,
                           thinking: nil, model_id: nil
                         ))

      line = buf.string.lines.first
      assert_includes line, 'msg #1: in=0 out=0 | session: in=0 out=0'
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

      parent.on_tokens(tokens(input: 1000, output: 100))
      child.on_tokens(tokens(input: 50, output: 10))

      parent_line = buf.string.lines.find { |l| l.include?('in=1000') }
      child_line  = buf.string.lines.find { |l| l.include?('in=50 out=10') }

      assert_includes parent_line, 'session: in=1000 out=100'
      assert_includes child_line,  'session: in=50 out=10'
    end
  end

  describe '#to_s' do
    it 'renders the short label' do
      assert_equal 'TokenLog', described_class.new.to_s
    end
  end
end
