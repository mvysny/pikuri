# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Grep do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-grep-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }
  let(:tool)      { described_class.new(workspace: workspace) }

  after do
    FileUtils.rm_rf(root)
    Pikuri::Subprocess.cleanup!
  end

  def write_file(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  # Default kwargs for .search. Specs override one or two at a time.
  def search_args(**overrides)
    {
      workspace: workspace, pattern: 'alpha', path: nil, glob: nil,
      case_insensitive: false, output_mode: 'content'
    }.merge(overrides)
  end

  describe '.search content mode' do
    it 'returns path:line:content rows with a summary footer' do
      write_file('a.txt', "alpha\nbeta\n")
      write_file('sub/b.txt', "alpha here\nalpha again\n")

      result = described_class.search(**search_args)

      assert_equal "a.txt:1:alpha\nsub/b.txt:1:alpha here\nsub/b.txt:2:alpha again\n\n" \
                   'Found 3 matches in 2 files.',
                   result
    end

    it 'singularizes the footer at 1 match / 1 file' do
      write_file('only.txt', "alpha\nbeta\n")

      result = described_class.search(**search_args)

      assert_includes result, 'Found 1 match in 1 file.'
    end

    it 'forces filename emission even when path is a single file' do
      # rg defaults to suppressing the filename when searching one file;
      # --with-filename keeps the output shape consistent.
      write_file('single.txt', "alpha line\n")

      result = described_class.search(**search_args(path: 'single.txt'))

      assert_includes result, 'single.txt:1:alpha line'
    end

    it 'outputs paths relative to the workspace, regardless of how path was passed' do
      write_file('sub/c.txt', "alpha in sub\n")

      result_rel = described_class.search(**search_args(path: 'sub'))
      result_abs = described_class.search(**search_args(path: (root + 'sub').to_s))

      assert_includes result_rel, 'c.txt:1:alpha in sub'
      assert_includes result_abs, 'c.txt:1:alpha in sub'
      refute_includes result_rel, root.to_s
      refute_includes result_abs, root.to_s
    end
  end

  describe '.search files_with_matches mode' do
    it 'returns one path per file and a file-count footer' do
      write_file('a.txt', "alpha\n")
      write_file('b.txt', "alpha here\nalpha again\n")
      write_file('c.txt', "no match\n")

      result = described_class.search(**search_args(output_mode: 'files_with_matches'))

      assert_equal "a.txt\nb.txt\n\nFound 2 files.", result
    end

    it 'singularizes at 1 file' do
      write_file('only.txt', "alpha\nalpha\n")

      result = described_class.search(**search_args(output_mode: 'files_with_matches'))

      assert_includes result, 'Found 1 file.'
    end
  end

  describe '.search count mode' do
    it 'returns path:count per file with a match-and-file-count footer' do
      write_file('a.txt', "alpha\nbeta\n")
      write_file('b.txt', "alpha\nalpha\nalpha\n")

      result = described_class.search(**search_args(output_mode: 'count'))

      assert_equal "a.txt:1\nb.txt:3\n\nFound 4 matches in 2 files.", result
    end
  end

  describe '.search glob filter' do
    it 'restricts matches to files matching glob' do
      write_file('keep.rb',  "alpha in rb\n")
      write_file('skip.txt', "alpha in txt\n")

      result = described_class.search(**search_args(glob: '*.rb'))

      assert_includes result, 'keep.rb:1:alpha in rb'
      refute_includes result, 'skip.txt'
    end
  end

  describe '.search case_insensitive' do
    it 'matches both cases when on' do
      write_file('mixed.txt', "Alpha\nALPHA\nalpha\n")

      result = described_class.search(**search_args(pattern: 'alpha', case_insensitive: true))

      assert_includes result, 'mixed.txt:1:Alpha'
      assert_includes result, 'mixed.txt:2:ALPHA'
      assert_includes result, 'mixed.txt:3:alpha'
      assert_includes result, 'Found 3 matches'
    end

    it 'is case-sensitive by default' do
      write_file('mixed.txt', "Alpha\nALPHA\nalpha\n")

      result = described_class.search(**search_args(pattern: 'alpha', case_insensitive: false))

      assert_includes result, 'mixed.txt:3:alpha'
      refute_includes result, 'Alpha'
      refute_includes result, 'ALPHA'
    end
  end

  describe '.search no matches' do
    it 'returns a "No matches" string (not Error) on exit 1' do
      write_file('a.txt', "nothing here\n")

      result = described_class.search(**search_args(pattern: 'nonexistent'))

      assert_equal "No matches for pattern 'nonexistent'.", result
      refute result.start_with?('Error:')
    end

    it 'includes the path in the no-matches message when given' do
      write_file('sub/a.txt', "nothing here\n")

      result = described_class.search(**search_args(pattern: 'absent', path: 'sub'))

      assert_equal "No matches for pattern 'absent' in sub.", result
    end
  end

  describe '.search input validation' do
    it 'rejects an empty pattern' do
      result = described_class.search(**search_args(pattern: ''))

      assert_equal 'Error: empty pattern.', result
    end

    it 'rejects an unknown output_mode listing the valid set' do
      result = described_class.search(**search_args(output_mode: 'bogus'))

      assert result.start_with?('Error:'), "got #{result.inspect}"
      assert_includes result, 'output_mode must be one of content, files_with_matches, count'
      assert_includes result, '"bogus"'
    end

    it 'reports a bad regex via rg (exit 2)' do
      write_file('a.txt', "anything\n")

      result = described_class.search(**search_args(pattern: '['))

      assert result.start_with?('Error: ripgrep:'), "got #{result.inspect}"
      assert_includes result, 'regex parse error'
    end

    it 'caps an oversized exit-2 error blob at MAX_BYTES' do
      # rg emits one diagnostic line per unreadable path; a search that
      # escapes into a tree full of broken symlinks / permission denials
      # (e.g. ~/.local/share/docker overlay snapshots) can produce
      # hundreds of KB of stderr. Untruncated, it overflows the model's
      # context — so the error path must share the success path's cap.
      huge_error = (1..20_000).map { |i| "rg: /x/#{i}: IO error (os error 2)" }.join("\n") + "\n"
      status = Struct.new(:exitstatus, :success?).new(2, false)
      fake = Struct.new(:output, :status).new(huge_error, status)
      spawner = Object.new
      spawner.define_singleton_method(:wait) { fake }

      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) { |*_a, **_k| spawner }
      begin
        result = described_class.search(**search_args)
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end

      assert result.start_with?('Error: ripgrep:'), "got #{result[0, 80].inspect}"
      assert_includes result, 'bytes omitted'
      assert result.bytesize <= described_class::MAX_BYTES + 200,
             "error blob not capped: #{result.bytesize} bytes"
    end
  end

  describe '.search workspace boundary' do
    it 'rejects a path outside the workspace via a Workspace::Error rescue' do
      Dir.mktmpdir('pikuri-grep-outside-') do |outside|
        File.write(File.join(outside, 'leak.txt'), "alpha\n")

        result = described_class.search(**search_args(path: outside))

        assert result.start_with?('Error:'), "got #{result.inspect}"
        assert_includes result, 'outside the workspace'
      end
    end

    it 'rejects a nonexistent path before reaching rg' do
      result = described_class.search(**search_args(path: 'does/not/exist'))

      assert_equal 'Error: path not found: does/not/exist', result
    end
  end

  describe '.search truncation' do
    it 'head-truncates oversized output at the last newline boundary with a marker' do
      # One match per line × N lines, each ~30 bytes → cross 50 KB.
      # Use a pattern that fires on every line; ~2500 matches gets us
      # comfortably past MAX_BYTES.
      huge = (1..2500).map { |i| "line #{i} HIT" }.join("\n") + "\n"
      write_file('big.txt', huge)

      result = described_class.search(**search_args(pattern: 'HIT'))

      assert_includes result, 'bytes omitted'
      assert_includes result, 'refine pattern or path'
      # No mid-line cut: every match row in the truncated body ends
      # with the literal 'HIT' from our fixture content. A partial
      # cut would leave a row ending in 'HI' or similar.
      match_rows = result.lines.grep(/\Abig\.txt:\d+:/).map(&:chomp)
      assert match_rows.all? { |row| row.end_with?('HIT') },
             "expected every match row to end in HIT, got tails: " \
               "#{match_rows.reject { |r| r.end_with?('HIT') }.inspect}"
    end

    it 'is a no-op when output fits within MAX_BYTES' do
      write_file('small.txt', "alpha\n")

      result = described_class.search(**search_args)

      refute_includes result, 'bytes omitted'
    end
  end

  describe '.search long-line handling (delegated to rg)' do
    it 'truncates lines longer than MAX_LINE_LENGTH with an rg-emitted preview marker' do
      long_line = ('a' * 3000) + 'NEEDLE' + ('b' * 3000)
      write_file('long.txt', long_line + "\n")

      result = described_class.search(**search_args(pattern: 'NEEDLE'))

      assert_includes result, 'long.txt:1:'
      assert_includes result, 'omitted'  # rg's preview marker
      # Sanity: the emitted line should not contain the full tail.
      refute_includes result, 'b' * 3000
    end
  end

  describe '.search default path' do
    it 'searches the workspace root when path is nil' do
      write_file('top.txt', "alpha at top\n")
      write_file('deep/nested.txt', "alpha deep\n")

      result = described_class.search(**search_args)

      assert_includes result, 'top.txt:1:alpha at top'
      assert_includes result, 'deep/nested.txt:1:alpha deep'
    end

    it 'honors .gitignore by default' do
      # rg respects .gitignore in repos. Need an actual git context.
      Pikuri::Subprocess.spawn('git', 'init', '-q', chdir: root.to_s).wait
      write_file('.gitignore', "ignored.txt\n")
      write_file('ignored.txt', "alpha ignored\n")
      write_file('visible.txt', "alpha visible\n")

      result = described_class.search(**search_args)

      assert_includes result, 'visible.txt:1:alpha visible'
      refute_includes result, 'ignored.txt'
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces content-mode output by default' do
      write_file('hit.rb', "alpha here\n")

      result = tool.run('pattern' => 'alpha')

      assert_includes result, 'hit.rb:1:alpha here'
      assert_includes result, 'Found 1 match in 1 file.'
    end

    it 'accepts case_insensitive as a boolean' do
      write_file('hit.rb', "ALPHA\n")

      result = tool.run('pattern' => 'alpha', 'case_insensitive' => true)

      assert_includes result, 'hit.rb:1:ALPHA'
    end

    it 'accepts case_insensitive as the literal String "true"' do
      write_file('hit.rb', "ALPHA\n")

      result = tool.run('pattern' => 'alpha', 'case_insensitive' => 'true')

      assert_includes result, 'hit.rb:1:ALPHA'
    end

    it 'reports a missing required pattern via the Parameters validator' do
      result = tool.run('path' => '.')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'pattern'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('pattern' => 'x', 'regex' => true)

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'regex'
    end
  end

  describe 'parameters schema' do
    it 'advertises the expected types and required set' do
      schema = tool.parameters.to_openai

      assert_equal %w[pattern], schema[:required]
      assert_equal 'string',  schema[:properties][:pattern][:type]
      assert_equal 'string',  schema[:properties][:path][:type]
      assert_equal 'string',  schema[:properties][:glob][:type]
      assert_equal 'boolean', schema[:properties][:case_insensitive][:type]
      assert_equal 'string',  schema[:properties][:output_mode][:type]
    end

    it 'wires through to_ruby_llm_tool under the "grep" name' do
      assert_equal 'grep', tool.to_ruby_llm_tool.name
    end
  end
end
