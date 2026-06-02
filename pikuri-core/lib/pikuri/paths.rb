# frozen_string_literal: true

require 'pathname'

module Pikuri
  # Standardized on-disk locations for pikuri's local state. Centralizes
  # the XDG resolution so every component that caches to disk roots under
  # one place instead of each re-deriving it — currently
  # {Pikuri::VectorDb::Server::Chroma} (its corpus volume) and
  # {Pikuri::Memory::Mem0Server} (its mem0 checkout + data volume).
  module Paths
    # Pikuri's cache root: +$XDG_CACHE_HOME/pikuri+ when +XDG_CACHE_HOME+
    # is set and non-empty, else +~/.cache/pikuri+.
    #
    # A method, not a frozen constant, on purpose: a constant would
    # snapshot +XDG_CACHE_HOME+ at +require+ time, which breaks
    # env-stubbing in tests and ignores a runtime change in a long-lived
    # process. The directory is *not* created — callers +mkdir_p+ the
    # subdirectory they need (e.g. +Paths.cache.join('chroma')+,
    # +Paths.cache.join('mem0')+).
    #
    # @return [Pathname] the +<cache home>/pikuri+ directory
    def self.cache
      home = ENV['XDG_CACHE_HOME']
      home = File.expand_path('~/.cache') if home.nil? || home.empty?
      Pathname.new(home).join('pikuri')
    end
  end
end
