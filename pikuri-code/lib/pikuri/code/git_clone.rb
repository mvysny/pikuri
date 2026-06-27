# frozen_string_literal: true

require 'fileutils'
require 'uri'

module Pikuri
  module Code
    # The +git_clone+ tool — shallow-clone a public git repository into
    # the workspace. Instantiating +Code::GitClone.new(filesystem: fs)+
    # produces a tool whose {Pikuri::Tool#to_ruby_llm_tool} wiring is
    # identical to any bundled tool's; +execute+ closes over the
    # filesystem and a lazily-minted {Bash::Sandbox::Bubblewrap}.
    #
    # == Why this exists
    #
    # The bundled +researcher+ persona can web_search / web_scrape /
    # fetch, which is great for "look up one fact" but inefficient when
    # the task is "dig through opencode's source for how it does X."
    # The pattern *N pages of HTML scraping* is much worse than
    # *one shallow clone + grep*. This tool plus
    # {Pikuri::Code::GIT_REPO_RESEARCHER} (the persona that wires it
    # together with workspace-scoped read/grep/glob) is the answer.
    #
    # == Threat model
    #
    # Git clone is not "just reading files." Hostile upstream has a
    # history of RCEs:
    #
    # * CVE-2024-32002 — submodule + symlink + case-insensitive FS
    #   escape → RCE.
    # * CVE-2022-39253 — +--local+ clone reading arbitrary host files
    #   via symlinks.
    # * CVE-2017-1000117 — +ssh://+ URL arg injection
    #   (+ssh://-oProxyCommand=...+) → arbitrary command execution.
    # * +.gitattributes+ filter drivers, +.git/config+ +core.fsmonitor+
    #   /+core.sshCommand+ — code paths that run during clone /
    #   checkout.
    #
    # Mitigations baked in here:
    #
    # 1. **HTTPS/HTTP only.** {VALID_SCHEMES} is +%w[https http]+;
    #    +ssh://+, +git://+, +file://+, +ext::+, and anything else are
    #    refused at the tool layer before +git+ sees the string.
    # 2. **No submodule recursion.** +--no-recurse-submodules+ kills
    #    the CVE-2024-32002 class.
    # 3. **Shallow clone.** +--depth 1+ skips history (fewer ref
    #    parsing edge cases, faster, smaller).
    # 4. **Bubblewrap-sandboxed subprocess.** The +git+ binary runs
    #    inside {Bash::Sandbox::Bubblewrap} bound to the persona's
    #    fresh temp workspace — no host +~/.ssh+, no +~/.gitconfig+,
    #    no other projects' source, no container sockets. A
    #    clone-RCE blast radius is the persona's throwaway workspace.
    #
    # The Bubblewrap instance is minted lazily on first +execute+,
    # not at construction — the boot-time GitClone wired by
    # +bin/pikuri-code+ never runs (it lives in the sub-agent-only
    # pool), and gets replaced by a fresh-workspace clone via
    # {#with_workspace} the moment a +git_repo_researcher+ session
    # starts. Eager construction would pay the ~+bwrap+ probe cost on
    # every coding-agent boot for no reason.
    #
    # == Output
    #
    # On success: a one-line ack with the relative path inside the
    # workspace. The persona then uses +read+ / +grep+ / +glob+ to
    # explore the clone.
    #
    # On failure: +"Error: ..."+ in the usual pikuri convention.
    # Possible causes: refused URL scheme, malformed URI, network
    # failure, target dir already exists, +git+ non-zero exit.
    class GitClone < Pikuri::Tool
      # URL schemes accepted. +https+ first (TLS) and +http+ as a
      # fallback for the rare public mirror. All other schemes are
      # refused — see the threat-model header.
      VALID_SCHEMES = %w[https http].freeze

      # Hard cap on the subprocess timeout (seconds). Real-world
      # shallow clones of medium repos finish in seconds; this is the
      # ceiling for a slow network or a large repo, after which we
      # SIGTERM.
      TIMEOUT_SECONDS = 120

      # @return [String]
      DESCRIPTION = <<~DESC
        Shallow-clone a public git repository into your workspace.

        Usage:
        - URL must be `https://` (preferred) or `http://`. Any other scheme (`ssh://`, `git://`, `file://`) is refused.
        - Always cloned with `--depth 1 --no-recurse-submodules`; you get the current tip, no history, no submodules.
        - Target directory name is derived from the URL's last segment (without `.git`). If that directory already exists, the call fails — pick a different URL or work with what you cloned.
        - On success returns the relative path to the cloned repo; use `read`, `grep`, `glob` to navigate it.
        - Clones run inside a sandbox bound to your workspace — host files, SSH keys, and `~/.gitconfig` are NOT visible to the cloned repo's hooks/filters.
      DESC

      # @param filesystem [Pikuri::Workspace::Filesystem] captured for
      #   the clone target root and the sandbox bind set.
      # @param sandbox [Bash::Sandbox, nil] optional sandbox override
      #   (defaults to a lazily-minted {Bash::Sandbox::Bubblewrap}
      #   bound to +filesystem+). Pass {Bash::Sandbox::NONE} in tests
      #   that don't have +bwrap+ on +PATH+; production wiring leaves
      #   it +nil+ so the Bubblewrap mint happens at the right moment
      #   (after {#with_workspace} replaces the filesystem).
      # @return [GitClone]
      def initialize(filesystem:, sandbox: nil)
        @filesystem = filesystem
        @sandbox = sandbox
        super(
          name: 'git_clone',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :url,
                              'HTTPS (or HTTP) git URL to clone, e.g. ' \
                              '"https://github.com/anomalyco/opencode" or ' \
                              '"https://github.com/anomalyco/opencode.git". ' \
                              'Other schemes are refused.'
          },
          execute: ->(url:) { execute_clone(url: url) }
        )
      end

      # Produce a new {GitClone} bound to the supplied workspace's
      # {Pikuri::Workspace::Filesystem}.
      #
      # The +with_workspace+ protocol ({Pikuri::SubAgent::SubAgentTool})
      # hands every rebuilt tool the session's {Pikuri::Workspace::Workspace}
      # *composite* — the right shape for the file tools, which resolve
      # paths and track a read record. GitClone is different: it drives a
      # {Bash::Sandbox::Bubblewrap}, which needs the bare {Filesystem}'s
      # +readable+/+writable+/+temp+ (the composite forwards only
      # +project_root+ / +resolve_for_*+). So we unwrap +.filesystem+ here;
      # a bare {Filesystem} is also accepted, for direct callers.
      #
      # The sandbox is NOT carried over — the new instance lazily mints a
      # fresh Bubblewrap from the new filesystem, since a sandbox's bind
      # set depends on the filesystem it constrains. See class header.
      #
      # @param workspace [Pikuri::Workspace::Workspace, Pikuri::Workspace::Filesystem]
      # @return [GitClone]
      def with_workspace(workspace)
        filesystem = workspace.respond_to?(:filesystem) ? workspace.filesystem : workspace
        self.class.new(filesystem: filesystem)
      end

      private

      # Mint the sandbox on first use, cache for subsequent calls.
      # See class header for why this isn't eager.
      def sandbox
        @sandbox ||= Bash::Sandbox::Bubblewrap.new(filesystem: @filesystem)
      end

      def execute_clone(url:)
        uri = parse_url(url)
        return uri if uri.is_a?(String) # error message

        target_name = derive_target_name(uri)
        target_path = @filesystem.project_root.join(target_name)
        if target_path.exist?
          return "Error: target directory #{target_name.inspect} already exists in the workspace."
        end

        argv = sandbox.wrap([
          'timeout', '--signal=TERM', '--kill-after=5s', "#{TIMEOUT_SECONDS}s",
          'git', 'clone', '--depth', '1', '--no-recurse-submodules', '--quiet',
          '--', url, target_name
        ])
        result = Pikuri::Subprocess.spawn(*argv, chdir: @filesystem.project_root.to_s).wait

        if result.status.success?
          "Cloned #{url} → #{target_name}/ (depth=1, no submodules)."
        else
          # Exit codes 124 / 137 / 125 = timeout (see Bash class header).
          ec = result.status.exitstatus
          tail = result.output.to_s.lines.last(20).join.strip
          if [124, 125, 137].include?(ec)
            "Error: git clone timed out after #{TIMEOUT_SECONDS}s.\n#{tail}"
          else
            "Error: git clone failed (exit #{ec}).\n#{tail}"
          end
        end
      end

      # Returns either a +URI+ on success or an +"Error: ..."+ string
      # on validation failure. Rejects non-+http(s)+ schemes, empty
      # host, and malformed URIs before +git+ ever sees the string.
      def parse_url(url)
        uri = URI.parse(url)
        unless VALID_SCHEMES.include?(uri.scheme)
          return "Error: only #{VALID_SCHEMES.join(' / ')} URLs are accepted (got #{uri.scheme.inspect})."
        end
        return 'Error: URL must include a host.' if uri.host.nil? || uri.host.empty?

        uri
      rescue URI::InvalidURIError => e
        "Error: malformed URL: #{e.message}"
      end

      # Last path segment, sans +.git+ suffix; falls back to +repo+
      # for path-less URLs. The basename is intentionally taken from
      # the parsed URI so path-traversal segments (+..+) in the URL
      # collapse to harmless directory names — the clone still lands
      # inside +filesystem.project_root+ because the +chdir+ + the
      # workspace containment check on subsequent reads enforce it.
      def derive_target_name(uri)
        name = File.basename(uri.path.to_s)
        name = name.sub(/\.git\z/, '')
        name = 'repo' if name.empty? || name == '/' || name == '.' || name == '..'
        name
      end
    end
  end
end
