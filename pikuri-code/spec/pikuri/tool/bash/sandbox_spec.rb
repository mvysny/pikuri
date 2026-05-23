# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# Probed once at file load. The `skip` idiom doesn't work cleanly with
# this project's Minitest-on-RSpec setup (Minitest::Skip bubbles as a
# failure), so we gate the bwrap-dependent describes at registration
# time instead of inside `it` blocks.
BWRAP_AVAILABLE = begin
  Pikuri::Subprocess.spawn('bwrap', '--version', chdir: '/').wait.status.success?
rescue Errno::ENOENT
  false
end

RSpec.describe Pikuri::Tool::Bash::Sandbox do
  describe described_class::NONE do
    it '#wrap returns argv unchanged' do
      argv = %w[timeout --signal=TERM 30s bash -c ls]
      assert_equal argv, described_class.wrap(argv)
    end

    it '#wrap returns the same array object (no copy)' do
      argv = ['bash', '-c', 'true']
      assert_same argv, described_class.wrap(argv)
    end
  end

  describe described_class::Bubblewrap do
    let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-sb-root-')).realpath }
    let(:workspace) { Pikuri::Workspace::Filesystem.new(anchor: root) }

    after do
      FileUtils.rm_rf(root)
      Pikuri::Subprocess.cleanup!
    end

    unless BWRAP_AVAILABLE
      it 'raises a clear RuntimeError when bwrap is missing' do
        err = assert_raises(RuntimeError) { described_class.new(workspace: workspace) }
        assert_includes err.message, "'bwrap' not found"
        assert_includes err.message, '--no-sandbox'
      end
    end

    if BWRAP_AVAILABLE
      it 'constructs successfully when bwrap is available' do
        sandbox = described_class.new(workspace: workspace)
        assert_kind_of described_class, sandbox
      end

      it '#wrap composes the expected bwrap argv shape' do
        sandbox = described_class.new(workspace: workspace)
        argv = sandbox.wrap(['bash', '-c', 'echo hi'])

        assert_equal 'bwrap', argv.first
        # Workspace anchor is in writable; the bind for it should appear.
        assert argv.each_cons(2).any? { |a, b| a == '--bind' && b == root.to_s },
               "expected --bind #{root} in #{argv.inspect}"
        # Isolation flags
        assert_includes argv, '--unshare-all'
        assert_includes argv, '--share-net'
        assert_includes argv, '--die-with-parent'
        assert_includes argv, '--new-session'
        # Synthetic mounts
        assert argv.each_cons(2).any? { |a, b| a == '--tmpfs' && b == '/tmp' },
               "expected --tmpfs /tmp in #{argv.inspect}"
        # User argv preserved at the tail
        assert_equal 'bash', argv[-3]
        assert_equal '-c', argv[-2]
        assert_equal 'echo hi', argv[-1]
      end

      it '#wrap includes the temp dir as a writable bind when temp: true' do
        ws = Pikuri::Workspace::Filesystem.new(anchor: root, temp: true)
        begin
          sandbox = described_class.new(workspace: ws)
          argv = sandbox.wrap(['true'])

          assert argv.each_cons(2).any? { |a, b| a == '--bind' && b == ws.temp.to_s },
                 "expected --bind #{ws.temp} in #{argv.inspect}"
        ensure
          FileUtils.remove_entry(ws.temp.to_s) if ws.temp.exist?
        end
      end

      it '#wrap exposes the OS-runtime baseline (/etc/ssl, etc.) when present' do
        sandbox = described_class.new(workspace: workspace)
        argv = sandbox.wrap(['true'])

        described_class::ETC_BASELINE.each do |p|
          next unless File.exist?(p)
          assert argv.each_cons(2).any? { |a, b| a == '--ro-bind' && b == p },
                 "expected --ro-bind #{p} in #{argv.inspect}"
        end
      end

      it 'end-to-end: bwrap-wrapped echo runs inside the sandbox' do
        sandbox = described_class.new(workspace: workspace)
        argv = sandbox.wrap(['bash', '-c', 'echo sandboxed'])
        result = Pikuri::Subprocess.spawn(*argv, chdir: root.to_s).wait

        assert result.status.success?, "spawn failed: #{result.output}"
        assert_includes result.output, 'sandboxed'
      end

      it 'end-to-end: the sandbox cannot see paths outside the workspace' do
        outside = Pathname.new(Dir.mktmpdir('pikuri-sb-outside-')).realpath
        begin
          File.write(outside + 'secret.txt', 'PEEKABOO')

          sandbox = described_class.new(workspace: workspace)
          argv = sandbox.wrap(['bash', '-c', "cat #{outside}/secret.txt 2>&1 || echo blocked"])
          result = Pikuri::Subprocess.spawn(*argv, chdir: root.to_s).wait

          refute_includes result.output, 'PEEKABOO',
                          'sandbox leaked an outside-the-workspace file: ' \
                          "#{result.output.inspect}"
        ensure
          FileUtils.rm_rf(outside)
        end
      end
    end
  end
end
