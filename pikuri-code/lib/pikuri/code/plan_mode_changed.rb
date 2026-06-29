# frozen_string_literal: true

module Pikuri
  module Code
    # Domain event emitted onto the agent's listener stream whenever plan
    # mode transitions — whether the model flipped it (via {EnterPlanMode}
    # / {ExitPlanMode}) or the host flipped it out-of-band (a key binding /
    # slash command). Wired by {Extension#bind} through the shared
    # {Pikuri::Workspace::ReadOnly} flag's +on_change+ →
    # {Pikuri::Agent::ExtensionContext#emit_event}.
    #
    # It is a *domain* event in pikuri-code's namespace — not a core
    # {Pikuri::Agent::Event} variant — because plan mode is a pikuri-code
    # feature, not part of the agent loop (the loop never reads it). Like
    # every domain event, listeners that don't care must no-op on it (see
    # CLAUDE.md's "Capability seam"); the demo {Pikuri::Agent::Listener::Terminal}
    # renders it generically via {#to_s}.
    #
    # Carries only the new posture, so a UI listener can render a plan-mode
    # indicator in its chrome without ever touching the flag.
    #
    # A host-initiated flip fires on the host's thread; a model flip fires
    # on the agent's thread. A listener feeding another thread should treat
    # the boolean as the latest authoritative state rather than assuming a
    # particular emitting thread.
    PlanModeChanged = Data.define(:active) do
      # @return [String] human-facing label; the Terminal demo chrome
      #   prints this verbatim, so the wording lives here in pikuri-code,
      #   not in core.
      def to_s
        "plan mode: #{active ? 'on (read-only)' : 'off'}"
      end
    end
  end
end
