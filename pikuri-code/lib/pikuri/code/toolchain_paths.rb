# frozen_string_literal: true

module Pikuri
  module Code
    # Curated lists of filesystem prefixes a coding agent benefits
    # from seeing: system toolchains under +/usr+ and +/opt+, per-user
    # toolchain managers (mise/asdf/rbenv/pyenv/nvm/rustup), and the
    # per-user dependency caches the toolchains themselves mutate
    # (Gradle, Maven, Cargo, npm, pip, …). Not a tool — a
    # configuration helper that +bin/pikuri-code+ (and any downstream
    # coding binary built on pikuri-code) feeds into
    # +Pikuri::Workspace::Filesystem.new(readable: ...)+ alongside the
    # skill catalog's roots, and into
    # +Pikuri::Code::Bash::Sandbox::Bubblewrap.new(ephemeral_overlay: ...)+
    # for the overlay layer.
    #
    # The list is the "allowlist a coding agent reads" surface derived
    # from the threat-model discussion that drove this gem; see
    # +pikuri-workspace/lib/pikuri/workspace/filesystem.rb+ for the
    # containment story and CLAUDE.md's Scope decisions for the
    # Linux-first stance.
    #
    # == .readable vs. .ephemeral_overlay
    #
    # The split exists because the bubblewrap sandbox treats these two
    # groups differently:
    #
    # * {.readable} — true read-only: system toolchains (+/usr+,
    #   +/opt+) and per-user toolchain managers (+~/.rbenv+, +~/.pyenv+,
    #   +~/.nvm+, +~/.asdf+, +~/.rustup+, +~/.local/share/mise+, +~/.config/mise+).
    #   The user installed these out-of-band; the LLM should be able
    #   to grep them but neither write nor *appear* to write to them.
    #   Bubblewrap +--ro-bind+'s each.
    # * {.ephemeral_overlay} — per-user dependency caches the
    #   toolchain itself mutates when invoked: +~/.gradle+,
    #   +~/.m2/repository+, +~/.cargo/registry+, +~/.ivy2+,
    #   +~/go/pkg/mod+, +~/.cache/pip+, +~/.cache/uv+, +~/.npm+, the
    #   pnpm store, +~/.nuget/packages+. The toolchain *needs* to
    #   write to these (Gradle's journal/locks, Maven downloading a
    #   new dep, …), but persistent host pollution from a poisoned
    #   pikuri-code session would propagate to the user's other
    #   projects. The bubblewrap sandbox overlays each with a
    #   per-session ephemeral upper layer under
    #   +<workspace.internal_temp>/overlay-<slug>/+ — writes survive
    #   across bash calls within one session, then vanish at process
    #   exit. See {Pikuri::Code::Bash::Sandbox::Bubblewrap} for the
    #   wiring.
    #
    # The host-side workspace continues to include both lists in its
    # +readable+ set, so the LLM can Read/Grep/Glob them via the file
    # tools (which operate on the host filesystem, not the sandbox view).
    module ToolchainPaths
      # @return [Array<String>] absolute paths, in stable order, each
      #   one confirmed to be an existing directory at the moment of
      #   the call. Presence-filtered: a developer who doesn't have
      #   Rust installed doesn't get a phantom +~/.rustup+ in their
      #   workspace.
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
          File.join(home, '.rustup')
        ]
        candidates.select { |p| File.directory?(p) }.freeze
      end

      # @return [Array<String>] absolute paths to per-user dependency
      #   caches the toolchain mutates. Presence-filtered, same
      #   discipline as {.readable}: a missing +~/.gradle+ stays out
      #   of the list, on the assumption the user doesn't use Gradle
      #   (and Gradle's eventual bootstrap inside the sandbox without
      #   a host lower would fail noisily, which is what we want — see
      #   the rationale in {Pikuri::Code::Bash::Sandbox::Bubblewrap}).
      def self.ephemeral_overlay
        home = Dir.home
        candidates = [
          File.join(home, '.cargo/registry'),
          File.join(home, '.m2/repository'),
          File.join(home, '.gradle'),
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
