# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Workspace::Confirmer do
  # Shorthand for a minimal Request; question defaults to 'go?'.
  def req(question = 'go?', detail: nil)
    Pikuri::Workspace::Confirmer::Request.new(question: question, detail: detail)
  end

  # An editable request (the author-seat shape used by the +agent+ tool).
  def editable_req(detail, question = 'Delegate?')
    Pikuri::Workspace::Confirmer::Request.new(question: question, detail: detail, editable: true)
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

    it 'defaults editable to false' do
      assert_equal false, described_class.new(question: 'OK?').editable
    end

    it 'defaults change to nil' do
      assert_nil described_class.new(question: 'OK?').change
    end

    it 'carries editable when set' do
      assert_equal true, described_class.new(question: 'OK?', detail: 't', editable: true).editable
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
      assert_includes $stdout.string, 'Please answer y, n, or r: '
    end

    it 'reprompts on blank line, eventually returns false on EOF' do
      stdin_with("\n\n\n")
      assert_equal false, described_class.new.confirm?(request: req)
    end

    it 'renders question, then cue, when there is no detail' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to overwrite a.txt: 4 → 6 bytes?'))
      assert_includes $stdout.string, "\nOK to overwrite a.txt: 4 → 6 bytes?\n[y] approve  [n] reject  [r] redirect\n"
    end

    it 'renders the detail on its own line between question and cue' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: '$ ls -la'))
      assert_includes $stdout.string, "\nOK to run bash\n$ ls -la\n[y] approve  [n] reject  [r] redirect\n"
    end

    it 'preserves newlines in a multi-line detail' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: "$ for x in 1 2; do\n  echo $x\ndone"))
      assert_includes $stdout.string, "$ for x in 1 2; do\n  echo $x\ndone\n[y] approve  [n] reject  [r] redirect\n"
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

    it 'surfaces a warning block when the sanitizer flags suspicious content' do
      stdin_with("n\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: "$ echo hi\rrm -rf /"))
      assert_includes $stdout.string, 'Suspicious content detected'
      assert_includes $stdout.string, 'Non-printable control bytes present'
    end

    it 'prints no warning block for a clean request' do
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: '$ ls -la'))
      refute_includes $stdout.string, 'Suspicious content detected'
    end

    it 'warns on a homoglyph spoof in the detail' do
      stdin_with("n\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: '$ curl https://Pаypal.com'))
      assert_includes $stdout.string, 'Mixed-script tokens present'
    end

    it 'bolds the question via Rainbow when color is enabled' do
      Rainbow.enabled = true
      stdin_with("y\n")
      described_class.new.confirm?(request: req('OK to run bash', detail: '$ ls'))
      assert_includes $stdout.string, "\e[1mOK to run bash\e[0m"
    end

    describe '#ask return type' do
      it 'returns Approved carrying the detail on a plain approve' do
        stdin_with("y\n")
        decision = described_class.new.ask(request: req('go?', detail: '$ ls'))
        assert_instance_of Pikuri::Workspace::Confirmer::Approved, decision
        assert_equal '$ ls', decision.new_request_detail
      end

      it 'returns Rejected on decline' do
        stdin_with("n\n")
        decision = described_class.new.ask(request: req)
        assert_instance_of Pikuri::Workspace::Confirmer::Rejected, decision
      end
    end

    describe 'redirect (typed words)' do
      it 'rejects at once on n, asking for no reason' do
        stdin_with("n\nnot read\n")
        assert_equal Pikuri::Workspace::Confirmer::Rejected.new, described_class.new.ask(request: req)
        assert_equal "not read\n", $stdin.gets
      end

      it 'returns Redirected carrying the typed words on r' do
        stdin_with("r\nuse the local docs\n")
        decision = described_class.new.ask(request: req)
        assert_equal Pikuri::Workspace::Confirmer::Redirected.new(message: 'use the local docs'), decision
        assert_includes $stdout.string, 'Tell the agent'
      end

      it 'backs off to Rejected when the words are left blank' do
        stdin_with("r\n  \n")
        assert_equal Pikuri::Workspace::Confirmer::Rejected.new, described_class.new.ask(request: req)
      end

      it 'backs off to Rejected on EOF after r' do
        stdin_with("r\n")
        assert_equal Pikuri::Workspace::Confirmer::Rejected.new, described_class.new.ask(request: req)
      end
    end

    describe 'editable task (author seat)' do
      it 'offers the edit cue for an editable request' do
        stdin_with("y\n")
        described_class.new.ask(request: editable_req('research foo'))
        assert_includes $stdout.string, '[y] approve  [e] edit  [n] reject  [r] redirect'
      end

      it 'approves as-is via [y], returning the original detail' do
        stdin_with("y\n")
        decision = described_class.new.ask(request: editable_req('research foo'))
        assert_instance_of Pikuri::Workspace::Confirmer::Approved, decision
        assert_equal 'research foo', decision.new_request_detail
      end

      it 'returns the edited text via [e], with pre-fill enabled for a clean task' do
        stdin_with("e\n")
        term = described_class.new
        captured_prefill = nil
        term.define_singleton_method(:read_edited) do |initial:, prefill:|
          captured_prefill = prefill
          "#{initial} (edited)"
        end
        decision = term.ask(request: editable_req('research foo'))
        assert_equal 'research foo (edited)', decision.new_request_detail
        assert_equal true, captured_prefill, 'a clean task pre-fills the editable buffer'
      end

      it 'refuses bare approve and forces a no-prefill retype for a flagged task' do
        # The \r makes the sanitizer flag the payload, so pre-fill is refused.
        stdin_with("y\ne\n") # 'y' is not accepted here; 'e' then edits
        term = described_class.new
        captured_prefill = nil
        term.define_singleton_method(:read_edited) do |initial:, prefill:|
          captured_prefill = prefill
          'retyped from scratch'
        end
        decision = term.ask(request: editable_req("bad\rtask"))
        assert_includes $stdout.string, 'retype required'
        assert_includes $stdout.string, 'Please answer e, n, or r: '
        assert_equal 'retyped from scratch', decision.new_request_detail
        assert_equal false, captured_prefill, 'a flagged task refuses pre-fill'
      end

      it 'rejects an editable task via [n]' do
        stdin_with("n\n")
        decision = described_class.new.ask(request: editable_req('research foo'))
        assert_equal Pikuri::Workspace::Confirmer::Rejected.new, decision
      end

      it 'redirects an editable task via [r], even a flagged one' do
        stdin_with("r\nnot now\n")
        decision = described_class.new.ask(request: editable_req("bad\rtask"))
        assert_equal Pikuri::Workspace::Confirmer::Redirected.new(message: 'not now'), decision
      end
    end

    describe 'change diff rendering' do
      it 'renders a unified diff of the change and approves on y' do
        stdin_with("y\n")
        change = Pikuri::Workspace::Confirmer::Change.new(
          path: 'a.txt', old: "one\ntwo\n", new: "one\nTWO\n"
        )
        assert_equal true,
                     described_class.new.confirm?(request: req('OK to write a.txt?').with(change: change))
        out = $stdout.string
        assert_includes out, '-two'
        assert_includes out, '+TWO'
      end

      it 'shows all lines added for a new file (old is nil)' do
        stdin_with("y\n")
        change = Pikuri::Workspace::Confirmer::Change.new(path: 'new.txt', old: nil, new: "hello\n")
        described_class.new.confirm?(request: req('OK to write new.txt?').with(change: change))
        assert_includes $stdout.string, '+hello'
      end
    end
  end

  describe Pikuri::Workspace::Confirmer::AutoApprove do
    it 'returns true regardless of request' do
      assert_equal true, described_class.new.confirm?(request: req('anything', detail: '$ rm -rf /'))
      assert_equal true, described_class.new.confirm?(request: req(''))
    end

    it 'returns Approved carrying the detail unchanged' do
      decision = described_class.new.ask(request: req('anything', detail: '$ rm -rf /'))
      assert_instance_of Pikuri::Workspace::Confirmer::Approved, decision
      assert_equal '$ rm -rf /', decision.new_request_detail
    end
  end

  describe 'singleton constants' do
    it 'AUTO_APPROVE is an AutoApprove instance' do
      assert_instance_of Pikuri::Workspace::Confirmer::AutoApprove, Pikuri::Workspace::Confirmer::AUTO_APPROVE
    end
  end
end
