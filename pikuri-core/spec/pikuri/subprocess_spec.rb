# frozen_string_literal: true

require 'pathname'
require 'tempfile'
require 'tmpdir'

RSpec.describe Pikuri::Subprocess do
  # SIGTERM any leaked process groups between specs. Same API as the
  # production at_exit cleanup — no separate _for_test method needed.
  # Use the explicit class (not described_class) because nested describe
  # blocks below redefine described_class to Subprocess::Result.
  after { Pikuri::Subprocess.cleanup! }

  describe '.spawn / #wait' do
    it 'runs argv and returns combined output + status' do
      result = described_class.spawn('echo', 'hello', chdir: '/tmp').wait
      assert_equal "hello\n", result.output
      assert_equal 0, result.status.exitstatus
    end

    it 'redirects stderr onto stdout (combined output)' do
      result = described_class.spawn('bash', '-c', 'echo out; echo err >&2', chdir: '/tmp').wait
      assert_includes result.output, 'out'
      assert_includes result.output, 'err'
    end

    it 'returns non-zero exit status without raising' do
      result = described_class.spawn('false', chdir: '/tmp').wait
      assert_equal 1, result.status.exitstatus
    end

    it 'runs in the given working directory' do
      Dir.mktmpdir do |dir|
        expected = Pathname.new(dir).realpath.to_s
        result = described_class.spawn('/bin/pwd', chdir: dir).wait
        assert_equal "#{expected}\n", result.output
      end
    end

    it 'accepts a Pathname for chdir' do
      Dir.mktmpdir do |dir|
        result = described_class.spawn('echo', 'x', chdir: Pathname.new(dir)).wait
        assert_equal "x\n", result.output
      end
    end
  end

  describe '.run' do
    # The filter shape: stdin fed, stdout redirected to a file, stderr
    # captured as Result#output. Read the payload back by rewinding the
    # file — the child shares its offset.
    it 'feeds stdin_data and redirects stdout to the given file' do
      Tempfile.create('pikuri-run') do |out|
        result = described_class.run('cat', stdin_data: "hello\nworld\n",
                                            stdout: out, chdir: '/tmp')
        assert_equal 0, result.status.exitstatus
        out.rewind
        assert_equal "hello\nworld\n", out.read
      end
    end

    it 'captures stderr separately as Result#output' do
      Tempfile.create('pikuri-run') do |out|
        result = described_class.run('bash', '-c', 'cat; echo warn >&2',
                                     stdin_data: 'payload', stdout: out, chdir: '/tmp')
        assert_equal "warn\n", result.output
        out.rewind
        assert_equal 'payload', out.read
      end
    end

    it 'passes binary stdin_data through unmangled' do
      bytes = (0..255).to_a.pack('C*')
      Tempfile.create('pikuri-run') do |out|
        result = described_class.run('cat', stdin_data: bytes, stdout: out, chdir: '/tmp')
        assert result.status.success?
        out.rewind
        out.binmode
        assert_equal bytes, out.read
      end
    end

    it 'returns non-zero exit status without raising' do
      Tempfile.create('pikuri-run') do |out|
        result = described_class.run('false', stdin_data: '', stdout: out, chdir: '/tmp')
        assert_equal 1, result.status.exitstatus
      end
    end

    it 'survives a child that exits without draining stdin' do
      big = 'x' * (1 << 20) # > pipe buffer, so the writer hits EPIPE
      Tempfile.create('pikuri-run') do |out|
        result = described_class.run('true', stdin_data: big, stdout: out, chdir: '/tmp')
        assert result.status.success?
      end
    end

    it 'prunes its pgid after completion' do
      Tempfile.create('pikuri-run') do |out|
        described_class.run('cat', stdin_data: '', stdout: out, chdir: '/tmp')
        assert_empty described_class.active
      end
    end
  end

  describe 'handle attributes' do
    it 'exposes pid, pgid (== pid), and io before #wait' do
      sp = described_class.spawn('sleep', '0.05', chdir: '/tmp')
      assert sp.pid.is_a?(Integer) && sp.pid > 0
      assert_equal sp.pid, sp.pgid
      assert sp.io.is_a?(IO)
      sp.wait
    end
  end

  describe 'process-group tracking' do
    it 'spawns in a new process group (leader pid == pgid)' do
      sp = described_class.spawn('sleep', '0.05', chdir: '/tmp')
      pid_pgid = Process.getpgid(sp.pid)
      assert_equal sp.pid, pid_pgid
      sp.wait
    end

    it 'registers the pgid in .active during execution' do
      sp = described_class.spawn('sleep', '5', chdir: '/tmp')
      assert_includes described_class.active, sp.pgid
      # .cleanup! in after kills the sleep
    end

    it 'prunes the pgid after #wait when no group members remain' do
      sp = described_class.spawn('echo', 'done', chdir: '/tmp')
      pgid = sp.pgid
      sp.wait
      refute_includes described_class.active, pgid
    end

    it 'keeps the pgid in .active when a backgrounded child outlives the direct child' do
      # The backgrounded sleep must redirect its stdout/stderr away from
      # our pipe; otherwise it inherits the pipe and our #wait blocks
      # until sleep ends. This is a real production limitation of the
      # Bash tool — documented in +lib/tool/bash.rb+'s "Backgrounded
      # subprocesses" RDoc section and surfaced to the LLM via the
      # tool description.
      sp = described_class.spawn('bash', '-c', 'sleep 5 >/dev/null 2>&1 &', chdir: '/tmp')
      pgid = sp.pgid
      sp.wait
      assert_includes described_class.active, pgid
    end
  end

  describe '#terminate' do
    it 'SIGTERMs the group of a daemon child without blocking' do
      sp = described_class.spawn('sleep', '5', chdir: '/tmp')
      sp.terminate
      # SIGTERM delivery is async; poll briefly for the child to die.
      deadline = Time.now + 2
      sleep 0.02 while Time.now < deadline && (Process.kill(0, sp.pid) rescue false)
      refute(begin
        Process.kill(0, sp.pid)
      rescue Errno::ESRCH
        false
      end, 'child should be dead after terminate')
    end

    it 'is idempotent on an already-dead child' do
      sp = described_class.spawn('true', chdir: '/tmp')
      sp.wait
      sp.terminate # must not raise
      sp.terminate
    end
  end

  describe '.cleanup!' do
    it 'SIGTERMs all tracked process groups and clears the set' do
      described_class.spawn('sleep', '5', chdir: '/tmp')
      described_class.spawn('sleep', '5', chdir: '/tmp')
      refute_empty described_class.active

      described_class.cleanup!
      assert_empty described_class.active
    end

    it 'is a no-op when nothing is tracked' do
      described_class.cleanup!
      assert_empty described_class.active
    end
  end

  describe Pikuri::Subprocess::Result do
    it 'is a Data class with output and status' do
      r = described_class.new(output: 'x', status: nil)
      assert_equal 'x', r.output
      assert_nil r.status
    end
  end
end
