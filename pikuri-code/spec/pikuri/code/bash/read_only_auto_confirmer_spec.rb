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

  describe 'auto-approves sequencer-joined chains of read-only commands' do
    # Every segment is independently a provably read-only invocation, so
    # the composition (&&, ||, ;, |) is read-only too.
    [
      'ls && pwd',
      'df -h && free -m',
      'cat a && cat b',
      'cd /home/u/notes && ls -la',
      'cd /etc && cat hostname && wc -l fstab',
      'ls&&pwd',                   # no spaces around the operator
      'ps aux | grep ssh',         # pipe
      'ls | wc -l',
      'cat a | grep b | head',     # multi-stage pipe
      'ls; pwd',                   # semicolon
      'df -h ; free -m',
      'ls || pwd',                 # logical-or
      'cd /etc && cat hostname | wc -l' # mixed operators
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
      'env (runs program)'   => 'env FOO=bar ls',
      # Sequencer segments that are not all provably read-only.
      'chain with mutation'  => 'ls && rm -rf ~',
      'chain hides git'      => 'cd notes && git diff', # git stays delegated
      'chain hides write'    => 'cd x && tee out',
      'triple-amp'           => 'ls &&& pwd',          # segment "& pwd" has a stray &
      'trailing &&'          => 'ls && ',              # empty trailing segment
      'leading &&'           => '&& ls',               # empty leading segment
      'quoted && literal'    => 'echo "a && b"',       # quotes trip the metachar check
      'over MAX_CHAIN'       => (['ls'] * 9).join(' && '),
      # A pipe grants no write/exec: the escalators aren't allowlisted.
      'pipe into xargs'      => 'ls | xargs rm',       # xargs not allowlisted
      'pipe into sh'         => 'ls | sh',             # sh not allowlisted
      'pipe into tee'        => 'cat x | tee y',       # tee writes
      'pipe then redirect'   => 'ps | grep x > out',   # redirect in last segment
      'pipe into dd'         => 'cat /dev/zero | dd of=x',
      'double-semicolon'     => 'ls ;; pwd',           # empty middle segment
      'background not seq'   => 'ls & pwd',            # single & not a sequencer; trips metachar
      'pipe-amp (stderr)'    => 'ls |& grep x'         # |& leaves a stray & → metachar
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

  describe 'with allow_git: true (trusted-repo read-only git)' do
    # Approved only because the caller asserted repo-config trust; the
    # human is never consulted (inner would REJECT, proving auto-approval).
    [
      'git diff',
      'git diff --cached',
      'git diff --staged',
      'git diff --stat',
      'git status',
      'git log -p',
      'git show HEAD',
      'git blame lib/foo.rb',
      'cd repo && git diff --cached', # composes with the sequencer split
      'git status | wc -l'            # composes with a read-only pipe
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        inner = RecordingConfirmer.new(false)
        confirmer = described_class.new(inner, allow_git: true)
        assert confirmer.confirm?(request: req(cmd)), "expected auto-approval for #{cmd.inspect}"
        assert_empty inner.calls, "should not consult the human for #{cmd.inspect}"
      end
    end

    # Trust neutralizes config-execution; it does NOT license destructive
    # git or config/repo-redirection/--output escapes — these still prompt.
    {
      'reset (destructive)'   => 'git reset --hard',
      'checkout (mutates)'    => 'git checkout .',
      'clean (deletes)'       => 'git clean -fd',
      'stash (mutates)'       => 'git stash',
      'commit (mutates)'      => 'git commit -m wip',
      'push (network/write)'  => 'git push',
      'config (writes)'       => 'git config user.email x',
      'tag (creates)'         => 'git tag v1',
      'branch -d (deletes)'   => 'git branch -d topic',
      'inline -c config'      => 'git -c core.pager=evil diff',  # global opt before verb
      'repo redirection -C'   => 'git -C /other diff',           # global opt before verb
      'diff --output= writes' => 'git diff --output=f',
      'diff --output writes'  => 'git diff --output f',
      'diff redirect'         => 'git diff > out',               # metachar, refused first
      'bare git'              => 'git'
    }.each do |label, cmd|
      it "delegates even with allow_git: #{label} (#{cmd.inspect})" do
        inner = RecordingConfirmer.new(true)
        confirmer = described_class.new(inner, allow_git: true)
        assert confirmer.confirm?(request: req(cmd))
        assert_equal 1, inner.calls.size, "expected the human to be consulted for #{cmd.inspect}"
      end
    end

    it 'still auto-approves the plain read-only binaries (git is additive)' do
      inner = RecordingConfirmer.new(false)
      confirmer = described_class.new(inner, allow_git: true)
      assert confirmer.confirm?(request: req('ls -la && cat foo'))
      assert_empty inner.calls
    end
  end

  describe 'with allow_git default (false) — git stays delegated' do
    %w[git\ diff git\ status git\ log].each do |cmd|
      it "delegates: #{cmd.inspect}" do
        inner = RecordingConfirmer.new(true)
        confirmer = described_class.new(inner) # allow_git omitted
        assert confirmer.confirm?(request: req(cmd))
        assert_equal 1, inner.calls.size
      end
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

  # bin/pikuri-code wires this wrapper onto Bash (Code::Extension) while
  # Write/Edit (Workspace::Extension) keep the bare human confirmer. The
  # asymmetry is the primary guard, but this pins the secondary one: even
  # if a Write request reached the wrapper, it is never auto-approved —
  # Write builds a Request with a question and NO detail (see
  # pikuri-workspace/lib/pikuri/workspace/write.rb), and a nil detail
  # delegates. So the same wrapper auto-approves a read-only command yet
  # always defers an overwrite to the human.
  describe 'shared-confirmer safety (pikuri-code wiring)' do
    it 'auto-approves a read-only command but defers a Write overwrite' do
      inner = RecordingConfirmer.new(false) # would REJECT if consulted
      confirmer = described_class.new(inner)

      # Read-only bash command: auto-approved, human never consulted.
      assert confirmer.confirm?(request: req('ps aux | grep ssh'))
      assert_empty inner.calls

      # Write's actual Request shape (overwrite question, nil detail):
      # delegated, so it follows the (rejecting) inner confirmer.
      overwrite = Pikuri::Workspace::Confirmer::Request.new(
        question: 'OK to overwrite lib/foo.rb: 100 → 120 bytes?'
      )
      refute confirmer.confirm?(request: overwrite)
      assert_equal 1, inner.calls.size
    end
  end
end
