# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Memory::Extension do
  def record(text, created_at: nil, score: nil)
    Pikuri::Memory::Record.new(
      id: 'r', text: text, score: score, created_at: created_at, metadata: {}, event: nil
    )
  end

  # Fake mem0 client: canned search/get_all results, and a thread-safe
  # capture of #add calls (capture is async).
  let(:fake_client_class) do
    Class.new do
      attr_accessor :search_rows, :all_rows, :search_error, :all_error

      def initialize
        @search_rows = []
        @all_rows = []
        @search_error = nil
        @all_error = nil
        @adds = Thread::Queue.new
      end

      def search(query:, user_id:, top_k:, threshold:)
        raise @search_error if @search_error

        @search_rows
      end

      def get_all(user_id:)
        raise @all_error if @all_error

        @all_rows
      end

      def add(content:, user_id:, infer:, prompt:)
        @adds << content
        []
      end

      def await_add(timeout: 2)
        Timeout.timeout(timeout) { @adds.pop }
      end
    end
  end

  # A standalone Configurator (no full Agent needed to test #configure).
  def build_configurator
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base', id: '', streaming: false,
      step_limit: nil, cancellable: nil, interloper: nil
    )
  end

  # A minimal agent stand-in that records on_close blocks.
  let(:fake_agent_class) do
    Class.new do
      attr_reader :close_blocks

      def initialize
        @close_blocks = []
      end

      def on_close(&blk)
        @close_blocks << blk
      end
    end
  end

  describe '#configure' do
    it 'registers the recall tool' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      c = build_configurator
      ext.configure(c)

      assert_equal ['recall'], c.tools.map(&:name)
    end

    it 'appends a resident-persona snippet built from the store' do
      client = fake_client_class.new
      client.all_rows = [record('lives in Brno'), record('writes Ruby')]
      ext = described_class.new(client: client, user_id: 'u')
      c = build_configurator
      ext.configure(c)

      snippet = c.system_prompt_additions.join
      assert_match(/<memory_persona>/, snippet)
      assert_match(/lives in Brno/, snippet)
      assert_match(/writes Ruby/, snippet)
    end

    it 'appends no persona snippet for an empty store' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u')
      c = build_configurator
      ext.configure(c)

      assert_equal [], c.system_prompt_additions
    end

    it 'survives an unreachable store at boot (no persona, no raise)' do
      client = fake_client_class.new
      client.all_error = RuntimeError.new('mem0 down')
      ext = described_class.new(client: client, user_id: 'u')
      c = build_configurator
      ext.configure(c) # must not raise

      assert_equal [], c.system_prompt_additions
    end

    it 'skips the persona entirely when resident_persona: false' do
      client = fake_client_class.new
      client.all_rows = [record('should not be read')]
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)
      c = build_configurator
      ext.configure(c)

      assert_equal [], c.system_prompt_additions
    end

    it 'raises if recall was pre-registered' do
      pre = Pikuri::Tool.new(
        name: 'recall', description: 'x',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :topic, 't' },
        execute: ->(topic:) { topic }
      )
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      c = build_configurator
      c.add_tool(pre)

      assert_raises(RuntimeError) { ext.configure(c) }
    end
  end

  describe '#on_user_message prefetch' do
    it 'returns a system-framed <memory-context> with timestamps' do
      client = fake_client_class.new
      client.search_rows = [record('lives in Brno', created_at: '2026-05-01T17:04:11.884889+00:00', score: 0.8)]
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)

      block = ext.on_user_message(nil, 'where do I live?')

      assert_match(/<memory-context>/, block)
      assert_match(/NOT new user input/, block)
      # created_at is trimmed to whole-second wall-clock — no sub-second / offset noise.
      assert_match(/\(2026-05-01 17:04:11\) lives in Brno/, block)
      assert_match(/recall/, block) # affordance pointing at the tool
    end

    it 'returns nil when search finds nothing' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      assert_nil ext.on_user_message(nil, 'anything')
    end

    it 'gates by threshold client-side, dropping low-similarity rows' do
      client = fake_client_class.new
      client.search_rows = [
        record('relevant', score: 0.8),
        record('noise', score: 0.2)
      ]
      ext = described_class.new(client: client, user_id: 'u', threshold: 0.5, resident_persona: false)

      block = ext.on_user_message(nil, 'q')

      assert_match(/relevant/, block)
      refute_match(/noise/, block)
    end

    it 'returns nil (no raise) when search fails' do
      client = fake_client_class.new
      client.search_error = RuntimeError.new('mem0 down')
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)

      assert_nil ext.on_user_message(nil, 'q')
    end

    it 'returns nil for blank content' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      assert_nil ext.on_user_message(nil, '   ')
    end
  end

  describe '#on_user_message capture + #bind' do
    it 'bind starts the recorder and enqueued turns reach client.add' do
      require 'timeout'
      client = fake_client_class.new
      ext = described_class.new(client: client, user_id: 'martin', resident_persona: false)
      agent = fake_agent_class.new

      ext.bind(agent)
      ext.on_user_message(nil, 'I am vegetarian')

      assert_equal 'I am vegetarian', client.await_add
      refute_empty agent.close_blocks
    ensure
      ext.recorder.close
    end

    it 'the on_close block closes the recorder' do
      client = fake_client_class.new
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)
      agent = fake_agent_class.new
      ext.bind(agent)

      agent.close_blocks.each(&:call) # must not raise; recorder stops
    end
  end
end
