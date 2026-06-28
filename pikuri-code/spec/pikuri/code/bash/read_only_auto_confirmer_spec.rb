# frozen_string_literal: true

RSpec.describe Pikuri::Code::Bash::ReadOnlyAutoConfirmer do
  # Records whether it was consulted and returns a configured answer, so
  # we can distinguish "auto-approved without asking" from "delegated".
  class RecordingConfirmer < Pikuri::Workspace::Confirmer
    attr_reader :calls

    def initialize(answer)
      super()
      @answer = answer
      @calls = []
    end

    def confirm?(request:)
      @calls << request
      @answer
    end
  end

  def req(command)
    Pikuri::Workspace::Confirmer::Request.new(question: 'OK to run bash', detail: "$ #{command}")
  end

  describe 'auto-approves provably read-only commands' do
    # These approve regardless of the inner confirmer — proven by wiring
    # an inner that would say NO and asserting the result is still true
    # and the inner was never consulted.
    %w[
      ls
      ls\ -la\ /etc
      cat\ /etc/hostname
      grep\ -i\ error\ /var/log/syslog
      rg\ --hidden\ pattern\ /home/u/notes
      df\ -h
      du\ -sh\ /home/u/Music
      ps\ aux
      free\ -m
      uname\ -a
      stat\ /etc/fstab
      head\ -n20\ /var/log/dmesg
      printenv\ HOME
      grep\ --color=never\ foo\ /tmp/x
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        inner = RecordingConfirmer.new(false)
        confirmer = described_class.new(inner)
        assert confirmer.confirm?(request: req(cmd)),
               "expected auto-approval for #{cmd.inspect}"
        assert_empty inner.calls, "should not consult the human for #{cmd.inspect}"
      end
    end
  end

  describe 'delegates everything not provably read-only' do
    {
      'pipe'                 => 'ls | rm -rf /',
      'semicolon chain'      => 'ls; rm -rf ~',
      'and chain'            => 'cat x && rm y',
      'command substitution' => 'echo $(rm -rf ~)',
      'backtick'             => 'echo `rm -rf ~`',
      'output redirect'      => 'echo pwned > /etc/passwd',
      'append redirect'      => 'echo x >> ~/.bashrc',
      'glob'                 => 'ls *.txt',
      'tilde expansion'      => 'ls ~/secret',
      'brace expansion'      => 'rm -rf {a,b}',
      'leading env assign'   => 'FOO=bar ls',
      'relative path binary' => './ls',
      'absolute path binary' => '/bin/ls -la',
      'rm'                   => 'rm -rf /',
      'find -delete'         => 'find . -name x -delete',
      'sort -o (writes)'     => 'sort -o out.txt in.txt',
      'systemctl stop'       => 'systemctl stop sshd',
      'journalctl --vacuum'  => 'journalctl --vacuum-time=1s',
      'git mutation'         => 'git reset --hard',
      'dd'                   => 'dd if=/dev/zero of=/dev/sda',
      'tee (writes)'         => 'tee /etc/hosts',
      'env (runs program)'   => 'env FOO=bar ls'
    }.each do |label, cmd|
      it "delegates: #{label} (#{cmd.inspect})" do
        inner = RecordingConfirmer.new(true)
        confirmer = described_class.new(inner)
        result = confirmer.confirm?(request: req(cmd))

        assert_equal 1, inner.calls.size,
                     "expected the human to be consulted for #{cmd.inspect}"
        assert result, 'delegated result should follow the inner confirmer (true here)'
      end
    end

    it 'propagates an inner rejection (returns false) when delegating' do
      inner = RecordingConfirmer.new(false)
      confirmer = described_class.new(inner)
      refute confirmer.confirm?(request: req('rm -rf /'))
      assert_equal 1, inner.calls.size
    end
  end

  describe 'edge cases' do
    it 'delegates when detail is nil (e.g. a non-Bash request)' do
      inner = RecordingConfirmer.new(true)
      confirmer = described_class.new(inner)
      req = Pikuri::Workspace::Confirmer::Request.new(question: 'OK to overwrite foo?', detail: nil)
      assert confirmer.confirm?(request: req)
      assert_equal 1, inner.calls.size
    end

    it 'delegates an empty command' do
      inner = RecordingConfirmer.new(true)
      confirmer = described_class.new(inner)
      assert confirmer.confirm?(request: req('   '))
      assert_equal 1, inner.calls.size
    end

    it 'still classifies when the "$ " echo prefix is absent' do
      # Robust to a caller that passes the bare command as detail.
      inner = RecordingConfirmer.new(false)
      confirmer = described_class.new(inner)
      bare = Pikuri::Workspace::Confirmer::Request.new(question: 'q', detail: 'ls -la')
      assert confirmer.confirm?(request: bare)
      assert_empty inner.calls
    end

    it 'is itself a Confirmer (duck-types into the seam)' do
      assert_kind_of Pikuri::Workspace::Confirmer, described_class.new(RecordingConfirmer.new(true))
    end
  end
end
