# frozen_string_literal: true

module Pikuri
  module Code
    # Curated list of read-only filesystem prefixes a coding agent
    # benefits from seeing: system toolchains under +/usr+ and +/opt+,
    # plus per-user toolchain managers and dependency caches
    # (mise/asdf/cargo/maven/gradle/go/...) under +$HOME+. Not a tool —
    # a configuration helper that +bin/pikuri-code+ (and any downstream
    # coding binary built on pikuri-code) feeds into
    # +Pikuri::Tool::Workspace.new(readable: ...)+ alongside the skill
    # catalog's roots.
    #
    # The list is the "allowlist a coding agent reads" surface derived
    # from the threat-model discussion that drove this gem; see
    # +pikuri-workspace/lib/pikuri/tool/workspace.rb+ for the
    # containment story and CLAUDE.md's Scope decisions for the
    # Linux-first stance.
    module ToolchainPaths
      # @return [Array<String>] absolute paths, in stable order, each one
      #   confirmed to be an existing directory at the moment of the call.
      #   The list is *presence-filtered*: any path that doesn't currently
      #   exist on disk is dropped silently — a developer who doesn't have
      #   Maven installed doesn't get a phantom +~/.m2/repository+ in
      #   their workspace.
      def self.readable
        home = Dir.home
        candidates = [
          '/usr',
          '/opt',
          File.join(home, '.local/share/mise'),
          File.join(home, '.config/mise'),
          File.join(home, '.asdf'),
          File.join(home, '.rbenv'),
          File.join(home, '.pyenv'),
          File.join(home, '.nvm'),
          File.join(home, '.rustup'),
          File.join(home, '.cargo/registry'),
          File.join(home, '.m2/repository'),
          File.join(home, '.gradle/caches'),
          File.join(home, '.ivy2'),
          File.join(home, 'go/pkg/mod'),
          File.join(home, '.cache/pip'),
          File.join(home, '.cache/uv'),
          File.join(home, '.npm'),
          File.join(home, '.local/share/pnpm/store'),
          File.join(home, '.nuget/packages')
        ]
        candidates.select { |p| File.directory?(p) }.freeze
      end
    end
  end
end
