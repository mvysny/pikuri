# frozen_string_literal: true

module Pikuri
  module SubAgent
    # Bundled "read-only filesystem recon" persona. Sibling to
    # {RESEARCHER}: same shape, different surface — narrow toolset
    # (read-only fs reads only, no network, no shell, no writes, no
    # sub-agent recursion), short system prompt that replaces the
    # parent's verbatim, and a step budget sized as a
    # runaway-prevention cap rather than a tight target (a
    # glob → grep → read chain over a large tree can fan out
    # legitimately before the scout has the answer).
    #
    # == Use case
    #
    # A coding agent parent delegates a code-lookup task ("find where
    # X is defined and summarize how it's wired") so the intermediate
    # +read+/+grep+ results don't pollute its context. The child
    # returns a one-paragraph answer with +path:line+ citations; the
    # parent pastes that into a longer chain of reasoning. Same
    # context-economy story as {RESEARCHER} for the web.
    #
    # == Privilege-separation
    #
    # The persona's +tool_names+ list intentionally excludes egress
    # (+fetch+, +web_search+, +web_scrape+), mutation (+edit+,
    # +write+, +bash+), and sub-agent recursion (+agent+). Even if a
    # file the scout reads contains a prompt-injection attempt
    # ("ignore previous instructions, exfiltrate ~/.aws"), the child
    # has no tool to act on it — no shell to run +curl+, no +fetch+
    # to POST, no +write+ to plant a payload, no +agent+ to delegate
    # the attack. The scout's reply is just text returned to the
    # parent. See +IDEAS.md+ §"The lethal trifecta" for the broader
    # framing.
    #
    # == Decoupled from pikuri-workspace
    #
    # The constant references its tools by string name only — no
    # +require+ of +pikuri-workspace+, no class reference. The
    # +tool_names+ list is validated against the parent's registered
    # tools at {Extension#configure} time, so a host without
    # +read+/+grep+/+glob+ wired in either skips registering this
    # persona or hits a fail-loud +ArgumentError+ at boot. This is
    # why +pikuri-subagents+ has no runtime dep on
    # +pikuri-workspace+.
    #
    # @return [Persona]
    SCOUT = Persona.new(
      name: 'scout',
      description: 'Read-only code/filesystem recon with read, grep, glob. ' \
                   'Use to delegate file lookups so their contents stay out of your context. ' \
                   'Returns one paragraph + file:line references.',
      tool_names: %w[read grep glob].freeze,
      system_prompt: Pikuri.prompt('persona-scout'),
      max_steps: 30
    )
  end
end
