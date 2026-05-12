# frozen_string_literal: true

require 'stringio'

RSpec.describe Tool::Confirmer do
  describe '#confirm?' do
    it 'raises NotImplementedError on the abstract base' do
      assert_raises(NotImplementedError) { described_class.new.confirm?(prompt: 'ok?') }
    end
  end

  describe Tool::Confirmer::Terminal do
    around do |example|
      orig_in, orig_out = $stdin, $stdout
      $stdout = StringIO.new
      example.run
      $stdin, $stdout = orig_in, orig_out
    end

    def stdin_with(text)
      $stdin = StringIO.new(text)
    end

    it 'returns true for "y"' do
      stdin_with("y\n")
      assert_equal true, described_class.new.confirm?(prompt: 'go?')
    end

    it 'returns true for "yes"' do
      stdin_with("yes\n")
      assert_equal true, described_class.new.confirm?(prompt: 'go?')
    end

    it 'is case-insensitive: "Y", "YES", "Yes" all approve' do
      %w[Y YES Yes].each do |answer|
        stdin_with("#{answer}\n")
        assert_equal true, described_class.new.confirm?(prompt: 'go?'),
                     "expected #{answer.inspect} to approve"
      end
    end

    it 'strips surrounding whitespace before matching' do
      stdin_with("  yes  \n")
      assert_equal true, described_class.new.confirm?(prompt: 'go?')
    end

    it 'returns false for "n"' do
      stdin_with("n\n")
      assert_equal false, described_class.new.confirm?(prompt: 'go?')
    end

    it 'returns false for "no" (case-insensitive)' do
      %w[no NO No].each do |answer|
        stdin_with("#{answer}\n")
        assert_equal false, described_class.new.confirm?(prompt: 'go?')
      end
    end

    it 'returns false on EOF (Ctrl+D / empty stdin)' do
      stdin_with('')
      assert_equal false, described_class.new.confirm?(prompt: 'go?')
    end

    it 'reprompts on unrecognized input and honors the next answer' do
      stdin_with("maybe\nblank\nyes\n")
      assert_equal true, described_class.new.confirm?(prompt: 'go?')
      assert_includes $stdout.string, 'Please answer y or n: '
    end

    it 'reprompts on blank line, eventually returns false on EOF' do
      stdin_with("\n\n\n")
      assert_equal false, described_class.new.confirm?(prompt: 'go?')
    end

    it 'echoes the caller-composed prompt on its own line' do
      stdin_with("y\n")
      described_class.new.confirm?(prompt: 'OK to run bash: ls?')
      assert_includes $stdout.string, "\nOK to run bash: ls?\n"
    end
  end

  describe Tool::Confirmer::AutoApprove do
    it 'returns true regardless of prompt' do
      assert_equal true, described_class.new.confirm?(prompt: 'anything')
      assert_equal true, described_class.new.confirm?(prompt: '')
    end
  end

  describe 'singleton constants' do
    it 'TERMINAL is a Terminal instance' do
      assert_instance_of Tool::Confirmer::Terminal, Tool::Confirmer::TERMINAL
    end

    it 'AUTO_APPROVE is an AutoApprove instance' do
      assert_instance_of Tool::Confirmer::AutoApprove, Tool::Confirmer::AUTO_APPROVE
    end
  end
end
