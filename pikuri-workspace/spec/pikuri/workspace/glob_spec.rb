# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Glob do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-glob-root-')).realpath }
  let(:workspace) { Pikuri::Workspace::Filesystem.new(anchor: root) }
  let(:tool)      { described_class.new(workspace: workspace) }

  after do
    FileUtils.rm_rf(root)
    Pikuri::Subprocess.cleanup!
  end

  def write_file(rel, content = '')
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  # Default kwargs for .search. Specs override one or two at a time.
  def search_args(**overrides)
    { workspace: workspace, pattern: '**/*', path: nil }.merge(overrides)
  end

  describe '.search basic matching' do
    it 'lists files matching a glob pattern across the workspace' do
      write_file('a.rb')
      write_file('lib/b.rb')
      write_file('lib/c.txt')

      result = described_class.search(**search_args(pattern: '**/*.rb'))

      assert_includes result, 'a.rb'
      assert_includes result, 'lib/b.rb'
      refute_includes result, 'c.txt'
      assert_includes result, 'Found 2 files.'
    end

    it 'singularizes the footer at 1 file' do
      write_file('only.rb')

      result = described_class.search(**search_args(pattern: '**/*.rb'))

      assert_includes result, 'Found 1 file.'
    end

    it 'supports brace alternation' do
      write_file('a.ts')
      write_file('b.tsx')
      write_file('c.txt')

      result = described_class.search(**search_args(pattern: '**/*.{ts,tsx}'))

      assert_includes result, 'a.ts'
      assert_includes result, 'b.tsx'
      refute_includes result, 'c.txt'
    end
  end

  describe '.search path narrowing' do
    it 'restricts search to the given subdirectory' do
      write_file('lib/keep.rb')
      write_file('spec/skip.rb')

      result = described_class.search(**search_args(pattern: '**/*.rb', path: 'lib'))

      assert_includes result, 'keep.rb'
      refute_includes result, 'skip.rb'
    end

    it 'outputs paths relative to the workspace whether path is relative or absolute' do
      write_file('lib/sub/file.rb')

      result_rel = described_class.search(**search_args(pattern: '**/*.rb', path: 'lib'))
      result_abs = described_class.search(**search_args(pattern: '**/*.rb', path: (root + 'lib').to_s))

      assert_includes result_rel, 'sub/file.rb'
      assert_includes result_abs, 'sub/file.rb'
      refute_includes result_rel, root.to_s
      refute_includes result_abs, root.to_s
    end
  end

  describe '.search rejections' do
    it 'rejects an empty pattern' do
      result = described_class.search(**search_args(pattern: ''))

      assert_equal 'Error: empty pattern.', result
    end

    it 'rejects a path that is a regular file, pointing at the read tool' do
      write_file('lonely.rb')

      result = described_class.search(**search_args(pattern: '**/*.rb', path: 'lonely.rb'))

      assert result.start_with?('Error:'), "got #{result.inspect}"
      assert_includes result, 'is a file, not a directory'
      assert_includes result, 'read tool'
    end

    it 'rejects a nonexistent path before reaching rg' do
      result = described_class.search(**search_args(pattern: '**/*', path: 'does/not/exist'))

      assert_equal 'Error: path not found: does/not/exist', result
    end

    it 'rejects a path outside the workspace via a Workspace::Error rescue' do
      Dir.mktmpdir('pikuri-glob-outside-') do |outside|
        File.write(File.join(outside, 'leak.rb'), '')

        result = described_class.search(**search_args(pattern: '**/*.rb', path: outside))

        assert result.start_with?('Error:'), "got #{result.inspect}"
        assert_includes result, 'outside the workspace'
      end
    end
  end

  describe '.search no matches' do
    it 'returns a "No files match" string (not Error)' do
      write_file('a.rb')

      result = described_class.search(**search_args(pattern: '**/*.foo'))

      assert_equal "No files match pattern '**/*.foo'.", result
      refute result.start_with?('Error:')
    end

    it 'includes the path in the no-matches message when given' do
      write_file('lib/a.rb')

      result = described_class.search(**search_args(pattern: '**/*.foo', path: 'lib'))

      assert_equal "No files match pattern '**/*.foo' in lib.", result
    end
  end

  describe '.search .gitignore handling' do
    it 'respects .gitignore inside a git repo' do
      Pikuri::Subprocess.spawn('git', 'init', '-q', chdir: root.to_s).wait
      write_file('.gitignore', "ignored.rb\n")
      write_file('ignored.rb')
      write_file('visible.rb')

      result = described_class.search(**search_args(pattern: '**/*.rb'))

      assert_includes result, 'visible.rb'
      refute_includes result, 'ignored.rb'
    end
  end

  describe '.search hidden / VCS handling' do
    it 'includes hidden files because --hidden is set' do
      write_file('.dotfile')

      result = described_class.search(**search_args(pattern: '**/*'))

      assert_includes result, '.dotfile'
    end

    it 'excludes the .git/ directory even with --hidden and a permissive pattern' do
      # .git/* exclusion is appended last so it overrides re-inclusion
      # from a permissive user pattern (rg: last-matching-glob wins).
      Pikuri::Subprocess.spawn('git', 'init', '-q', chdir: root.to_s).wait
      write_file('visible.rb')

      result = described_class.search(**search_args(pattern: '**/*'))

      assert_includes result, 'visible.rb'
      refute_match(%r{\.git/}, result)
    end
  end

  describe '.search mtime ordering' do
    it 'returns newer files before older files' do
      old = write_file('old.rb')
      new = write_file('new.rb')
      # Force distinct mtimes — write speed makes them similar otherwise.
      File.utime(Time.now - 3600, Time.now - 3600, old)
      File.utime(Time.now,        Time.now,        new)

      result = described_class.search(**search_args(pattern: '**/*.rb'))
      idx_new = result.index('new.rb')
      idx_old = result.index('old.rb')

      refute_nil idx_new
      refute_nil idx_old
      assert idx_new < idx_old, "expected new.rb before old.rb, got:\n#{result}"
    end

    it 'breaks ties on equal mtimes by path ascending' do
      ts = Time.now - 60
      a = write_file('a.rb')
      b = write_file('b.rb')
      File.utime(ts, ts, a)
      File.utime(ts, ts, b)

      result = described_class.search(**search_args(pattern: '**/*.rb'))

      assert result.index('a.rb') < result.index('b.rb'),
             "expected a.rb before b.rb on tie, got:\n#{result}"
    end
  end

  describe '.search output formatting' do
    it 'strips the leading ./ from rg paths regardless of search root' do
      write_file('top.rb')
      write_file('lib/nested.rb')

      result = described_class.search(**search_args(pattern: '**/*.rb'))

      refute_match(%r{(\A|\n)\./}, result, "found leading ./ in output:\n#{result}")
      assert_includes result, 'top.rb'
      assert_includes result, 'lib/nested.rb'
    end
  end

  describe '.search truncation' do
    it 'head-truncates oversized output at the last newline boundary with a marker' do
      # Path ~52 bytes × 1500 files = ~78 KB, well over MAX_BYTES (50 KB).
      base = 'longish_subdir_name'
      1500.times do |i|
        write_file("#{base}/file_with_a_longer_name_#{format('%04d', i)}.txt")
      end

      result = described_class.search(**search_args(pattern: '**/*.txt'))

      assert_includes result, 'bytes omitted'
      assert_includes result, 'refine pattern or path'

      # No mid-line cut: every path row in the kept portion starts with
      # the directory prefix and ends with '.txt'.
      rows = result.lines.map(&:chomp).grep(%r{\A#{base}/})
      assert rows.all? { |r| r.end_with?('.txt') },
             "expected every kept row to end in .txt, got tails: " \
               "#{rows.reject { |r| r.end_with?('.txt') }.last(5).inspect}"
    end

    it 'is a no-op when output fits within MAX_BYTES' do
      write_file('a.rb')

      result = described_class.search(**search_args(pattern: '**/*.rb'))

      refute_includes result, 'bytes omitted'
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a listing with footer' do
      write_file('a.rb')
      write_file('b.rb')

      result = tool.run('pattern' => '**/*.rb')

      assert_includes result, 'a.rb'
      assert_includes result, 'b.rb'
      assert_includes result, 'Found 2 files.'
    end

    it 'reports a missing required pattern via the Parameters validator' do
      result = tool.run('path' => '.')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'pattern'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('pattern' => '**/*', 'recursive' => true)

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'recursive'
    end
  end

  describe 'parameters schema' do
    it 'advertises the expected types and required set' do
      schema = tool.parameters.to_h

      assert_equal %w[pattern], schema[:required]
      assert_equal 'string', schema[:properties][:pattern][:type]
      assert_equal 'string', schema[:properties][:path][:type]
    end

    it 'wires through to_ruby_llm_tool under the "glob" name' do
      assert_equal 'glob', tool.to_ruby_llm_tool.name
    end
  end
end
