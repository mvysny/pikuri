# frozen_string_literal: true

require 'tmpdir'
require 'json'

RSpec.describe Pikuri::Agent::History do
  H = Pikuri::Agent::History unless defined?(H)

  # A conversation exercising every branch of the format: a typed user turn, an
  # assistant tool-call turn with thinking + usage, the tool result carrying an
  # image, and an injected reference block.
  let(:png) { (+"\x89PNG\r\n\x1a\n").b + ('payload' * 4).b }
  let(:history) do
    H.new(messages: [
            H::Message.new(id: 'm1', role: 'user', content: 'show me a.png'),
            H::Message.new(id: 'm2', role: 'assistant', content: '', model_id: 'qwen3-35b',
                           tool_calls: [H::ToolCall.new(id: 'call_1', name: 'read',
                                                        arguments: { 'path' => 'a.png' })],
                           thinking: H::Thinking.new(text: 'ponder', signature: 'SIG=='),
                           tokens: H::Tokens.new(input: 100, output: 7, cached: 20,
                                                 cache_creation: nil, thinking: nil)),
            H::Message.new(id: 'm3', role: 'tool', tool_call_id: 'call_1',
                           content: 'Read image: a.png',
                           attachments: [Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png)]),
            H::Message.new(id: 'm4', role: 'user', kind: 'reference',
                           content: '<system-reminder>recalled</system-reminder>')
          ])
  end

  describe 'round-tripping' do
    it 'survives the self-contained JSON form' do
      assert_equal history, H.parse(history.to_json)
    end

    it 'survives the folder form' do
      Dir.mktmpdir do |dir|
        history.save(dir)
        assert_equal history, H.load(dir)
      end
    end

    it 'converges: both encodings load to the same value' do
      Dir.mktmpdir do |dir|
        history.save(dir)
        # The property that stops the two encodings drifting into two formats.
        assert_equal H.parse(history.to_json), H.load(dir)
      end
    end

    it 'survives a trip through RubyLLM message objects' do
      back = history.messages.map do |m|
        H::Message.from_ruby_llm(m.to_ruby_llm, id: m.id, kind: m.kind)
      end
      assert_equal history, H.new(messages: back)
    end

    it 'serializes every Pikuri::Attachment field' do
      # A field added to Pikuri::Attachment needs attachment_to_h/from_h too;
      # one with a default would otherwise be dropped on save without a sound.
      assert_equal %i[mime filename bytes], Pikuri::Attachment.members
    end

    it 'normalizes attachment bytes to binary, so identical content compares equal' do
      utf8 = Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png.dup.force_encoding('UTF-8'))
      assert_equal Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png), utf8
    end
  end

  describe 'the folder form' do
    it 'writes history.json plus content-addressed attachments' do
      Dir.mktmpdir do |dir|
        saved = history.save(dir)
        assert_equal %w[attachments history.json], Dir.children(saved).sort
        stored = Dir.children(saved / 'attachments')
        assert_equal 1, stored.size
        # Digest prefix + sanitized original name.
        assert_match(/\A[0-9a-f]{10}-a\.png\z/, stored.first)
      end
    end

    it 'skips an attachment already present, and never deletes an unreferenced one' do
      Dir.mktmpdir do |dir|
        saved = history.save(dir)
        orphan = saved / 'attachments' / 'deadbeef00-gone.png'
        orphan.binwrite('stale')

        # Re-saving a shrunken history leaves both the orphan and the still-live file.
        history.with(messages: history.messages.take(2)).save(dir)

        assert orphan.exist?, 'save must not delete files it did not write'
        assert_equal 2, Dir.children(saved / 'attachments').size
      end
    end

    it 'refuses a history whose attachment is missing from the folder' do
      Dir.mktmpdir do |dir|
        saved = history.save(dir)
        (saved / 'attachments').children.each(&:delete)

        e = assert_raises(H::Error) { H.load(dir) }
        assert_match(/is missing from/, e.message)
      end
    end

    it 'refuses an attachment whose bytes no longer match its digest' do
      Dir.mktmpdir do |dir|
        saved = history.save(dir)
        (saved / 'attachments').children.first.binwrite('tampered')

        e = assert_raises(H::Error) { H.load(dir) }
        assert_match(/does not match its content digest/, e.message)
      end
    end
  end

  describe 'attachment confinement' do
    # The rule: an attachment either lives in this folder or the history does
    # not load. No sanitizing, no rewriting a bad path into a good one.
    def tampered(dir, file)
      raw = JSON.parse((Pathname(dir) / 'history.json').read)
      raw['messages'][2]['attachments'][0]['file'] = file
      raw
    end

    it 'refuses a traversal out of the folder' do
      Dir.mktmpdir do |dir|
        history.save(dir)
        File.write(File.join(dir, 'secret.txt'), 'ssh-key')

        e = assert_raises(H::Error) { H.from_h(tampered(dir, '../secret.txt'), dir: Pathname(dir)) }
        assert_match(/must be a bare filename/, e.message)
      end
    end

    it 'refuses an absolute path' do
      Dir.mktmpdir do |dir|
        history.save(dir)

        e = assert_raises(H::Error) { H.from_h(tampered(dir, '/etc/passwd'), dir: Pathname(dir)) }
        assert_match(/must be a bare filename/, e.message)
      end
    end

    it 'refuses a symlink that resolves outside the folder' do
      Dir.mktmpdir do |dir|
        saved = history.save(dir)
        secret = File.join(dir, 'secret.txt')
        File.write(secret, 'ssh-key')
        # Passes every textual check: a bare filename, sitting in attachments/.
        File.symlink(secret, saved / 'attachments' / 'aaaaaaaaaa-evil.png')

        e = assert_raises(H::Error) { H.from_h(tampered(dir, 'aaaaaaaaaa-evil.png'), dir: Pathname(dir)) }
        assert_match(/outside/, e.message)
      end
    end

    it 'refuses a file-backed attachment when parsed without a folder' do
      Dir.mktmpdir do |dir|
        json = (history.save(dir) / 'history.json').read

        e = assert_raises(H::Error) { H.parse(json) }
        assert_match(/use History\.load/, e.message)
      end
    end
  end

  describe 'validation' do
    def raw(messages) = { 'version' => 1, 'messages' => messages }

    it 'refuses a version from the future rather than loading it best-effort' do
      e = assert_raises(H::Error) { H.from_h({ 'version' => 2, 'messages' => [] }) }
      assert_match(/newer than this pikuri understands/, e.message)
    end

    it 'refuses malformed JSON' do
      assert_raises(H::Error) { H.parse('{not json') }
    end

    it 'ignores unknown keys, so a file from a newer pikuri still loads' do
      loaded = H.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'hi', 'invented_later' => 42 }]))
      assert_equal 1, loaded.messages.size
    end

    it 'defaults an absent kind to user' do
      loaded = H.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'hi' }]))
      assert_equal 'user', loaded.messages.first.kind
    end

    it 'refuses a system message: the prompt is re-assembled, never replayed' do
      e = assert_raises(H::Error) { H.from_h(raw([{ 'id' => 'a', 'role' => 'system', 'content' => 'x' }])) }
      assert_match(%r{role must be one of user/assistant/tool}, e.message)
    end

    it 'refuses a duplicate id' do
      e = assert_raises(H::Error) do
        H.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'x' },
                      { 'id' => 'a', 'role' => 'user', 'content' => 'y' }]))
      end
      assert_match(/duplicate id a/, e.message)
    end

    it 'refuses a tool result no assistant message asked for' do
      e = assert_raises(H::Error) do
        H.from_h(raw([{ 'id' => 'a', 'role' => 'tool', 'tool_call_id' => 'ghost', 'content' => 'x' }]))
      end
      assert_match(/was never issued/, e.message)
    end

    it 'refuses one tool call answered twice' do
      e = assert_raises(H::Error) do
        H.from_h(raw([{ 'id' => 'a', 'role' => 'assistant', 'content' => '',
                        'tool_calls' => [{ 'id' => 'c1', 'name' => 'read', 'arguments' => {} }] },
                      { 'id' => 'b', 'role' => 'tool', 'tool_call_id' => 'c1', 'content' => 'x' },
                      { 'id' => 'c', 'role' => 'tool', 'tool_call_id' => 'c1', 'content' => 'y' }]))
      end
      assert_match(/already answered/, e.message)
    end

    it 'refuses a tool_call_id on a non-tool message' do
      e = assert_raises(H::Error) do
        H.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'x', 'tool_call_id' => 'c1' }]))
      end
      assert_match(/only a tool message/, e.message)
    end

    it 'accepts a tool call with no result: that is what a crash leaves behind' do
      loaded = H.from_h(raw([{ 'id' => 'a', 'role' => 'assistant', 'content' => '',
                               'tool_calls' => [{ 'id' => 'c1', 'name' => 'read', 'arguments' => {} }] }]))
      assert_equal 1, loaded.messages.size
    end
  end

  describe '#repair_interrupted_tool_calls' do
    def assistant(calls)
      H::Message.new(id: 'a', role: 'assistant', content: '',
                     tool_calls: calls.map { |c| H::ToolCall.new(id: c, name: 'read', arguments: {}) })
    end

    it 'is a no-op when every call was answered' do
      h = H.new(messages: [assistant(%w[c1]),
                           H::Message.new(id: 'b', role: 'tool', tool_call_id: 'c1', content: 'ok')])
      assert_same h, h.repair_interrupted_tool_calls
    end

    it 'synthesizes a result for a call that never got one' do
      repaired = H.new(messages: [assistant(%w[c1])]).repair_interrupted_tool_calls

      assert_equal %w[assistant tool], repaired.messages.map(&:role)
      assert_equal 'c1', repaired.messages.last.tool_call_id
      assert_equal H::INTERRUPTED_RESULT, repaired.messages.last.content
    end

    it 'fills only the unanswered calls of a partly-answered batch, after the real results' do
      h = H.new(messages: [assistant(%w[c1 c2 c3]),
                           H::Message.new(id: 'b', role: 'tool', tool_call_id: 'c2', content: 'ok')])

      repaired = h.repair_interrupted_tool_calls

      # The answering run stays contiguous, real results first.
      assert_equal %w[assistant tool tool tool], repaired.messages.map(&:role)
      assert_equal %w[c2 c1 c3], repaired.messages.drop(1).map(&:tool_call_id)
      assert_equal ['ok'], repaired.messages.drop(1).map(&:content).uniq - [H::INTERRUPTED_RESULT]
    end

    it 'leaves a repaired history loadable, closing the crash loop' do
      repaired = H.new(messages: [assistant(%w[c1])]).repair_interrupted_tool_calls
      assert_equal repaired, H.parse(repaired.to_json)
    end
  end

  describe '.mint_id' do
    it 'sorts in mint order, so ordering falls out of the id itself' do
      ids = Array.new(50) { H.mint_id }
      assert_equal ids, ids.sort
      assert_equal ids.size, ids.uniq.size
    end
  end
end
