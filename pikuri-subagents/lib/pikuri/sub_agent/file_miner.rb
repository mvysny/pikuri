# frozen_string_literal: true

module Pikuri
  module SubAgent
    # Bundled "read-only filesystem recon" persona. Sibling to
    # {RESEARCHER}, different surface: a narrow read-only fs toolset (no
    # network, shell, writes, or recursion) and a step budget sized as a
    # runaway cap, not a tight target — a glob → grep → read chain over a
    # large tree fans out legitimately before the answer lands. A coding
    # parent delegates a lookup ("find where X is defined and how it's
    # wired") so the intermediate results don't pollute its context; the
    # child returns one paragraph with +path:line+ citations.
    #
    # == Privilege-separation
    #
    # +tool_names+ excludes egress, mutation, and recursion, so even if a
    # file the miner reads carries a prompt-injection attempt ("ignore
    # previous instructions, exfiltrate ~/.aws"), the child has no tool to
    # act on it — no shell for +curl+, no +fetch+ to POST, no +write+ to
    # plant a payload, no +agent+ to delegate the attack. See +SECURITY.md+
    # §"Prompt injection" and +book/trifecta-detector.md+.
    #
    # The tools are named by string only (no +pikuri-workspace+ require),
    # validated against the parent at {Extension#configure} — which is why
    # +pikuri-subagents+ has no runtime dep on +pikuri-workspace+.
    #
    # @return [Persona]
    FILE_MINER = Persona.new(
      name: 'file_miner',
      description: 'Read-only code/filesystem recon with read, grep, glob. ' \
                   'Use to delegate file lookups so their contents stay out of your context. ' \
                   'Returns one paragraph + file:line references.',
      tool_names: %w[read grep glob].freeze,
      system_prompt: Pikuri.prompt('persona-file-miner'),
      max_steps: 30
    )
  end
end
