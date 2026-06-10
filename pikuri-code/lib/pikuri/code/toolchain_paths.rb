# frozen_string_literal: true

module Pikuri
  module Code
    # Curated list of filesystem prefixes a coding agent benefits from
    # seeing: system toolchains under +/usr+ and +/opt+, per-user
    # toolchain managers (mise/asdf/rbenv/pyenv/nvm/rustup), and the
    # per-user dependency caches the toolchains themselves mutate
    # (Gradle, Maven, Cargo, npm, pip, …). Not a tool — a
    # configuration helper that +bin/pikuri-code+ (and any downstream
    # coding binary built on pikuri-code) feeds into
    # +Pikuri::Workspace::Filesystem.new(readable: ...)+ alongside the
    # skill catalog's roots.
    #
    # The list is the "allowlist a coding agent reads" surface derived
    # from the threat-model discussion that drove this gem; see
    # +pikuri-workspace/lib/pikuri/workspace/filesystem.rb+ for the
    # containment story and CLAUDE.md's Scope decisions for the
    # Linux-first stance.
    #
    # == One list, overlaid — not a readable-vs-writable split
    #
    # Earlier this module split the paths into "true read-only"
    # (toolchains) and "ephemeral overlay" (caches the toolchain
    # mutates). That split is gone: every entry here is mounted by
    # {Pikuri::Code::Bash::Sandbox::Bubblewrap} as a *read-write
    # ephemeral overlay* (when the kernel supports overlayfs in a user
    # namespace; read-only bind otherwise). The host's real dir is the
    # read-through lower; a per-session upper absorbs writes and is
    # discarded at process exit.
    #
    # The reason is that build tools assume their dirs are writable.
    # A read-only +~/.rbenv+ (or mise/asdf/system Ruby) breaks
    # +gem install+ / +bundle install+ with +EROFS+ — the gem install
    # target lives *inside* the version-manager dir, so there's no
    # separate cache to overlay. Overlaying the whole dir lets the
    # install succeed against an ephemeral copy: the toolchain writes,
    # the warm result survives across bash calls within the session,
    # and the host's real toolchain is never touched. The same
    # ephemerality that makes a writable +/usr+ safe (writes vanish at
    # exit, host untouched) is what makes "the LLM must not even appear
    # to write here" moot — so the old read-only treatment bought
    # nothing and cost a class of confusing failures.
    #
    # The host-side workspace includes this list in its +readable+ set,
    # so the LLM can Read/Grep/Glob the paths via the file tools (which
    # operate on the host filesystem, not the sandbox view). Writes the
    # LLM makes through bash land in the overlay and are *not* visible
    # to the host-reading file tools — the same accepted asymmetry the
    # cache overlays always had.
    #
    # == Why subdirs, not whole toolchain dirs
    #
    # The per-user dependency caches are listed as *content-only
    # subdirs* chosen to *exclude* the toolchain's credential /
    # persistence files. Even though the overlay is ephemeral, the
    # host's real file is the read-through lower — so a narrower mount
    # keeps secrets out of the sandbox's view entirely rather than
    # relying on "the write vanished." The exposed path holds cache
    # content (downloaded jars, distributions, modules); the excluded
    # paths hold secrets or build-config:
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
    # The version-manager roots (+~/.rbenv+, +~/.pyenv+, …) are listed
    # *whole* because they don't carry credential files — their gem /
    # package install targets live directly under them, so a narrower
    # mount would defeat the purpose. mise installs Ruby/Node under
    # +~/.local/share/mise/installs+, so overlaying +~/.local/share/mise+
    # covers mise-managed +gem install+; system Ruby installs under
    # +/usr+, covered by the +/usr+ overlay.
    module ToolchainPaths
      # @return [Array<String>] absolute paths, in stable order, each
      #   one confirmed to be an existing directory at the moment of
      #   the call. Presence-filtered: a developer who doesn't have
      #   Rust installed doesn't get a phantom +~/.rustup+ in their
      #   workspace, and a missing +~/.gradle/caches+ stays out (on the
      #   assumption the user doesn't use Gradle yet — its eventual
      #   bootstrap inside the sandbox without a host lower would fail
      #   noisily, which is what we want). The whole list is mounted as
      #   read-write ephemeral overlays by
      #   {Pikuri::Code::Bash::Sandbox::Bubblewrap}; see the module
      #   header for why each cache entry is a content-only subdir
      #   rather than the whole toolchain dir.
      def self.readable
        home = Dir.home
        candidates = [
          # System + per-user toolchains. Whole dirs — no credential
          # files live here, and gem/package install targets sit
          # directly under them.
          '/usr',
          '/opt',
          File.join(home, '.local/share/mise'),
          File.join(home, '.config/mise'),
          File.join(home, '.asdf'),
          File.join(home, '.rbenv'),
          File.join(home, '.pyenv'),
          File.join(home, '.nvm'),
          File.join(home, '.rustup'),
          # Per-user dependency caches the toolchain mutates. Each is a
          # content-only subdir that excludes the toolchain's
          # credential / persistence files — see the module header.
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
