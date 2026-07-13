# frozen_string_literal: true

require 'pathname'

module Pikuri
  # Standardized on-disk locations for pikuri's local state, centralizing XDG
  # resolution so every disk-caching component roots under one place instead of
  # re-deriving it.
  module Paths
    # Pikuri's cache root: +$XDG_CACHE_HOME/pikuri+ or +~/.cache/pikuri+.
    #
    # A method, not a constant: a constant would snapshot +XDG_CACHE_HOME+ at
    # +require+ time, breaking env-stubbing in tests and a runtime change. Not
    # created — callers +mkdir_p+ the subdir they need.
    #
    # @return [Pathname] the +<cache home>/pikuri+ directory
    def self.cache
      home = ENV['XDG_CACHE_HOME']
      home = File.expand_path('~/.cache') if home.nil? || home.empty?
      Pathname.new(home).join('pikuri')
    end

    # Pikuri's config root: +$XDG_CONFIG_HOME/pikuri+ or +~/.config/pikuri+.
    # Home for user-owned, hand-edited config (the OS helper's +MACHINE.md+).
    #
    # A method for the same reason as {.cache}. Not created — config is
    # user-owned, so callers +mkdir_p+ only when writing.
    #
    # @return [Pathname] the +<config home>/pikuri+ directory
    def self.config
      home = ENV['XDG_CONFIG_HOME']
      home = File.expand_path('~/.config') if home.nil? || home.empty?
      Pathname.new(home).join('pikuri')
    end

    # Pikuri's state root: +$XDG_STATE_HOME/pikuri+ or +~/.local/state/pikuri+.
    # Created automatically. For state that persists across restarts but isn't
    # portable enough for XDG_DATA_HOME (logs, history, layout).
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
