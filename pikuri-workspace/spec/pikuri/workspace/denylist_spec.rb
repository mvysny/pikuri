# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# The credential denylist across every tool that can surface a path.
#
# `resolve_for_read` only ever sees a path the *model* supplied, so for a long
# time it was the whole guard — and `grep 'BEGIN PRIVATE KEY'` returned what
# `read` refused to open, because a path the tool *walked* to reaches no
# `resolve_` call. Each tool below gets the same three questions, so a fifth
# path-walking tool is a copied block rather than a fresh think.
RSpec.describe 'credential denylist' do
  let(:home) { Pathname.new(Dir.mktmpdir('pikuri-denylist-')).realpath }
  let(:root) { home + 'proj' }

  # AllowAll is the only Filesystem with a denylist; a scoped one contains by
  # its readable/writable ceiling instead. DEFAULT_CREDENTIAL_DENYLIST is
  # home-anchored, so the in-workspace .ssh is listed explicitly here.
  let(:filesystem) do
    Pikuri::Workspace::Filesystem::AllowAll.new(
      project_root: root, denylist: [home + '.ssh', root + '.ssh']
    )
  end
  let(:workspace) { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }

  before do
    FileUtils.mkdir_p(home + '.ssh')
    File.write(home + '.ssh/id_rsa', "-----BEGIN PRIVATE KEY-----\nsecret\n")
    FileUtils.mkdir_p(root)
    File.write(root + 'ok.txt', 'BEGIN PRIVATE KEY is mentioned here too')
    # A denylisted subtree reachable *without* leaving the workspace root, and
    # the two symlink decoys that motivate resolving before testing.
    FileUtils.mkdir_p(root + '.ssh')
    File.write(root + '.ssh/inner_key', "-----BEGIN PRIVATE KEY-----\ninner\n")
    File.symlink(home + '.ssh', root + 'decoy_dir')
    File.symlink(home + '.ssh/id_rsa', root + 'decoy_file')
  end

  after { FileUtils.rm_rf(home) }

  describe 'Filesystem#denied?' do
    it 'resolves symlinks before testing, so a decoy inside the workspace is caught' do
      assert filesystem.denied?(root + 'decoy_dir')
      assert filesystem.denied?(root + 'decoy_file')
    end

    it 'is false for ordinary paths' do
      refute filesystem.denied?(root + 'ok.txt')
    end

    it 'is always false on a scoped Filesystem, which has no denylist' do
      scoped = Pikuri::Workspace::Filesystem.new(project_root: root)

      refute scoped.denied?(root + '.ssh/inner_key')
      assert_empty scoped.denied_roots
    end
  end

  describe 'read' do
    it 'refuses a denied path' do
      result = Pikuri::Workspace::Read.read(workspace: workspace, path: '.ssh/inner_key',
                                            offset: 1, limit: 100)

      assert_includes result, 'denied credential location'
      refute_includes result, 'BEGIN PRIVATE KEY'
    end
  end

  describe 'file_list' do
    it 'marks a denied directory instead of descending into it' do
      result = Pikuri::Workspace::FileList.list(workspace: workspace, path: nil, depth: 3)

      assert_includes result, ".ssh/  #{Pikuri::Workspace::Listing::DENIED}"
      refute_includes result, 'inner_key'
    end

    it 'marks denied symlink decoys rather than following them' do
      result = Pikuri::Workspace::FileList.list(workspace: workspace, path: nil, depth: 3)

      assert_includes result, "decoy_dir/  #{Pikuri::Workspace::Listing::DENIED}"
      assert_includes result, "decoy_file  #{Pikuri::Workspace::Listing::DENIED}"
      refute_includes result, 'id_rsa'
    end

    it 'refuses when pointed straight at a denied path' do
      result = Pikuri::Workspace::FileList.list(workspace: workspace, path: '.ssh', depth: 1)

      assert_includes result, 'denied credential location'
    end
  end

  describe 'glob' do
    it 'omits denied paths from the match list' do
      result = Pikuri::Workspace::Search::Glob.search(workspace: workspace, pattern: '**/*',
                                                      path: nil)

      assert_includes result, 'ok.txt'
      refute_includes result, 'inner_key'
    end

    it 'omits them under include_gitignored too, where a negative glob could be overridden' do
      result = Pikuri::Workspace::Search::Glob.search(workspace: workspace, pattern: '**/*',
                                                      path: nil, include_gitignored: true)

      refute_includes result, 'inner_key'
    end
  end

  describe 'grep' do
    %w[content files_with_matches count].each do |mode|
      it "omits denied paths in #{mode} mode" do
        result = Pikuri::Workspace::Search::Grep.search(
          workspace: workspace, pattern: 'BEGIN PRIVATE KEY', path: nil, glob: nil,
          case_insensitive: false, output_mode: mode
        )

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
                                                      path: nil)

      assert_includes result, 'ok.txt'
      refute_includes result, 'inner_key'
    end

    it 'grep still omits denied file contents' do
      result = Pikuri::Workspace::Search::Grep.search(
        workspace: workspace, pattern: 'BEGIN PRIVATE KEY', path: nil, glob: nil,
        case_insensitive: false, output_mode: 'content'
      )

      refute_includes result, 'inner_key'
      refute_includes result, 'secret'
    end
  end

  describe 'an empty denylist stays empty' do
    # pikuri-os / pikuri-computer pass denylist: [] deliberately (bash under
    # FullFsNoNet sees the disk anyway, so a half-denylist would be theater).
    # This fix must not quietly re-close that door.
    let(:filesystem) do
      Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root, denylist: [])
    end

    it 'lists and searches credential paths as ordinary ones' do
      listing = Pikuri::Workspace::FileList.list(workspace: workspace, path: nil, depth: 2)
      grepped = Pikuri::Workspace::Search::Grep.search(
        workspace: workspace, pattern: 'BEGIN PRIVATE KEY', path: nil, glob: nil,
        case_insensitive: false, output_mode: 'files_with_matches'
      )

      assert_includes listing, 'inner_key'
      assert_includes grepped, 'inner_key'
      refute filesystem.denied?(root + '.ssh/inner_key')
    end
  end
end
