# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# A file-index backend for the tool specs: answers +hits+ / +text+ and
# records every call, so a spec can see which folders a search was bounded to
# and which path a read asked for:
#
#   backend = FakeBackend.build(hits: [{ path: '/r/a.txt', snippet: 'x', text_size: 1 }])
#   Pikuri::Fileindex::Search.search(query: 'x', backend: backend, roots: roots)
#   backend.calls   # => [[:search, { query: 'x', limit: 10, folders: ['/r'] }]]
module FakeBackend
  # @param hits [Array<Hash>] what +search+ answers
  # @param text [String, nil] what +read_text+ answers
  # @param error [String, nil] when set, +search+ raises its +CommandError+
  #   with this message
  # @return [Module]
  def self.build(hits: [], text: nil, error: nil)
    Module.new do
      const_set(:CommandError, Class.new(StandardError))
      calls = []
      define_singleton_method(:calls) { calls }
      define_singleton_method(:label) { 'fake' }
      define_singleton_method(:limitations) { 'FAKE BLIND SPOTS' }
      define_singleton_method(:search) do |**args|
        calls << [:search, args]
        raise self::CommandError, error if error

        hits
      end
      define_singleton_method(:read_text) do |path|
        calls << [:read_text, path]
        text
      end
    end
  end
end

# A temp folder tree to root the tools at, with the shapes a model's path can
# escape through: a sibling folder, a symlink out, a hidden folder.
#
#   docs/            the root
#   docs/tax/        a subfolder
#   docs/note.txt    a file
#   docs/.hidden/    hidden below the root
#   docs/link -> work
#   work/            outside the root
module RootTree
  # @yieldparam tmp [String] the tree's real path
  # @return [void]
  def self.with
    Dir.mktmpdir do |tmp|
      tmp = File.realpath(tmp)
      %w[docs/tax docs/.hidden work].each { |dir| FileUtils.mkdir_p(File.join(tmp, dir)) }
      File.write(File.join(tmp, 'docs/note.txt'), 'a note')
      File.symlink(File.join(tmp, 'work'), File.join(tmp, 'docs/link'))
      yield tmp
    end
  end
end
