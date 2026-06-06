# frozen_string_literal: true

module Pikuri
  module Tasks
    # Domain event emitted onto the agent's listener stream after
    # every {List} mutation (add / status change / delete), wired by
    # {Extension#bind} via
    # {Pikuri::Agent::ExtensionContext#emit_event}. Carries a frozen
    # point-in-time snapshot of the whole list ({List#items}'s
    # shape), so a consumer needs no +List+ reference — render or
    # serialize the payload as-is.
    #
    # Lands between the mutating tool's {Pikuri::Agent::Event::ToolCall}
    # and {Pikuri::Agent::Event::ToolResult} in the stream (the
    # +on_change+ hook fires inside the tool's +execute+). A batch
    # +task_create+ emits one event per added item — consumers that
    # render should treat the latest snapshot as authoritative
    # (last-wins) rather than diffing event-by-event.
    #
    # Fired on the agent's thread. A listener feeding another thread
    # (e.g. a web UI pushing over SSE) should serialize inside
    # +on_event+ and hand off only the immutable result — see the
    # Concurrency note on {List}.
    ListChanged = Data.define(:items)
  end
end
