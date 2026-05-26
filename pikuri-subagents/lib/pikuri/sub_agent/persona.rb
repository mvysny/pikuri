# frozen_string_literal: true

module Pikuri
  module SubAgent
    # A named bundle of "what kind of agent is this": the tools it
    # may use, the system prompt it runs under, and the per-task
    # step budget. Hosts declare which personas a parent agent may
    # spawn by handing instances to {Extension} via its
    # +personas:+ kwarg inside the +Agent.new+ block; the LLM
    # picks one by +name:+ when calling the +agent+ tool.
    #
    # == Why this shape
    #
    # An earlier iteration of +SubAgentTool+ snapshotted the parent's
    # full tool list and system prompt onto every spawned child, which
    # made the system prompt a leaked context ("you are a coding
    # assistant" inside a child whose actual job is "look up one fact
    # on the web"). Personas flip the model: a child receives the
    # persona's prompt verbatim and only the subset of parent tools
    # the persona names. The persona is the source of truth for the
    # child's identity; nothing leaks from the parent except controls
    # (cancellable, step budget) and transport.
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
    #   {Extension} validates at +configure+ time that every entry
    #   exists in the parent's tool list; the {SubAgentTool}
    #   +execute+ lambda filters +parent.tools+ by this list at
    #   spawn time. The child's tools are the *same instances* the
    #   parent uses, so any workspace/confirmer wiring already on
    #   those tools comes along for free.
    # * +system_prompt+ — full system prompt, replaces the
    #   parent's (no append, no inheritance). Hosts typically
    #   load this from a +.txt+ under +pikuri-*/prompts/+ via
    #   {Pikuri.prompt}.
    # * +max_steps+ — step budget for one delegated task,
    #   threaded into a fresh {Pikuri::Agent::Control::StepLimit}
    #   per invocation.
    # * +workspace_builder+ — optional +Proc+ taking a fresh empty
    #   temp directory path (String) and returning a
    #   {Pikuri::Workspace::Filesystem} (or compatible) bound to it.
    #   When set, {SubAgentTool} +Dir.mktmpdir+s a per-invocation
    #   temp dir, calls this builder to wrap it into a Workspace,
    #   threads the result through tools that respond to
    #   +#with_workspace+, and +FileUtils.remove_entry+s the temp
    #   dir at sub-agent +#close+. The persona has *no* control
    #   over the dir lifecycle — it's always a temp folder, always
    #   deleted, full stop. The builder's only job is "given this
    #   path, build me a Workspace". Default +nil+ — child shares
    #   the parent's workspace through tool instance reuse. See
    #   {Pikuri::Code::GIT_REPO_RESEARCHER} for the bundled use
    #   case (fresh empty workspace per clone-and-explore task).
    #
    # @example bundled researcher
    #   Pikuri::SubAgent::RESEARCHER
    #   # => #<data Pikuri::SubAgent::Persona name="researcher", ...>
    class Persona < Data.define(:name, :description, :tool_names, :system_prompt, :max_steps, :workspace_builder)
      # @param workspace_builder [Proc, nil] optional builder, see
      #   class header. Default +nil+.
      def initialize(workspace_builder: nil, **rest)
        super(workspace_builder: workspace_builder, **rest)
      end

      # @return [Boolean] +true+ iff a +workspace_builder+ was wired.
      def needs_temp_workspace?
        !workspace_builder.nil?
      end
    end
  end
end
