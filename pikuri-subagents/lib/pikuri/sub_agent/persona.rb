# frozen_string_literal: true

module Pikuri
  module SubAgent
    # A named bundle of "what kind of agent is this": the tools it may
    # use and the system prompt it runs under.
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
    #
    # == The prompt is the whole brief
    #
    # A child inherits no extensions, so nothing an extension contributes to
    # the prompt or the toolset reaches it. Put everything the child must know
    # in +system_prompt+ — it fetches no instructions at runtime. (A host
    # wiring pikuri-workshop's skills may still name +skill+ in +tool_names+;
    # why no bundled persona does is +pikuri-workshop:D_no_skills_in_sub_agents+.)
    #
    # == The host writes personas, never the model
    #
    # A persona's +tool_names+ is the unit the trifecta map places, at most
    # two legs per node ({Pikuri::Trifecta}). A persona the model writes at
    # runtime would choose its own legs, and an injected model would choose
    # all three — so there is no +agent+ argument that names tools or a
    # prompt, only +name:+ picking from the host's set.
    #
    # @example bundled researcher
    #   Pikuri::SubAgent::RESEARCHER
    #   # => #<data Pikuri::SubAgent::Persona name="researcher", ...>
    class Persona < Data.define(:name, :description, :tool_names, :system_prompt); end
  end
end
