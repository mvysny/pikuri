# frozen_string_literal: true

module Pikuri
  module Os
    # One-call wiring for the offline OS-helper agent. Adding this single
    # extension to an +Agent.new+ block gives the complete surface — the
    # five workspace file tools, +bash+ (net-severable, with the read-only
    # auto-confirmer), the file-index tools, and the machine grounding +
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
    # {Pikuri::Workspace::Confirmer::TERMINAL}). +Write+ gets it directly
    # (every overwrite confirms). +Bash+ gets it wrapped in
    # {Pikuri::Code::Bash::ReadOnlyAutoConfirmer}, so provably read-only
    # commands run without a prompt and everything else still reaches the
    # human — the conservative half of the confirmation-fatigue answer.
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
    # The file-index tools need GNOME's +localsearch+. When it's absent the
    # extension logs a warning and simply omits them — the agent still works
    # (bash + file tools); it doesn't fail to construct on a non-GNOME host.
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Os::Extension')

      # @param filesystem [Pikuri::Workspace::Filesystem] the host fs view
      #   for the file tools and bash (typically
      #   {Pikuri::Workspace::Filesystem::AllowAll} for full-host access).
      # @param confirmer [Pikuri::Workspace::Confirmer] the *human*
      #   confirmer; Bash is auto-gated on top of it (see "Confirmation
      #   policy").
      # @param sandbox [Pikuri::Code::Bash::Sandbox] bash subprocess
      #   isolation; defaults to {Pikuri::Code::Bash::Sandbox::NONE}.
      # @param memory [MachineMemory] the MACHINE.md reader.
      # @param system_info [SystemInfo] the boot-time machine facts.
      def initialize(filesystem:, confirmer:,
                     sandbox: Pikuri::Code::Bash::Sandbox::NONE,
                     memory: MachineMemory.new, system_info: SystemInfo.new)
        @filesystem = filesystem
        @confirmer = confirmer
        @sandbox = sandbox
        @memory = memory
        @system_info = system_info
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        c.add_extension(Pikuri::Workspace::Extension.new(filesystem: @filesystem, confirmer: @confirmer))
        c.add_extension(Pikuri::Code::Extension.new(
                          filesystem: @filesystem,
                          confirmer: Pikuri::Code::Bash::ReadOnlyAutoConfirmer.new(@confirmer),
                          sandbox: @sandbox
                        ))

        if LocalSearch.available?
          c.add_tool FileindexSearch.new
          c.add_tool FileindexRead.new
        else
          LOGGER.warn('localsearch not found on PATH; fileindex_search / fileindex_read ' \
                      'disabled (GNOME desktop file index unavailable on this host).')
        end

        c.append_system_prompt(@system_info.prompt_section)
        c.append_system_prompt(@memory.prompt_section || empty_memory_affordance)
        nil
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
