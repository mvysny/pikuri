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
    #   toolchain itself mutates when invoked: subdirs of +~/.gradle+,
    #   +~/.m2/repository+, +~/.cargo/registry+, +~/.ivy2/cache+,
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
    #
    # == Why subdirs, not whole toolchain dirs
    #
    # Every entry in {.ephemeral_overlay} is a content-only subdir
    # chosen to *exclude* the toolchain's credential / persistence
    # files. The exposed path holds cache content (downloaded jars,
    # distributions, modules); the excluded paths hold secrets or
    # build-config:
    #
    #   * +~/.gradle/caches+ + +~/.gradle/wrapper/dists+ + +~/.gradle/jdks+
    #     — NOT +~/.gradle/gradle.properties+ (signing keys, OSSRH /
    #     GitHub Packages / Develocity tokens), NOT +~/.gradle/init.d+
    #     (persistence: any future +./gradlew+ outside pikuri would
    #     execute init scripts a poisoned session could plant here),
    #     NOT +~/.gradle/enterprise+ (Develocity access keys), NOT
    #     +~/.gradle/daemon+ (logs that can leak +-P+ project
    #     properties passed on the command line).
    #   * +~/.m2/repository+ — NOT +~/.m2/settings.xml+ (server creds).
    #   * +~/.cargo/registry+ — NOT +~/.cargo/credentials.toml+
    #     (crates.io publish tokens).
    #   * +~/.ivy2/cache+ — NOT +~/.ivy2/.credentials+ (resolver creds).
    #
    # +bwrap+ creates the parent dir (e.g. +~/.gradle/+) as an empty
    # tmpfs directory inside the sandbox automatically, so the
    # toolchain can mkdir new subdirs there (e.g. +~/.gradle/daemon/+)
    # without seeing anything we didn't bind. The cost is mild: dirs
    # outside the overlay list (+~/.gradle/daemon/+, native cache,
    # configuration cache) start empty each bash call instead of
    # persisting within a session. That's acceptable for daemon-style
    # caches — the warm-cache value lives in +caches/+ and +wrapper/+,
    # which the overlays cover.
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
      #   discipline as {.readable}: a missing +~/.gradle/caches+
      #   stays out of the list, on the assumption the user doesn't
      #   use Gradle yet (and Gradle's eventual bootstrap inside the
      #   sandbox without a host lower would fail noisily, which is
      #   what we want — see the rationale in
      #   {Pikuri::Code::Bash::Sandbox::Bubblewrap}). See the module
      #   header for why each entry is a content-only subdir rather
      #   than the whole toolchain dir.
      def self.ephemeral_overlay
        home = Dir.home
        candidates = [
          File.join(home, '.cargo/registry'),
          File.join(home, '.m2/repository'),
          # Gradle: caches/ (jar + journal + transforms + build-cache),
          # wrapper/dists/ (downloaded distributions), jdks/ (toolchain
          # auto-installs). gradle.properties / init.d / enterprise /
          # daemon are deliberately NOT exposed.
          File.join(home, '.gradle/caches'),
          File.join(home, '.gradle/wrapper/dists'),
          File.join(home, '.gradle/jdks'),
          # Ivy: cache only. ~/.ivy2/.credentials is deliberately NOT exposed.
          File.join(home, '.ivy2/cache'),
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
