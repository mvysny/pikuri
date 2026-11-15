# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::FileList do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-file-list-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }
  let(:tool)       { described_class.new(workspace: workspace) }

  after { FileUtils.rm_rf(root) }

  def list(path: nil, depth: 1)
    described_class.list(workspace: workspace, path: path, depth: depth).to_s
  end

  describe '.list' do
    it 'defaults to the workspace root when no path is given' do
      FileUtils.mkdir_p(root + 'lib')
      File.write(root + 'README.md', 'x' * 2048)

      assert_equal "lib/  [empty]\nREADME.md  2.0K", list
    end

    it 'lists a subdirectory relative to the workspace root' do
      FileUtils.mkdir_p(root + 'lib/inner')
      File.write(root + 'lib/a.rb', 'x')

      assert_equal "inner/  [empty]\na.rb  1B", list(path: 'lib')
    end

    it 'descends when depth is raised' do
      FileUtils.mkdir_p(root + 'lib/inner/deeper')

      assert_equal "lib/\n  inner/  [1 dir, 0 files]", list(depth: 2)
    end

    it 'caps depth rather than refusing it — the answer is just shallower' do
      FileUtils.mkdir_p(root + 'a/b/c/d/e')

      assert_equal list(depth: Pikuri::Workspace::Listing::MAX_DEPTH), list(depth: 99)
    end

    it 'reports an empty directory instead of returning nothing' do
      assert_equal '(Empty directory)', list
    end
  end

  describe 'refusals' do
    it 'refuses depth below 1' do
      assert_equal 'Error: depth must be >= 1, got 0', list(depth: 0)
    end

    it 'refuses a regular file and points at the read tool' do
      File.write(root + 'a.rb', 'x')

      assert_equal 'Error: a.rb is a file, not a directory; use the read tool to view it.',
                   list(path: 'a.rb')
    end

    it 'refuses a missing path' do
      assert_equal 'Error: path not found: nope', list(path: 'nope')
    end

    it 'converts workspace-boundary violations to "Error: ..." strings' do
      result = list(path: '../outside')

      assert result.start_with?('Error: '), result.inspect
    end

    # The oversized-root guard is Search::Utils'; this only pins that FileList
    # consults it, since a +readable:+ root can reach $HOME.
    it 'refuses an oversized root and hands back entries to pick from' do
      broad = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [Dir.home])
      ws = Pikuri::Workspace::Workspace.new(filesystem: broad)

      result = described_class.list(workspace: ws, path: Dir.home, depth: 1).to_s

      assert result.start_with?('Error: refusing to list'), result[0, 80].inspect
    end
  end

  describe 'tool integration (via #run)' do
    it 'produces a listing observation for the LLM' do
      FileUtils.mkdir_p(root + 'lib')

      assert_equal 'lib/  [empty]', tool.run({}).to_s
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run({ 'path' => 'lib', 'recursive' => true }).to_s

      assert_includes result, 'recursive'
    end

    it 'wires through to_ruby_llm_tool under the "file_list" name' do
      assert_equal 'file_list', tool.name
      assert_equal 'file_list', tool.to_ruby_llm_tool.name.to_s
    end
  end

  describe 'parameters schema' do
    it 'advertises path and depth as optional' do
      schema = tool.parameters.to_openai

      assert_equal %w[path depth], schema[:properties].keys.map(&:to_s)
      assert_empty schema[:required]
    end
  end
end
