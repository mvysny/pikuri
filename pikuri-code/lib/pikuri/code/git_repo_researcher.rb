# frozen_string_literal: true

require 'pathname'

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
    # The persona ships with a +workspace_builder:+ recipe: given a
    # fresh empty dir from {SubAgentTool}'s +Dir.mktmpdir+, return
    # a {Pikuri::Workspace::Filesystem} bound to it. SubAgentTool
    # owns the temp dir lifecycle (mktmpdir + rm_rf on close) so the
    # persona only describes the *shape* of its workspace — namely,
    # +project_root+ at the temp dir plus
    # {Pikuri::Code::ToolchainPaths.readable} folded into +readable:+
    # so the sub-agent can find +git+ under +/usr+.
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
      max_steps: 20,
      workspace_builder: lambda { |temp_root|
        Pikuri::Workspace::Filesystem.new(
          project_root: Pathname.new(temp_root),
          readable: Pikuri::Code::ToolchainPaths.readable,
          temp: false
        )
      }
    )
  end
end
