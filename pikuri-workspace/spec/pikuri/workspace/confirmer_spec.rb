# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Workspace::Confirmer do
  # Shorthand for a minimal Request; question defaults to 'go?'.
  def req(question = 'go?', detail: nil)
    Pikuri::Workspace::Confirmer::Request.new(question: question, detail: detail)
  end

  describe Pikuri::Workspace::Confirmer::Request do
    it 'carries question and detail' do
      r = described_class.new(question: 'OK?', detail: '$ ls')
      assert_equal 'OK?', r.question
      assert_equal '$ ls', r.detail
    end

    it 'defaults detail to nil' do
      assert_nil described_class.new(question: 'OK?').detail
    end
  end

  describe '#confirm?' do
    it 'raises NotImplementedError on the abstract base' do
      assert_raises(NotImplementedError) { described_class.new.confirm?(request: req('ok?')) }
    end
  end

  describe Pikuri::Workspace::Confirmer::Terminal do
    around do |example|
      orig_in, orig_out = $stdin, $stdout
      orig_rainbow = Rainbow.enabled
      $stdout = StringIO.new
      # Deterministic plain-text rendering regardless of whether the
      # spec runner's stdout is a TTY; the one color spec below opts
      # back in explicitly.
      Rainbow.enabled = false
      example.run
      $stdin, $stdout = orig_in, orig_out
      Rainbow.enabled = orig_rainbow
    end

    def stdin_with(text)
      $stdin = StringIO.new(text)
    end

    it 'returns true for "y"' do
      stdin_with("y\n")
      assert_equal true, described_class.new.confirm?(request: req)
    end

    it 'returns true for "yes"' do
      stdin_with("yes\n")
      assert_equal true, described_class.new.confirm?(request: req)
    end

    it 'is case-insensitive: "Y", "YES", "Yes" all approve' do
      %w[Y YES Yes].each do |answer|
        stdin_with("#{answer}\n")
        assert_equal true, described_class.new.confirm?(request: req),
                     "expected #{answer.inspect} to approve"
      end
    end

    it 'strips surrounding whitespace before matching' do
      stdin_with("  yes  \n")
      assert_equal true, described_class.new.confirm?(request: req)
    end

    it 'returns false for "n"' do
      stdin_with("n\n")
      assert_equal false, described_class.new.confirm?(request: req)
    end

    it 'returns false for "no" (case-insensitive)' do
      %w[no NO No].each do |answer|
        stdin_with("#{answer}\n")
        assert_equal false, described_class.new.confirm?(request: req)
      end
    end

    it 'returns false on EOF (Ctrl+D / empty stdin)' do
      stdin_with('')
      assert_equal false, described_class.new.confirm?(request: req)
    end

    it 'reprompts on unrecognized input and honors the next answer' do
      stdin_with("maybe\nblank\nyes\n")
      assert_equal true, described_class.new.confirm?(request: req)
      assert_includes $stdout.string, 'Please answer y or n: '
    end

    it 'reprompts on blank line, eventually returns false on EOF' do
      stdin_with("\n\n\n")
      assert_equal false, described_class.new.confirm?(request: req)
    end

    it 'renders question, then cue, when there is no detail' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to overwrite a.txt: 4 → 6 bytes?'))
      assert_includes $stdout.string, "\nOK to overwrite a.txt: 4 → 6 bytes?\n(y/n)?\n"
    end

    it 'renders the detail on its own line between question and cue' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: '$ ls -la'))
      assert_includes $stdout.string, "\nOK to run bash\n$ ls -la\n(y/n)?\n"
    end

    it 'preserves newlines in a multi-line detail' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: "$ for x in 1 2; do\n  echo $x\ndone"))
      assert_includes $stdout.string, "$ for x in 1 2; do\n  echo $x\ndone\n(y/n)?\n"
    end

    it 'escapes control bytes in the detail so a \r cannot overwrite the echoed command' do
      stdin_with("n\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: "$ echo hi\rrm -rf /"))
      assert_includes $stdout.string, '$ echo hi\\x0drm -rf /'
      refute_includes $stdout.string, "\r"
    end

    it 'escapes control bytes in the question (it may embed an LLM-written description)' do
      stdin_with("n\n")
      described_class.new.confirm?(request: req("OK to run bash: nice\e[2Kdesc"))
      assert_includes $stdout.string, 'OK to run bash: nice\\x1b[2Kdesc'
      refute_includes $stdout.string, "\e"
    end

    it 'bolds the question via Rainbow when color is enabled' do
      Rainbow.enabled = true
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: '$ ls'))
      assert_includes $stdout.string, "\e[1mOK to run bash\e[0m"
    end
  end

  describe Pikuri::Workspace::Confirmer::AutoApprove do
    it 'returns true regardless of request' do
      assert_equal true, described_class.new.confirm?(request: req('anything', detail: '$ rm -rf /'))
      assert_equal true, described_class.new.confirm?(request: req(''))
    end
  end

  describe 'singleton constants' do
    it 'TERMINAL is a Terminal instance' do
      assert_instance_of Pikuri::Workspace::Confirmer::Terminal, Pikuri::Workspace::Confirmer::TERMINAL
    end

    it 'AUTO_APPROVE is an AutoApprove instance' do
      assert_instance_of Pikuri::Workspace::Confirmer::AutoApprove, Pikuri::Workspace::Confirmer::AUTO_APPROVE
    end
  end
end
