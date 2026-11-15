# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# The walked-path denylist across every tool that can surface a path.
#
# `resolve_for_read` only ever sees a path the *model* supplied, so a path a
# tool *walked* to (a listing row, an rg hit) must pass `Filesystem#denied?`
# before it is reported — otherwise `grep 'BEGIN PRIVATE KEY'` returns what
# `read` refused to open. Each tool below gets the same questions, so a fifth
# path-walking tool is a copied block rather than a fresh think.
RSpec.describe 'walked-path denylist' do
  let(:home) { Pathname.new(Dir.mktmpdir('pikuri-denylist-')).realpath }
  let(:root) { home + 'proj' }

  # pikuri's scoped Filesystem denies nothing; a whole-host host overrides
  # +denied?+ / +denied_roots+. Stub that override the way such a host
  # implements it — symlink-resolved, so the decoys below are caught.
  let(:filesystem) do
    fs = Pikuri::Workspace::Filesystem.new(project_root: root)
    denylist = [home + '.ssh', root + '.ssh']
    fs.define_singleton_method(:denied_roots) { denylist }
    fs.define_singleton_method(:denied?) do |path|
      real = begin
        Pathname.new(path).realpath
      rescue SystemCallError
        Pathname.new(path).expand_path.cleanpath
      end
      denylist.any? { |d| real == d || real.to_s.start_with?("#{d}#{File::SEPARATOR}") }
    end
    fs
  end
  let(:workspace) { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }

  before do
    FileUtils.mkdir_p(home + '.ssh')
    File.write(home + '.ssh/id_rsa', "-----BEGIN PRIVATE KEY-----\nsecret\n")
    FileUtils.mkdir_p(root)
    File.write(root + 'ok.txt', 'BEGIN PRIVATE KEY is mentioned here too')
    # A denylisted subtree reachable *without* leaving the workspace root, and
    # the two symlink decoys a listing would otherwise follow.
    FileUtils.mkdir_p(root + '.ssh')
    File.write(root + '.ssh/inner_key', "-----BEGIN PRIVATE KEY-----\ninner\n")
    File.symlink(home + '.ssh', root + 'decoy_dir')
    File.symlink(home + '.ssh/id_rsa', root + 'decoy_file')
  end

  after { FileUtils.rm_rf(home) }

  it 'is always false on a scoped Filesystem, which has no denylist' do
    scoped = Pikuri::Workspace::Filesystem.new(project_root: root)

    refute scoped.denied?(root + '.ssh/inner_key')
    assert_empty scoped.denied_roots
  end

  describe 'file_list' do
    it 'marks a denied directory instead of descending into it' do
      result = Pikuri::Workspace::FileList.list(workspace: workspace, path: nil, depth: 3).to_s

      assert_includes result, ".ssh/  #{Pikuri::Workspace::Listing::DENIED}"
      refute_includes result, 'inner_key'
    end

    it 'marks denied symlink decoys rather than following them' do
      result = Pikuri::Workspace::FileList.list(workspace: workspace, path: nil, depth: 3).to_s

      assert_includes result, "decoy_dir/  #{Pikuri::Workspace::Listing::DENIED}"
      assert_includes result, "decoy_file  #{Pikuri::Workspace::Listing::DENIED}"
      refute_includes result, 'id_rsa'
    end
  end

  describe 'glob' do
    it 'omits denied paths from the match list' do
      result = Pikuri::Workspace::Search::Glob.search(workspace: workspace, pattern: '**/*',
                                                      path: nil).to_s

      assert_includes result, 'ok.txt'
      refute_includes result, 'inner_key'
    end

    it 'omits them under include_gitignored too, where a negative glob could be overridden' do
      result = Pikuri::Workspace::Search::Glob.search(workspace: workspace, pattern: '**/*',
                                                      path: nil, include_gitignored: true).to_s

      refute_includes result, 'inner_key'
    end
  end

  describe 'grep' do
    %w[content files_with_matches count].each do |mode|
      it "omits denied paths in #{mode} mode" do
        result = Pikuri::Workspace::Search::Grep.search(
          workspace: workspace, pattern: 'BEGIN PRIVATE KEY', path: nil, glob: nil,
          case_insensitive: false, output_mode: mode
        ).to_s

        assert_includes result, 'ok.txt'
        refute_includes result, 'inner_key'
        refute_includes result, 'secret'
      end
    end
  end

  # The rg --glob pruning is an optimization that can go silently partial (a
  # denied root outside the search root, an rg flag change). These pin that the
  # in-Ruby filter alone still holds, which is the whole point of the layering.
  describe 'with rg-side pruning disabled' do
    around do |example|
      utils = Pikuri::Workspace::Search::Utils
      globs = utils.method(:denied_globs)
      prefixes = utils.method(:denied_prefixes)
      utils.define_singleton_method(:denied_globs) { |**| [] }
      begin
        example.run
      ensure
        utils.define_singleton_method(:denied_globs, globs)
        utils.define_singleton_method(:denied_prefixes, prefixes)
      end
    end

    it 'glob still omits denied paths' do
      result = Pikuri::Workspace::Search::Glob.search(workspace: workspace, pattern: '**/*',
                                                      path: nil).to_s

      assert_includes result, 'ok.txt'
      refute_includes result, 'inner_key'
    end

    it 'grep still omits denied file contents' do
      result = Pikuri::Workspace::Search::Grep.search(
        workspace: workspace, pattern: 'BEGIN PRIVATE KEY', path: nil, glob: nil,
        case_insensitive: false, output_mode: 'content'
      ).to_s

      refute_includes result, 'inner_key'
      refute_includes result, 'secret'
    end
  end
end
