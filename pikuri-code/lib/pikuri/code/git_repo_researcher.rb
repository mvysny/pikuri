# frozen_string_literal: true

module Pikuri
  module Code
    # Bundled "clone-and-dig" persona. Where {Pikuri::SubAgent::RESEARCHER}
    # answers "look up one fact online", +GIT_REPO_RESEARCHER+ answers
    # "explore that repo's source for how it does X."
    #
    # == Toolset
    #
    # * +git_clone+ — shallow, sandboxed clone of a public repo
    #   ({Pikuri::Code::GitClone}).
    # * +read+ / +grep+ / +glob+ — rebuilt onto the persona's fresh
    #   workspace by {Pikuri::SubAgent::SubAgentTool}'s
    #   +#with_workspace+ dispatch (see
    #   {Pikuri::SubAgent::Persona}'s class header).
    # * +web_search+ / +web_scrape+ / +fetch+ — same network reads
    #   as {Pikuri::SubAgent::RESEARCHER}; useful for "what does the
    #   README say about Y" without a clone.
    #
    # No +bash+, no +edit+, no +write+, no +agent+ (no recursion).
    #
    # == Per-invocation workspace
    #
    # The persona signals +needs_temp_workspace: true+ — that's all.
    # {Pikuri::SubAgent::SubAgentTool} owns the lifecycle: mktmpdir +
    # construct a {Pikuri::Workspace::Filesystem} with the temp dir
    # as +project_root+ + {Pikuri::SubAgent::SubAgentTool::TEMP_WORKSPACE_READABLE}
    # folded into +readable:+ (so the Bubblewrap-wrapped +git+
    # subprocess can find its binary under +/usr+) +
    # +FileUtils.remove_entry+ on the temp dir at sub-agent close.
    # The persona has no say in shape or cleanup.
    #
    # The persona's filesystem view is *disjoint* from the parent's:
    # a cloned repo cannot leave files where the parent's +read+
    # tool would later find them (containment check rejects paths
    # outside the parent's +project_root+), so string paths
    # exfiltrated through the persona's reply are inert.
    #
    # == Security profile
    #
    # Trifecta-wise, the persona is the same shape as
    # {Pikuri::SubAgent::RESEARCHER}: leg (a) "private data" is
    # structurally near-zero (no project_root access, no home dir
    # access — only the temp workspace + what it just downloaded);
    # legs (b)/(c) are present (untrusted cloned content + network
    # egress) but harmless without (a). The one wrinkle vs.
    # RESEARCHER is the historical RCE class on +git clone+ itself
    # — addressed by {GitClone}'s HTTPS-only + no-submodules + the
    # Bubblewrap sandbox bound to the temp workspace. See
    # {Pikuri::Code::GitClone} for the full mitigation list.
    #
    # @return [Pikuri::SubAgent::Persona]
    GIT_REPO_RESEARCHER = Pikuri::SubAgent::Persona.new(
      name: 'git_repo_researcher',
      description: 'Clone a public git repo and explore it with read/grep/glob. ' \
                   'Use when you need to dig through a repository\'s actual source, ' \
                   'not just a page about it. Also has web_search/web_scrape/fetch. ' \
                   'Returns one paragraph + citations.',
      tool_names: %w[git_clone read grep glob web_search web_scrape fetch].freeze,
      system_prompt: Pikuri.prompt('persona-git-repo-researcher'),
      max_steps: 30,
      needs_temp_workspace: true
    )
  end
end
