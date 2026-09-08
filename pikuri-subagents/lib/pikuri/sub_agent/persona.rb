# frozen_string_literal: true

module Pikuri
  module SubAgent
    # A named bundle of "what kind of agent is this": the tools it may
    # use, the system prompt it runs under, and the per-task step budget.
    # Hosts hand instances to {Extension}'s +personas:+ kwarg; the LLM
    # picks one by +name:+ when calling the +agent+ tool. The persona is
    # the source of truth for the child's identity — a child gets the
    # persona's prompt verbatim and only the named subset of parent tools;
    # nothing leaks from the parent except controls and transport.
    #
    # == Fields
    #
    # * +name+ — short identifier, also the +name:+ value the LLM passes
    #   and the root of the child's listener name. Unique per host.
    # * +description+ — one-liner shown in +<available_agents>+ so the
    #   parent picks the right persona; picker-time only, the child never
    #   sees it.
    # * +tool_names+ — names of parent tools the persona uses ({Extension}
    #   validates them at +configure+; spawn filters +parent.tools+ by
    #   this list). The child's tools are the *same instances* the parent
    #   uses, so their workspace/confirmer wiring comes along for free.
    # * +system_prompt+ — full prompt, replaces the parent's (no append,
    #   no inheritance).
    # * +needs_temp_workspace+ — when +true+, {SubAgentTool} mints a
    #   fresh temp workspace per invocation and deletes it at close (see
    #   there; the persona controls neither shape nor lifecycle). Default
    #   +false+ — child shares the parent's workspace via tool reuse.
    #   {Pikuri::Code::GIT_REPO_RESEARCHER} is the bundled use case.
    #
    # == The prompt is the whole brief
    #
    # A child inherits no extensions, so no +<available_skills>+ block and no
    # MCP tools reach it, and no bundled persona names +skill+ in
    # +tool_names+ either. Put everything the child must know in
    # +system_prompt+ — it fetches no instructions at runtime. Naming +skill+
    # does work for a concrete case, resolving against
    # {Pikuri::Skill::Activation::Sealed} (ungated skills only, never the
    # parent's path promotions); why that is not the default is
    # +DECISIONS.md+ +D_no_skills_in_sub_agents+.
    #
    # @example bundled researcher
    #   Pikuri::SubAgent::RESEARCHER
    #   # => #<data Pikuri::SubAgent::Persona name="researcher", ...>
    class Persona < Data.define(:name, :description, :tool_names, :system_prompt, :needs_temp_workspace)
      # @param needs_temp_workspace [Boolean] see class header.
      #   Default +false+.
      def initialize(needs_temp_workspace: false, **rest)
        super(needs_temp_workspace: needs_temp_workspace, **rest)
      end

      # Predicate-style alias for {#needs_temp_workspace}; reads
      # more naturally at call sites
      # (+if persona.needs_temp_workspace?+).
      #
      # @return [Boolean]
      alias_method :needs_temp_workspace?, :needs_temp_workspace
    end
  end
end
