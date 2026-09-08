# frozen_string_literal: true

module Pikuri
  class Agent
    # Namespace for the +Agent+'s pure event consumers — {Terminal},
    # {InMemoryEventList}, {TokenLog}, and any host/test consumer. Each
    # subclasses {Base} and overrides {Base#on_event} to pattern-match the
    # {Event} variants it cares about; everything else flows through unobserved.
    #
    # These are *pure consumers*: no listener writes back into the stream
    # (emission is the +Agent+'s and {Agent::ExtensionContext#emit_event}'s job)
    # or reaches into ruby_llm's callbacks (that's {Agent}'s). Host-facing signal
    # holders (step budget, cancel flag, input queue) are *controls* under
    # {Pikuri::Agent::Control}, not listeners — they never appear in a
    # {ListenerList} or receive events.
    module Listener
      # Abstract base for event-stream consumers. Subclasses override {#on_event}
      # with a +case+ on the {Event} variant; the default is a no-op so a
      # listener caring about one variant needn't enumerate the rest.
      #
      # Subclasses optionally define +for_sub_agent(**params)+ for a spawned
      # sub-agent — a fresh instance, the same shared by reference, or +nil+ to
      # opt out. See {ListenerList#for_sub_agent}.
      class Base
        # Single entry point for every event in the normalized stream.
        # Subclasses override and dispatch on the variant (a +case event in
        # Event::X(...)+); the default no-op lets a listener match a subset and
        # ignore the rest.
        #
        # @param event [Event::UserTurn, Event::Thinking, Event::ThinkingDelta,
        #   Event::Assistant, Event::AssistantDelta, Event::ToolCall,
        #   Event::ToolResult, Event::Tokens, Event::ContextCap,
        #   Event::Cancelled, Object] a core
        #   loop-narration variant, or a gem domain event via
        #   {Agent::ExtensionContext#emit_event} (e.g. +Pikuri::Tasks::ListChanged+)
        # @return [void]
        def on_event(event); end
      end
    end
  end
end
