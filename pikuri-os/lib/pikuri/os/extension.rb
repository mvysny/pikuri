# frozen_string_literal: true

module Pikuri
  module Os
    # One-call wiring for the offline OS-helper agent. Adding this single
    # extension to an +Agent.new+ block gives the complete surface — the
    # five workspace file tools, +bash+ (net-severable, with the read-only
    # command approver), the file-index tools, and the machine grounding +
    # +MACHINE.md+ memory folded into the system prompt. The +bin/+ script
    # and the planned TUI / web clients all wire the agent through this one
    # object rather than re-deriving the toolset and confirmation policy.
    #
    # == Composition
    #
    # It is a composite: +configure+ adds {Pikuri::Workspace::Extension}
    # and {Pikuri::Code::Extension} as sub-extensions (the configurator runs
    # their +configure+ immediately and still fires their +bind+ /
    # +on_user_message+), then layers on the OS-specific tools and prompt
    # sections. Reusing those two extensions means the file-tool and bash
    # wiring lives in one place each, not duplicated here.
    #
    # == Confirmation policy
    #
    # The caller passes the *human* confirmer (e.g.
    # {Pikuri::Workspace::Confirmer::Terminal}). The file tools get it via
    # {Pikuri::Workspace::Extension} with +confirm_all_writes: true+: since
    # this agent roams the full disk (no containment), *every* writable
    # Write/Edit confirms with a diff and an unwritable target
    # short-circuits to "ask the user to sudo" (see {Pikuri::Workspace::WriteGate}
    # and the guide's ch7). +Bash+ gets that same human confirmer plus a
    # {Pikuri::Code::Bash::ReadOnlyCommandApprover} as its +command_approver+,
    # so provably read-only commands run without a prompt and everything else
    # still reaches the human — the conservative half of the
    # confirmation-fatigue answer. So bash mutations and file-tool writes are
    # on the same page: both always confirm.
    #
    # The approver is built with +allow_git: true+, so read-only git verbs
    # (+status+ / +diff+ / +log+ / +show+ / +blame+ / ...) also skip the
    # prompt — there is no per-repo trust prompt. That is safe here *only because*
    # {Pikuri::Code::Bash} hardens the git subprocess environment
    # ({Pikuri::Code::Bash::GIT_HARDENING}): a hostile repo-local
    # +core.fsmonitor+ is neutralized regardless of what the repo's
    # +.git/config+ says, which is the vector that fires on a plain
    # +git status+. The accepted residual is diff-driver execution
    # (+diff.external+ / +.gitattributes+-selected +textconv+) on a repo
    # whose +.git/config+ an attacker wrote — env can't disable those
    # cleanly, and we don't rewrite the model's command to inject
    # +--no-ext-diff+. A plain +git clone+ never copies the remote's
    # config, so the residual is confined to non-clone-delivered repos.
    # See {Pikuri::Code::Bash::ReadOnlyCommandApprover}'s +allow_git:+ yardoc.
    #
    # == Sandbox
    #
    # The +sandbox+ is the caller's choice (default {NONE} — a safe library
    # default). The OS-helper binary passes
    # {Pikuri::Code::Bash::Sandbox::FullFsNoNet} for the net-severed,
    # full-filesystem posture; that decision (and its fail-loud probe) lives
    # in the binary, not here, so a TUI / web host can isolate differently.
    #
    # == Degradation
    #
    # The file-index tools need a usable index backend. The extension tries
    # each of {FILE_INDEX_BACKENDS} in order and wires the tools on the
    # first that is {LocalSearch.available? usable} — {LocalSearch} (GNOME,
    # zero-setup) first, then {Recoll} (DE-independent, but only when it has
    # a built index). When none is usable it logs a warning and simply omits
    # the tools — the agent still works (bash + file tools); it doesn't fail
    # to construct on a host with no file index.
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Os::Extension')

      # @return [Array<Module>] file-index backends in preference order; the
      #   first one whose +#available?+ is true backs the fileindex tools.
      FILE_INDEX_BACKENDS = [LocalSearch, Recoll].freeze

      # @param filesystem [Pikuri::Workspace::Filesystem] the host fs view
      #   for the file tools and bash (typically
      #   {Pikuri::Workspace::Filesystem::AllowAll} for full-host access).
      # @param confirmer [Pikuri::Workspace::Confirmer] the *human*
      #   confirmer; Bash is auto-gated on top of it (see "Confirmation
      #   policy").
      # @param sandbox [Pikuri::Code::Bash::Sandbox] bash subprocess
      #   isolation; defaults to {Pikuri::Code::Bash::Sandbox::NONE}.
      # @param read_only [Pikuri::Workspace::ReadOnly, nil] the shared
      #   read-only flag; when present it is threaded into both
      #   {Pikuri::Workspace::Extension} (gates Write/Edit) and
      #   {Pikuri::Code::Extension} (wires plan mode), so one instance
      #   drives the whole posture. +nil+ leaves plan mode unavailable.
      # @param memory [MachineMemory] the MACHINE.md reader.
      # @param system_info [SystemInfo] the boot-time machine facts.
      # @param file_index_backends [Array<Module>] file-index backends in
      #   preference order; defaults to {FILE_INDEX_BACKENDS}. The first
      #   usable one backs the fileindex tools; if none is usable they are
      #   omitted.
      def initialize(filesystem:, confirmer:,
                     sandbox: Pikuri::Code::Bash::Sandbox::NONE, read_only: nil,
                     memory: MachineMemory.new, system_info: SystemInfo.new,
                     file_index_backends: FILE_INDEX_BACKENDS)
        @filesystem = filesystem
        @confirmer = confirmer
        @sandbox = sandbox
        @read_only = read_only
        @memory = memory
        @system_info = system_info
        @file_index_backends = file_index_backends
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        c.add_extension(Pikuri::Workspace::Extension.new(
                          filesystem: @filesystem, confirmer: @confirmer, read_only: @read_only,
                          confirm_all_writes: true
                        ))
        c.add_extension(Pikuri::Code::Extension.new(
                          filesystem: @filesystem,
                          confirmer: @confirmer,
                          command_approver: Pikuri::Code::Bash::ReadOnlyCommandApprover.new(allow_git: true),
                          sandbox: @sandbox,
                          read_only: @read_only
                        ))

        backend = @file_index_backends.find(&:available?)
        if backend
          c.add_tool FileindexSearch.new(backend: backend)
          c.add_tool FileindexRead.new(backend: backend)
        else
          tried = @file_index_backends.map(&:label).join(' / ')
          LOGGER.warn("no usable file index (tried #{tried}); fileindex_search / " \
                      'fileindex_read disabled on this host.')
        end

        nil
      end

      # Two grounding sections: the machine facts and the MACHINE.md
      # notes (or an affordance pointing the agent at where to record
      # them). The system-info section is memoized at its source so a
      # re-pull on clear is free; the memory section is read **fresh**, so
      # MACHINE.md edits surface on a "/clear" — the durable notes stay
      # current across a conversation reset. The nested Workspace / Code
      # extensions (added in {#configure}) contribute their own snippets
      # independently.
      #
      # @return [Array<String>]
      def system_prompt_snippets
        [@system_info.prompt_section, @memory.prompt_section || empty_memory_affordance]
      end

      private

      # System-prompt line shown when MACHINE.md doesn't exist yet, so the
      # agent still knows where to record durable facts.
      #
      # @return [String]
      def empty_memory_affordance
        <<~SECTION.chomp
          # Notes about this machine

          No durable notes recorded yet. You can record lasting facts about this
          computer's setup by creating and editing #{@memory.path}.
        SECTION
      end
    end
  end
end
