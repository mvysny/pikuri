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

    # Pikuri's config root: +$XDG_CONFIG_HOME/pikuri+ when
    # +XDG_CONFIG_HOME+ is set and non-empty, else +~/.config/pikuri+.
    # Home for user-owned configuration the user is expected to read and
    # hand-edit (e.g. the OS helper's +MACHINE.md+ memory).
    #
    # A method, not a constant, for the same reason as {.cache} (no
    # +require+-time snapshot of the env). The directory is *not* created
    # — config is user-owned, so callers +mkdir_p+ only when actually
    # writing (e.g. +Paths.config.join('MACHINE.md')+).
    #
    # @return [Pathname] the +<config home>/pikuri+ directory
    def self.config
      home = ENV['XDG_CONFIG_HOME']
      home = File.expand_path('~/.config') if home.nil? || home.empty?
      Pathname.new(home).join('pikuri')
    end

    # Pikuri's state root: `~/.local/state/pikuri`. Created automatically.
    #
    # The place for state data that should persist between application restarts
    # but isn't important or portable enough to live in XDG_DATA_HOME. The examples
    # it gives include things like action history (logs, command history, recently-used
    # files) and the current state of an application (window layout, open files,
    # undo history).
    #
    # @return [Pathname] the +<state home>/pikuri+ directory
    def self.state
      state = ENV['XDG_STATE_HOME']
      state = File.expand_path('~/.local/state') if state.nil? || state.empty?
      state = Pathname.new(state).join('pikuri')
      FileUtils.mkdir_p(state.to_path)
      state
    end
  end
end
