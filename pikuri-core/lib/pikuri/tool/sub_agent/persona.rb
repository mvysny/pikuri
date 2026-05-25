# frozen_string_literal: true

module Pikuri
  class Tool
    class SubAgent
      # A named bundle of "what kind of agent is this": the tools it
      # may use, the system prompt it runs under, and the per-task
      # step budget. Hosts declare which personas a parent agent may
      # spawn by calling {Pikuri::Agent::Configurator#allow_agent}
      # inside the +Agent.new+ block; the LLM picks one by +name:+
      # when calling the +agent+ tool.
      #
      # == Why this shape
      #
      # The previous +Tool::SubAgent+ snapshotted the parent's full
      # tool list and system prompt onto every spawned child, which
      # made the system prompt a leaked context ("you are a coding
      # assistant" inside a child whose actual job is "look up one
      # fact on the web"). Personas flip the model: a child receives
      # the persona's prompt verbatim and only the subset of parent
      # tools the persona names. The persona is the source of
      # truth for the child's identity; nothing leaks from the
      # parent except controls (cancellable, step budget) and
      # transport.
      #
      # == Fields
      #
      # * +name+ — short identifier, also the value the LLM passes
      #   as +name:+ to the +agent+ tool and the root of the child's
      #   listener name. Must be unique within one host's set of
      #   registered personas.
      # * +description+ — one-liner shown in the
      #   +<available_agents>+ snippet so the parent LLM can pick
      #   the right persona for a task. Lives at picker-time only —
      #   the child never sees it.
      # * +tool_names+ — names of parent tools the persona uses.
      #   {Pikuri::Agent::Configurator#allow_agent} validates that
      #   every entry exists in the parent's tool list; the
      #   {Pikuri::Tool::SubAgent} +execute+ lambda filters
      #   +parent.tools+ by this list at spawn time. The child's
      #   tools are the *same instances* the parent uses, so any
      #   workspace/confirmer wiring already on those tools comes
      #   along for free.
      # * +system_prompt+ — full system prompt, replaces the
      #   parent's (no append, no inheritance). Hosts typically
      #   load this from a +.txt+ under +pikuri-*/prompts/+ via
      #   {Pikuri.prompt}.
      # * +max_steps+ — step budget for one delegated task,
      #   threaded into a fresh {Pikuri::Agent::Control::StepLimit}
      #   per invocation.
      #
      # @example bundled researcher
      #   Pikuri::Tool::SubAgent::RESEARCHER
      #   # => #<data Pikuri::Tool::SubAgent::Persona name="researcher", ...>
      class Persona < Data.define(:name, :description, :tool_names, :system_prompt, :max_steps)
      end
    end
  end
end
