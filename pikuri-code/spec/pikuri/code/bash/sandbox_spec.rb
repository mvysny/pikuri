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

RSpec.describe Pikuri::Code::Bash::Sandbox do
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
    let(:workspace) { Pikuri::Workspace::Filesystem.new(project_root: root) }

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

    # Fires before the bwrap probe, so this test is bwrap-availability-
    # independent.
    it 'refuses construction when the workspace lists / as writable' do
      ws = Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root)
      err = assert_raises(RuntimeError) { described_class.new(workspace: ws) }
      assert_includes err.message, "lists '/' as"
      assert_includes err.message, 'Sandbox::NONE'
    end

    # Also fires before the bwrap probe — bwrap-availability-independent.
    it 'refuses construction when temp is set but alias_tmp_to_temp is off' do
      ws = Pikuri::Workspace::Filesystem.new(
        project_root: root, temp: true, alias_tmp_to_temp: false
      )
      begin
        err = assert_raises(RuntimeError) { described_class.new(workspace: ws) }
        assert_includes err.message, 'temp set'
        assert_includes err.message, 'alias_tmp_to_temp'
      ensure
        FileUtils.remove_entry(ws.temp.to_s) if ws.temp&.exist?
      end
    end

    # Probe-scheduling and probe-failure tests: stub Subprocess.spawn
    # to give us deterministic exit codes regardless of whether the
    # host actually has bwrap (let alone a recent-enough kernel for
    # overlayfs in user namespaces). Each block restores the original
    # method on the way out.
    describe 'bwrap probe' do
      def stub_subprocess_spawn(call_log:, results:)
        original = Pikuri::Subprocess.method(:spawn)
        result_struct = Struct.new(:status) do
          def wait; self; end
        end
        status_struct = Struct.new(:success?, :exitstatus)
        results = results.dup

        Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
          call_log << args
          ok, code = results.shift || [true, 0]
          result_struct.new(status_struct.new(ok, code))
        end
        original
      end

      def restore_subprocess_spawn(original)
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end

      it 'does NOT run the overlay probe when ephemeral_overlay is empty' do
        calls = []
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0]])
        begin
          described_class.new(workspace: workspace)
        ensure
          restore_subprocess_spawn(original)
        end

        bwrap_calls = calls.select { |argv| argv.first == 'bwrap' }
        assert_equal 1, bwrap_calls.size,
                     "expected only the basic bwrap probe, got #{bwrap_calls.size}: " \
                     "#{bwrap_calls.inspect}"
        refute_includes bwrap_calls.first, '--tmp-overlay',
                        'basic probe should not include --tmp-overlay'
      end

      it 'DOES run the overlay probe when ephemeral_overlay is non-empty' do
        overlay_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-probe-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [overlay_dir])

        calls = []
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0], [true, 0]])
        begin
          described_class.new(workspace: ws, ephemeral_overlay: [overlay_dir])
        ensure
          restore_subprocess_spawn(original)
          FileUtils.rm_rf(overlay_dir)
        end

        bwrap_calls = calls.select { |argv| argv.first == 'bwrap' }
        assert_equal 2, bwrap_calls.size,
                     "expected basic probe + overlay probe, got #{bwrap_calls.size}: " \
                     "#{bwrap_calls.inspect}"
        assert_includes bwrap_calls.last, '--tmp-overlay',
                        "second probe should include --tmp-overlay; got #{bwrap_calls.last.inspect}"
      end

      it 'surfaces a kernel-pointer error when the overlay probe fails' do
        overlay_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-probe-fail-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [overlay_dir])

        calls = []
        # First probe (basic) succeeds; second probe (overlay) fails.
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0], [false, 1]])
        begin
          err = assert_raises(RuntimeError) do
            described_class.new(workspace: ws, ephemeral_overlay: [overlay_dir])
          end
          assert_includes err.message, 'overlay probe failed'
          assert_includes err.message, '5.11',
                          'expected kernel-version hint in the message'
          assert_includes err.message, 'ephemeral_overlay: []',
                          'expected escape-hatch hint in the message'
        ensure
          restore_subprocess_spawn(original)
          FileUtils.rm_rf(overlay_dir)
        end
      end

      it 'does NOT run the overlay probe when the basic probe already failed' do
        calls = []
        # Basic probe fails; overlay probe must not be attempted.
        original = stub_subprocess_spawn(call_log: calls, results: [[false, 1]])
        begin
          assert_raises(RuntimeError) { described_class.new(workspace: workspace) }
        ensure
          restore_subprocess_spawn(original)
        end

        bwrap_calls = calls.select { |argv| argv.first == 'bwrap' }
        assert_equal 1, bwrap_calls.size,
                     'overlay probe must be gated on the basic probe succeeding'
      end
    end

    # Pre-bwrap-probe validation: the container-socket-exposure
    # check fires before check_bwrap! so these stay
    # availability-independent.
    describe 'container-socket exposure refusal' do
      # Surgically replace DENIED_CONTAINER_SOCKETS with one path
      # under a controllable tmpdir so we can build a workspace that
      # exposes it without touching real host paths.
      let(:fake_sock_root) { Pathname.new(Dir.mktmpdir('pikuri-sb-sockroot-')).realpath }
      let(:fake_sock) { fake_sock_root + 'docker.sock' }

      around do |example|
        FileUtils.touch(fake_sock.to_s)
        original = described_class::DENIED_CONTAINER_SOCKETS
        described_class.send(:remove_const, :DENIED_CONTAINER_SOCKETS)
        described_class.const_set(:DENIED_CONTAINER_SOCKETS, [fake_sock].freeze)
        begin
          example.run
        ensure
          described_class.send(:remove_const, :DENIED_CONTAINER_SOCKETS)
          described_class.const_set(:DENIED_CONTAINER_SOCKETS, original)
          FileUtils.rm_rf(fake_sock_root)
        end
      end

      it 'refuses construction when a workspace.readable root contains a denied socket' do
        # workspace.readable includes fake_sock_root → the bind would
        # carry fake_sock_root/docker.sock into the sandbox.
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [fake_sock_root])
        err = assert_raises(RuntimeError) { described_class.new(workspace: ws) }
        assert_includes err.message, 'container/VM control sockets'
        assert_includes err.message, fake_sock.to_s
        assert_includes err.message, 'root escape'
      end

      it 'refuses construction when a workspace.writable root contains a denied socket' do
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, writable: [fake_sock_root])
        err = assert_raises(RuntimeError) { described_class.new(workspace: ws) }
        assert_includes err.message, 'container/VM control sockets'
        assert_includes err.message, fake_sock.to_s
      end

      it 'refuses construction when the socket itself is bound as writable (direct match, not just ancestor)' do
        # Simulate someone mounting just the socket path. The
        # workspace constructor needs a real directory for project_root,
        # but readable/writable accept any existing path including a
        # regular file or socket. We point writable directly at the
        # socket file.
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, writable: [fake_sock])
        err = assert_raises(RuntimeError) { described_class.new(workspace: ws) }
        assert_includes err.message, fake_sock.to_s
      end

      it 'accepts a sibling path that does not expose the denied socket' do
        sibling = Pathname.new(Dir.mktmpdir('pikuri-sb-sibling-')).realpath
        begin
          # Workspace bind sibling, which does NOT contain fake_sock.
          ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [sibling])
          # Need a bwrap probe to actually run; without bwrap we'd
          # surface a different RuntimeError. Skip-then-assert pattern:
          # in the absence of bwrap we just confirm the socket check
          # passes (i.e. the error is the bwrap-not-found one).
          err = begin
            described_class.new(workspace: ws)
            nil
          rescue RuntimeError => e
            e
          end
          if err
            refute_includes err.message, 'container/VM control sockets',
                            'socket check must not fire for an unrelated workspace path'
          end
        ensure
          FileUtils.rm_rf(sibling)
        end
      end
    end

    it 'refuses construction when an ephemeral_overlay path is not in workspace.readable' do
      ws = Pikuri::Workspace::Filesystem.new(project_root: root)
      stray = Pathname.new(Dir.mktmpdir('pikuri-sb-stray-')).realpath
      begin
        err = assert_raises(RuntimeError) do
          described_class.new(workspace: ws, ephemeral_overlay: [stray])
        end
        assert_includes err.message, 'ephemeral_overlay'
        assert_includes err.message, 'workspace.readable'
      ensure
        FileUtils.rm_rf(stray)
      end
    end

    if BWRAP_AVAILABLE
      it 'constructs successfully when bwrap is available' do
        sandbox = described_class.new(workspace: workspace)
        assert_kind_of described_class, sandbox
      end

      it '#wrap emits --overlay-src/--overlay for ephemeral_overlay paths (not --ro-bind)' do
        overlay_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-overlay-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [overlay_dir])
        begin
          sandbox = described_class.new(workspace: ws, ephemeral_overlay: [overlay_dir])
          argv = sandbox.wrap(['true'])

          # The overlay path appears as --overlay-src <lower> followed by
          # --overlay <upper> <work> <dest>; the dest equals the lower.
          src_idx = argv.each_cons(2).find_index { |a, b| a == '--overlay-src' && b == overlay_dir.to_s }
          assert src_idx, "expected --overlay-src #{overlay_dir} in #{argv.inspect}"

          # --overlay <upper> <work> <dest> starts somewhere after src_idx
          ov_idx = argv.each_with_index.find { |arg, i| arg == '--overlay' && i > src_idx }&.last
          assert ov_idx, "expected --overlay after --overlay-src in #{argv.inspect}"
          upper = argv[ov_idx + 1]
          work  = argv[ov_idx + 2]
          dest  = argv[ov_idx + 3]
          assert_equal overlay_dir.to_s, dest
          assert upper.end_with?('/upper'), "expected upper ending /upper, got #{upper}"
          assert work.end_with?('/work'),   "expected work ending /work, got #{work}"
          # Upper + work live under the workspace umbrella so they get
          # swept with the rest of internal_temp at process exit.
          assert upper.start_with?(ws.internal_temp.to_s),
                 "expected upper under #{ws.internal_temp}, got #{upper}"
          assert work.start_with?(ws.internal_temp.to_s),
                 "expected work under #{ws.internal_temp}, got #{work}"
          assert File.directory?(upper), "expected #{upper} to exist on disk"
          assert File.directory?(work),  "expected #{work} to exist on disk"

          # The path must NOT also appear as --ro-bind — that would be
          # the bug we're guarding against (double-mount / wrong semantics).
          refute argv.each_cons(2).any? { |a, b| a == '--ro-bind' && b == overlay_dir.to_s },
                 "did not expect --ro-bind #{overlay_dir} alongside the overlay: #{argv.inspect}"
        ensure
          FileUtils.rm_rf(overlay_dir)
          FileUtils.remove_entry(ws.internal_temp.to_s) if ws.internal_temp&.exist?
        end
      end

      it 'readable paths NOT in ephemeral_overlay still get --ro-bind' do
        plain_ro = Pathname.new(Dir.mktmpdir('pikuri-sb-ro-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [plain_ro])
        begin
          sandbox = described_class.new(workspace: ws)
          argv = sandbox.wrap(['true'])

          assert argv.each_cons(2).any? { |a, b| a == '--ro-bind' && b == plain_ro.to_s },
                 "expected --ro-bind #{plain_ro} in #{argv.inspect}"
        ensure
          FileUtils.rm_rf(plain_ro)
        end
      end

      it '#wrap composes the expected bwrap argv shape' do
        sandbox = described_class.new(workspace: workspace)
        argv = sandbox.wrap(['bash', '-c', 'echo hi'])

        assert_equal 'bwrap', argv.first
        # Workspace project_root is in writable; the bind for it should appear.
        assert argv.each_cons(2).any? { |a, b| a == '--bind' && b == root.to_s },
               "expected --bind #{root} in #{argv.inspect}"
        # Isolation flags
        assert_includes argv, '--unshare-all'
        assert_includes argv, '--share-net'
        assert_includes argv, '--die-with-parent'
        assert_includes argv, '--new-session'
        # Synthetic mounts — workspace has no temp, so /tmp falls back to tmpfs.
        assert argv.each_cons(2).any? { |a, b| a == '--tmpfs' && b == '/tmp' },
               "expected --tmpfs /tmp in #{argv.inspect}"
        # User argv preserved at the tail
        assert_equal 'bash', argv[-3]
        assert_equal '-c', argv[-2]
        assert_equal 'echo hi', argv[-1]
      end

      it '#wrap binds workspace.temp at /tmp when temp: true (NOT --tmpfs /tmp)' do
        ws = Pikuri::Workspace::Filesystem.new(
          project_root: root, temp: true, alias_tmp_to_temp: true
        )
        begin
          sandbox = described_class.new(workspace: ws)
          argv = sandbox.wrap(['true'])

          # /tmp is bound to the workspace temp (persistent across bash calls).
          assert argv.each_cons(3).any? { |a, b, c| a == '--bind' && b == ws.temp.to_s && c == '/tmp' },
                 "expected --bind #{ws.temp} /tmp in #{argv.inspect}"
          # The fallback tmpfs at /tmp is gone.
          refute argv.each_cons(2).any? { |a, b| a == '--tmpfs' && b == '/tmp' },
                 "did not expect --tmpfs /tmp when temp is set: #{argv.inspect}"
          # The temp host path is ALSO bound at its host path so file tools
          # and bash agree on a single canonical path.
          assert argv.each_cons(3).any? { |a, b, c| a == '--bind' && b == ws.temp.to_s && c == ws.temp.to_s },
                 "expected --bind #{ws.temp} #{ws.temp} in #{argv.inspect}"
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
