# frozen_string_literal: true

module Pikuri
  module Code
    # Domain event emitted onto the agent's listener stream whenever
    # the shared {Pikuri::Agent::Control::PlanMode} transitions —
    # whether the model flipped it (via {EnterPlanMode} /
    # {ExitPlanMode}) or the host flipped it out-of-band (a key
    # binding). Wired by {Extension#bind} through
    # {Pikuri::Agent::Control::PlanMode#on_change} →
    # {Pikuri::Agent::ExtensionContext#emit_event}.
    #
    # Carries only the new posture, so a UI listener can render a
    # plan-mode indicator in its chrome without ever touching the
    # control. Like every domain event, listeners that don't care
    # must no-op on it (see CLAUDE.md's "Capability seam").
    #
    # A host-initiated flip fires on the host's thread; a model flip
    # fires on the agent's thread. A listener feeding another thread
    # should treat the boolean as the latest authoritative state
    # rather than assuming a particular emitting thread.
    PlanModeChanged = Data.define(:active)
  end
end
