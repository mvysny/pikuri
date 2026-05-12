# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Tool::Bash do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-bash-root-')).realpath }
  let(:workspace) { Tool::Workspace::Cwd.new(root: root) }
  let(:confirmer) { build_confirmer(true) }
  let(:tool)      { described_class.new(workspace: workspace, confirmer: confirmer) }

  after do
    FileUtils.rm_rf(root)
    # Belt and braces: kill any background subprocesses a spec spawned
    # past its #wait point (timeout tests in particular).
    Pikuri::Subprocess.cleanup!
  end

  # Inline confirmer double: records every prompt it sees, returns
  # successive elements of +answers+. Calling +confirm?+ when no answer
  # is queued raises — surfaces "test silently consumed a confirmation"
  # bugs rather than letting nil flow through as a false answer.
  def build_confirmer(*answers)
    queue   = answers.dup
    prompts = []
    cf = Object.new
    cf.define_singleton_method(:confirm?) do |prompt:|
      prompts << prompt
      raise "build_confirmer received an unexpected #confirm? call (prompt: #{prompt.inspect})" if queue.empty?

      queue.shift
    end
    cf.define_singleton_method(:prompts) { prompts }
    cf
  end

  describe '.run happy path' do
    it 'runs the command and returns command-echo + output + exit status' do
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'echo hello', description: nil, timeout: 120)

      assert_equal "$ echo hello\nhello\n\n\nexit status: 0", result
    end

    it 'combines stdout and stderr into one stream' do
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'echo out; echo err >&2',
                                   description: nil, timeout: 120)

      assert_includes result, 'out'
      assert_includes result, 'err'
      assert_includes result, 'exit status: 0'
    end

    it 'reports non-zero exit status as a normal observation (not an Error)' do
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'exit 3', description: nil, timeout: 120)

      refute result.start_with?('Error:'), "expected non-Error observation, got #{result.inspect}"
      assert_includes result, 'exit status: 3'
    end

    it 'runs in the workspace cwd' do
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'pwd', description: nil, timeout: 120)

      assert_includes result, root.to_s
    end
  end

  describe '.run confirmation' do
    it 'composes the three-line prompt with description and a non-default timeout' do
      cf = build_confirmer(true)

      described_class.run(workspace: workspace, confirmer: cf,
                          command: 'ls -la', description: 'List files',
                          timeout: 300)

      lines = cf.prompts.first.split("\n")
      assert_equal 3, lines.size
      assert_includes lines[0], 'OK to run bash: List files [Timeout: 300s]'
      assert_includes lines[1], '$ ls -la'
      assert_equal '(y/n)?', lines[2]
    end

    it 'drops the trailing colon when no description is given' do
      cf = build_confirmer(true)

      described_class.run(workspace: workspace, confirmer: cf,
                          command: 'pwd', description: nil, timeout: 120)

      lines = cf.prompts.first.split("\n")
      assert_includes lines[0], 'OK to run bash'
      refute_includes lines[0], 'OK to run bash:'
      refute_includes lines[0], 'Timeout'
    end

    it 'omits the timeout suffix at the default 120s' do
      cf = build_confirmer(true)

      described_class.run(workspace: workspace, confirmer: cf,
                          command: 'pwd', description: 'Print working dir',
                          timeout: 120)

      refute_includes cf.prompts.first, 'Timeout'
    end

    it 'includes the timeout suffix when non-default with no description' do
      cf = build_confirmer(true)

      described_class.run(workspace: workspace, confirmer: cf,
                          command: 'pwd', description: nil, timeout: 300)

      lines = cf.prompts.first.split("\n")
      assert_includes lines[0], '[Timeout: 300s]'
      refute_includes lines[0], 'bash:'
    end

    it 'treats whitespace-only description as no description' do
      cf = build_confirmer(true)

      described_class.run(workspace: workspace, confirmer: cf,
                          command: 'pwd', description: '   ', timeout: 120)

      refute_includes cf.prompts.first, 'OK to run bash:'
    end

    it 'returns a decline-Error when the user rejects' do
      cf = build_confirmer(false)

      result = described_class.run(workspace: workspace, confirmer: cf,
                                   command: 'rm -rf /', description: nil, timeout: 120)

      assert_equal 'Error: user declined the bash command.', result
      assert_equal 1, cf.prompts.size
    end
  end

  describe '.run input validation' do
    it 'rejects empty command before consulting the confirmer' do
      cf = build_confirmer # no answers queued

      result = described_class.run(workspace: workspace, confirmer: cf,
                                   command: '', description: nil, timeout: 120)

      assert_equal 'Error: empty bash command.', result
      assert_equal [], cf.prompts
    end

    it 'rejects whitespace-only command' do
      cf = build_confirmer
      result = described_class.run(workspace: workspace, confirmer: cf,
                                   command: "  \t\n  ", description: nil, timeout: 120)

      assert_equal 'Error: empty bash command.', result
      assert_equal [], cf.prompts
    end

    it 'rejects timeout < 1 before consulting the confirmer' do
      cf = build_confirmer
      result = described_class.run(workspace: workspace, confirmer: cf,
                                   command: 'echo hi', description: nil, timeout: 0)

      assert_equal 'Error: timeout must be >= 1, got 0', result
      assert_equal [], cf.prompts
    end

    it 'rejects timeout > MAX_TIMEOUT before consulting the confirmer' do
      cf = build_confirmer
      result = described_class.run(workspace: workspace, confirmer: cf,
                                   command: 'echo hi', description: nil, timeout: 601)

      assert_equal 'Error: timeout must be <= 600, got 601', result
      assert_equal [], cf.prompts
    end
  end

  describe '.run timeout' do
    it 'returns a timeout Error when the command exceeds the limit' do
      # 1s timeout, sleeping 3s: timeout sends SIGTERM, sleep handles it,
      # exits via signal — `timeout` exits 124.
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'sleep 3', description: nil, timeout: 1)

      assert result.start_with?('Error: command timed out after 1s'),
             "expected timeout Error, got #{result.inspect}"
      assert_includes result, 'SIGTERM, then SIGKILL'
      assert_includes result, '$ sleep 3'
    end

    it 'includes any partial output captured before the timeout' do
      # Print before sleeping so popen2e's pipe carries the line; then
      # block past the 1s timeout. Echo's stdout is line-buffered, so
      # the line lands before the sleep.
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'echo partial; sleep 3',
                                   description: nil, timeout: 1)

      assert result.start_with?('Error: command timed out'),
             "expected timeout Error, got #{result.inspect}"
      assert_includes result, 'partial'
    end
  end

  describe '.visible sanitization' do
    it 'preserves newlines (multi-line commands are normal)' do
      assert_equal "for x in 1 2 3; do\n  echo $x\ndone",
                   described_class.send(:visible, "for x in 1 2 3; do\n  echo $x\ndone")
    end

    it 'escapes carriage returns so the model cannot hide bytes via line overwrite' do
      assert_equal 'echo hi\\x0drm -rf /',
                   described_class.send(:visible, "echo hi\rrm -rf /")
    end

    it 'escapes ESC (the ANSI introducer)' do
      assert_equal 'echo \\x1b[2K',
                   described_class.send(:visible, "echo \e[2K")
    end

    it 'escapes NUL and DEL' do
      assert_equal 'a\\x00b\\x7fc',
                   described_class.send(:visible, "a\x00b\x7fc")
    end

    it 'leaves UTF-8 multibyte sequences alone' do
      assert_equal 'echo "héllo ✓"',
                   described_class.send(:visible, 'echo "héllo ✓"')
    end

    it 'the confirmation echo shows the visible form, not the raw bytes' do
      cf = build_confirmer(false)

      described_class.run(workspace: workspace, confirmer: cf,
                          command: "echo hi\rrm -rf /", description: nil, timeout: 120)

      assert_includes cf.prompts.first, '\\x0d'
      refute_includes cf.prompts.first, "\r"
    end
  end

  describe '.truncate' do
    it 'is a no-op when output fits within head + tail' do
      output = 'x' * (described_class::OUTPUT_HEAD + described_class::OUTPUT_TAIL)
      assert_equal output, described_class.send(:truncate, output)
    end

    it 'keeps head and tail and reports omitted + total bytes in the marker' do
      head_bytes = described_class::OUTPUT_HEAD
      tail_bytes = described_class::OUTPUT_TAIL
      total      = head_bytes + tail_bytes + 5000
      output     = ('H' * head_bytes) + ('M' * 5000) + ('T' * tail_bytes)

      truncated = described_class.send(:truncate, output)

      assert truncated.start_with?('H' * head_bytes)
      assert truncated.end_with?('T' * tail_bytes)
      assert_includes truncated, "[5000 bytes omitted; total was #{total} bytes]"
      refute_includes truncated, 'M'
    end
  end

  describe '.run output truncation (integration)' do
    it 'truncates oversized output via .truncate' do
      # Generate output large enough to trigger truncation: 32 KB > 30 KB cap.
      # Use a quick `printf` repetition; combined head+tail is 30 KB so this
      # exercises the cap with a small margin.
      result = described_class.run(workspace: workspace, confirmer: confirmer,
                                   command: 'yes x | head -c 32768',
                                   description: nil, timeout: 30)

      assert_includes result, 'bytes omitted'
      assert_includes result, 'exit status: 0'
    end
  end

  describe '.run workspace boundary' do
    it 'runs in the workspace cwd regardless of what the model passes in command' do
      # We don't path-resolve command args — bash itself interprets cd/etc.
      # But `chdir` for the spawn is fixed to workspace.cwd. Verify by
      # writing a file from inside the command via a relative path; it
      # should land under root.
      described_class.run(workspace: workspace, confirmer: confirmer,
                          command: "echo content > marker.txt",
                          description: nil, timeout: 30)

      assert (root + 'marker.txt').exist?
      assert_equal "content\n", (root + 'marker.txt').read
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a normal observation' do
      result = tool.run('command' => 'echo integ')

      assert_includes result, '$ echo integ'
      assert_includes result, 'integ'
      assert_includes result, 'exit status: 0'
    end

    it 'accepts timeout as an integer' do
      result = tool.run('command' => 'echo ok', 'timeout' => 30)

      assert_includes result, 'exit status: 0'
    end

    it 'accepts timeout as a numeric String (Parameters coerces)' do
      result = tool.run('command' => 'echo ok', 'timeout' => '30')

      assert_includes result, 'exit status: 0'
    end

    it 'accepts an optional description and propagates it to the confirmer' do
      cf = build_confirmer(true)
      t  = described_class.new(workspace: workspace, confirmer: cf)

      t.run('command' => 'echo desc', 'description' => 'Echo a token')

      assert_includes cf.prompts.first, 'Echo a token'
    end

    it 'reports a missing required command via the Parameters validator' do
      result = tool.run('description' => 'no command here')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'command'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('command' => 'echo ok', 'shell' => 'zsh')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'shell'
    end
  end

  describe 'parameters schema' do
    it 'advertises command as required string, description optional string, timeout optional integer' do
      schema = tool.parameters.to_h

      assert_equal %w[command], schema[:required]
      assert_equal 'string',  schema[:properties][:command][:type]
      assert_equal 'string',  schema[:properties][:description][:type]
      assert_equal 'integer', schema[:properties][:timeout][:type]
    end

    it 'wires through to_ruby_llm_tool under the "bash" name' do
      assert_equal 'bash', tool.to_ruby_llm_tool.name
    end
  end
end
